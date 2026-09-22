#!/usr/bin/env bash
# Dns_Sundhedstjek.sh — monitors DNSSEC, DMARC, CAA and SPF for seven domains
#
# Most important: warns if DNSSEC signatures are about to expire.
# e-studio auto re-signs records but does NOT rotate KSKs. If their signing
# job stops, the signatures expire and the domain becomes invisible to
# validating resolvers. This script catches that in time.
#
# All lookups go via DNS-over-HTTPS (dig +https, requires bind9-dnsutils >= 9.18).
# Plain DNS on port 53 is intercepted on the local network (UDM-Pro), which
# strips the ad flag and answers with local records — so the script would end
# up measuring the local network instead of the internet. DoH over 443 bypasses that.
#   Plain DNS instead:  DIGOPT= ./Dns_Sundhedstjek.sh
#
# Run daily via cron:
#   0 7 * * *  /path/to/Dns_Sundhedstjek.sh >> /var/log/dns-tjek.log 2>&1
#
# Requires: dig (bind9-dnsutils / dnsutils)
# Exit 0 = all OK, 1 = warning, 2 = critical,
#      3 = check could not be performed (resolver unreachable / not validating)

set -uo pipefail
# --- Dependency check ---------------------------------------------------------
# Finds lib/require_tools.sh in three places, in this order:
#   1. $REQUIRE_TOOLS_LIB (explicit path)
#   2. upward from the script's own directory (works when the script lives UNDER ~/git)
#   3. known locations (works when it lives in a side branch, e.g. ~/DNSSEC)
# If it isn't found, a built-in fallback is used — a missing helper library
# must not stop a monitoring script.
_find_lib() {
  local d p
  [ -n "${REQUIRE_TOOLS_LIB:-}" ] && [ -f "$REQUIRE_TOOLS_LIB" ] && { printf '%s' "$REQUIRE_TOOLS_LIB"; return; }
  d="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
  while :; do
    [ -f "$d/lib/require_tools.sh" ] && { printf '%s' "$d/lib/require_tools.sh"; return; }
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  for p in "$HOME/git/lib" "$HOME/Linux-Scripts/lib" "$HOME/lib"; do
    [ -f "$p/require_tools.sh" ] && { printf '%s' "$p/require_tools.sh"; return; }
  done
}
_lib="$(_find_lib)"
if [ -n "$_lib" ]; then
  # shellcheck source=/dev/null
  source "$_lib"
else
  echo "WARNING: lib/require_tools.sh not found — using built-in check." >&2
  require_tools() {
    local spec miss=()
    for spec in "$@"; do
      command -v "${spec%%:*}" >/dev/null 2>&1 || miss+=("${spec%%:*} (package: ${spec#*:})")
    done
    [ ${#miss[@]} -eq 0 ] && return 0
    printf 'ERROR: missing: %s\n' "${miss[@]}" >&2
    exit 1
  }
fi
unset _lib
require_tools "dig:dnsutils"

DOMAINS=(
  ahlstrom-itsec.com
  ahlstrom-itsec.dk
  coldicewarmblood.info
  dragic-playground.info
  dragic.com
  taenkeboksen.dk
  xn--tnkeboksen-d6a.dk
)

RESOLVER="@1.1.1.1"
SECONDARY="@9.9.9.9"        # confirms SERVFAIL before raising a critical alarm
DIGOPT="${DIGOPT-+https}"   # empty = plain DNS on port 53
DIGBASE=(+time=5 +tries=2)
CANARY="isc.org"            # known signed domain for the preflight check
WARN_DAYS=5                 # warn when signatures expire in under 5 days
CRIT_DAYS=2                 # critical under 2 days
EXPECTED_CA="letsencrypt.org"

# Expected number of DS records per domain. .dk domains get two, because DK
# Hostmaster itself computes the extra SHA-384 variant from your SHA-256.
# A deviation usually means one DS record too many — typically an
# incorrectly entered digest.
# 0 = DNSSEC is NOT expected to be active.
declare -A EXPECTED_DS=(
  [ahlstrom-itsec.com]=1
  [ahlstrom-itsec.dk]=2
  [coldicewarmblood.info]=1
  [dragic-playground.info]=1
  [dragic.com]=1
  [taenkeboksen.dk]=2
  [xn--tnkeboksen-d6a.dk]=2
)

status=0
note() { printf '  %-9s %s\n' "$1" "$2"; }
bump() { [ "$1" -gt "$status" ] && status=$1; return 0; }

# --- DNS helpers ---------------------------------------------------------------
# Output is always captured into a variable and matched afterwards. Never
# "dig | grep -q": grep -q closes the pipe early, dig gets SIGPIPE, and
# pipefail turns that into a false negative.
qr() { local r=$1; shift
       # shellcheck disable=SC2086  # DIGOPT must be word-split (can be empty)
       dig $DIGOPT "${DIGBASE[@]}" "$@" "$r" 2>/dev/null; }
q()  { qr "$RESOLVER" "$@"; }

# rcode from the full dig output (NOERROR, SERVFAIL, NXDOMAIN …), empty on timeout
rcode_of() { awk '/->>HEADER<<-/ {for(i=1;i<=NF;i++) if($i=="status:"){s=$(i+1); gsub(",","",s); print s; exit}}' <<<"$1"; }
# Flag matches ONLY in the header line ";; flags: …;" — not in the EDNS line
has_flag() { grep -qE "^;; flags:[^;]* $1[ ;]" <<<"$2"; }
# rdata for a given type from the answer section (reads stdin)
rdata() { awk -v t="$1" '$1 !~ /^;/ && NF>4 && $4==t {$1=$2=$3=$4=""; sub(/^ +/,""); print}'; }

echo "=============================================="
echo "DNS health check — $(date '+%Y-%m-%d %H:%M %Z')"
echo "Resolver: ${RESOLVER#@} ${DIGOPT:-(port 53)}"
echo "=============================================="

# --- Preflight: are we talking to a validating resolver? -----------------------
pre=$(q +dnssec "$CANARY" A)
pre_rc=$(rcode_of "$pre")
if [ "$pre_rc" != "NOERROR" ]; then
  echo "ERROR: no usable answer from ${RESOLVER#@} (rcode=${pre_rc:-timeout/invalid call})."
  echo "       Check the network, and that dig supports '$DIGOPT' (dig -v — requires bind 9.18+)."
  exit 3
fi
if ! has_flag ad "$pre"; then
  echo "ERROR: the resolver does not validate DNSSEC (ad flag missing on $CANARY)."
  echo "       DNS is likely being intercepted along the way. Results would be misleading."
  exit 3
fi

auth_unreachable=0

for d in "${DOMAINS[@]}"; do
  echo
  echo "--- $d"
  exp_ds=${EXPECTED_DS[$d]:-0}

  # ---------- 1. Lookup + SERVFAIL (broken DNSSEC chain) ----------
  # Tested BEFORE the A-record check: a broken chain gives SERVFAIL with no A record.
  a_out=$(q +dnssec "$d" A)
  rcode=$(rcode_of "$a_out")

  if [ "$rcode" = "SERVFAIL" ]; then
    sec_rc=$(rcode_of "$(qr "$SECONDARY" "$d" A)")
    if [ "$sec_rc" = "SERVFAIL" ]; then
      cd_rc=$(rcode_of "$(q +cd "$d" A)")     # +cd = without DNSSEC validation
      if [ "$cd_rc" = "NOERROR" ]; then
        note "CRITICAL" "SERVFAIL at both resolvers, but answers fine without validation — the DNSSEC chain is broken."
        note ""         "Check: dig +dnssec $d SOA $RESOLVER | grep RRSIG"
        note ""         "Emergency fix: remove the DS record at the registrar to bring the domain back."
      else
        note "CRITICAL" "SERVFAIL even without validation — the name servers aren't answering correctly."
      fi
      bump 2
    else
      note "WARNING" "SERVFAIL only at ${RESOLVER#@} (${SECONDARY#@}: ${sec_rc:-no answer}) — probably transient"
      bump 1
    fi
    continue
  fi

  # ---------- 2. Does the domain answer with an address? ----------
  if [ -z "$rcode" ]; then
    note "CRITICAL" "no answer (timeout)"; bump 2; continue
  fi
  if [ -z "$(rdata A <<<"$a_out")" ]; then
    note "CRITICAL" "domain doesn't answer with an A record (rcode=$rcode)"
    bump 2; continue
  fi

  # ---------- 3. DNSSEC ----------
  ds_out=$(q DS "$d")
  ds_rc=$(rcode_of "$ds_out")
  ds_count=$(rdata DS <<<"$ds_out" | awk 'END{print NR}')

  if [ "$ds_rc" != "NOERROR" ]; then
    note "WARNING" "DS lookup failed (rcode=${ds_rc:-timeout}) — DNSSEC not checked"; bump 1
  elif [ "$ds_count" -eq 0 ]; then
    if [ "$exp_ds" -gt 0 ]; then
      note "WARNING" "no DS records, but $exp_ds expected — has DNSSEC been disabled at the registrar?"; bump 1
    else
      note "info" "no DS — DNSSEC not active (as expected)"
    fi
  else
    # Earliest expiry among ALL SOA signatures (several during key rotation)
    soa_out=$(q +dnssec "$d" SOA)
    exp=$(awk '$1 !~ /^;/ && $4=="RRSIG" && $5=="SOA" {if(m=="" || $9<m) m=$9} END{print m}' <<<"$soa_out")
    if [[ "$exp" =~ ^[0-9]{14}$ ]]; then
      es=$(date -u -d "${exp:0:8} ${exp:8:2}:${exp:10:2}:${exp:12:2}" +%s 2>/dev/null || echo "")
      if [ -n "$es" ]; then
        secs=$(( es - $(date -u +%s) ))
        days=$(( secs / 86400 ))
        if   [ "$secs" -le 0 ];           then note "CRITICAL" "signatures have EXPIRED — contact e-studio NOW"; bump 2
        elif [ "$days" -lt "$CRIT_DAYS" ]; then note "CRITICAL" "signatures expire in $(( secs / 3600 )) hours — contact e-studio NOW"; bump 2
        elif [ "$days" -lt "$WARN_DAYS" ]; then note "WARNING" "signatures expire in $days days"; bump 1
        else note "ok" "signatures valid for $days more days"
        fi
      else note "WARNING" "couldn't parse RRSIG date ($exp)"; bump 1
      fi
    else note "WARNING" "couldn't read RRSIG expiry"; bump 1
    fi

    if [ "$exp_ds" -eq 0 ]; then
      note "WARNING" "$ds_count DS records, but DNSSEC isn't expected — update EXPECTED_DS"; bump 1
    elif [ "$ds_count" -ne "$exp_ds" ]; then
      note "WARNING" "$ds_count DS records, expected $exp_ds — check for a wrong digest"; bump 1
    fi

    if has_flag ad "$a_out"; then
      note "ok" "DNSSEC validates (ad flag set)"
    else
      note "WARNING" "DS exists, but the answer isn't validated (unknown algorithm/digest?)"; bump 1
    fi
  fi

  # ---------- 4. DMARC ----------
  dm_out=$(q TXT "_dmarc.$d")
  dm_rc=$(rcode_of "$dm_out")
  dmarc=$(rdata TXT <<<"$dm_out" | grep '^"v=DMARC1' || true)
  dm_cname=$(rdata CNAME <<<"$dm_out")
  cnt=$(grep -c . <<<"$dmarc" || true)
  if [ "$dm_rc" != "NOERROR" ] && [ "$dm_rc" != "NXDOMAIN" ]; then
    note "WARNING" "DMARC lookup failed (rcode=${dm_rc:-timeout})"; bump 1
  elif [ "$cnt" -eq 0 ]; then note "CRITICAL" "no DMARC record"; bump 2
  elif [ "$cnt" -gt 1 ]; then note "CRITICAL" "$cnt DMARC records — RFC 7489: = no policy applies"; bump 2
  else
    case "$dmarc $dm_cname" in
      *vali.email*) note "ok" "DMARC with reporting to Valimail" ;;
      *rua=*)       note "WARNING" "DMARC without a Valimail address"; bump 1 ;;
      *)            note "CRITICAL" "DMARC without rua= — no reports delivered"; bump 2 ;;
    esac
  fi

  # ---------- 5. CAA ----------
  caa_out=$(q CAA "$d")
  caa_rc=$(rcode_of "$caa_out")
  caa=$(rdata CAA <<<"$caa_out")
  issue=$(awk '$2=="issue"' <<<"$caa")        # exact tag — not issuewild/issuemail
  if [ "$caa_rc" != "NOERROR" ]; then
    note "WARNING" "CAA lookup failed (rcode=${caa_rc:-timeout})"; bump 1
  elif [ -z "$caa" ]; then
    note "WARNING" "no CAA record"; bump 1
  elif [ -z "$issue" ]; then
    # RFC 8659: CAA RRset without an issue tag = NO CA may issue
    note "CRITICAL" "CAA exists but is missing 'issue' — no CA may issue a certificate"; bump 2
  elif grep -qF "\"$EXPECTED_CA" <<<"$issue"; then
    note "ok" "CAA allows $EXPECTED_CA"
  else
    note "CRITICAL" "CAA 'issue' doesn't mention $EXPECTED_CA — renewal will fail"; bump 2
  fi

  # Leftovers on subdomains — ask the authoritative name server directly (no
  # cache). It doesn't speak DoH, so port 53 is used here. The answer only
  # counts if the aa flag is set — otherwise a middlebox answered, and the
  # check is skipped.
  ns=$(q NS "$d" | rdata NS | awk 'NR==1')
  if [ -n "$ns" ]; then
    for sub in issue issuewild iodef; do
      auth=$(dig "${DIGBASE[@]}" +norecurse CAA "$sub.$d" "@$ns" 2>/dev/null)
      if ! has_flag aa "$auth"; then auth_unreachable=1; break; fi
      if [ -n "$(rdata CAA <<<"$auth")" ]; then
        note "WARNING" "leftover at $sub.$d — CAA should live on the domain itself"; bump 1
      fi
    done
  fi

  # ---------- 6. SPF ----------
  txt_out=$(q TXT "$d")
  txt_rc=$(rcode_of "$txt_out")
  spf=$(rdata TXT <<<"$txt_out" | grep -c '^"v=spf1[ "]' || true)
  if [ "$txt_rc" != "NOERROR" ]; then
    note "WARNING" "TXT lookup failed (rcode=${txt_rc:-timeout}) — SPF not checked"; bump 1
  elif [ "$spf" -ne 1 ]; then
    note "WARNING" "$spf SPF records (should be exactly 1)"; bump 1
  fi
done

echo
if [ "$auth_unreachable" -eq 1 ]; then
  echo "  info      authoritative name servers could not be reached directly on port 53"
  echo "            (intercepted locally?) — CAA leftover check skipped for one or more domains"
fi
echo "=============================================="
case $status in
  0) echo "RESULT: all OK" ;;
  1) echo "RESULT: WARNINGS — see above" ;;
  2) echo "RESULT: CRITICAL — action required" ;;
esac
echo "=============================================="
exit $status
