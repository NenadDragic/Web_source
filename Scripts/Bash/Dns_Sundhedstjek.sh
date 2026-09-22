#!/usr/bin/env bash
# Dns_Sundhedstjek.sh — overvåger DNSSEC, DMARC og CAA på syv domæner
#
# Vigtigst: advarer hvis DNSSEC-signaturer er ved at udløbe.
# e-studio gensignerer automatisk, men roterer IKKE KSK'er. Stopper deres
# signeringsjob, udløber signaturerne, og domænet bliver usynligt for
# validerende resolvere. Dette script fanger det i tide.
#
# Kør dagligt via cron:
#   0 7 * * *  /sti/til/dns-sundhedstjek.sh >> /var/log/dns-tjek.log 2>&1
#
# Kræver: dig (bind9-dnsutils / dnsutils)
# Exit 0 = alt OK, 1 = advarsel, 2 = kritisk

set -uo pipefail
# --- Dependency check (auto-inserted) ---
_d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
while [ "$_d" != "/" ] && [ ! -f "$_d/lib/require_tools.sh" ]; do _d="$(dirname "$_d")"; done
if [ ! -f "$_d/lib/require_tools.sh" ]; then
    echo "FEJL: Kunne ikke finde lib/require_tools.sh (delt dependency-checker)." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$_d/lib/require_tools.sh"
unset _d
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
WARN_DAYS=5         # advar når signaturer udløber om under 5 dage
CRIT_DAYS=2         # kritisk under 2 dage
EXPECTED_CA="letsencrypt.org"
FRESH_TTL=13000     # TTL over dette = friskt CAA-svar (CAA i e-studios zoner har loft 14400)

# Forventet antal DS-records pr. domæne. .dk-domæner får to, fordi DK Hostmaster
# selv beregner SHA-384-varianten ud fra din SHA-256. Afvigelse betyder som regel
# en DS for meget — typisk en forkert digest der er blevet indtastet.
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

# Returnér TTL for første record i svaret (0 hvis intet svar)
get_ttl() { dig "$2" "$1" "$RESOLVER" 2>/dev/null | awk -v t="$1" '$1 ~ t"\\.$" && $2 ~ /^[0-9]+$/ {print $2; exit}'; }

echo "=============================================="
echo "DNS-sundhedstjek — $(date '+%Y-%m-%d %H:%M %Z')"
echo "=============================================="

for d in "${DOMAINS[@]}"; do
  echo
  echo "--- $d"

  # ---------- 1. SERVFAIL først = brudt DNSSEC-kæde ----------
  # Skal testes FØR A-record-tjekket: en brudt kæde giver SERVFAIL uden A-record,
  # og så ville et A-tjek melde "svarer ikke" i stedet for den rigtige årsag.
  rcode=$(dig "$d" A "$RESOLVER" 2>/dev/null \
          | awk '/->>HEADER<<-/ {for(i=1;i<=NF;i++) if($i=="status:") print $(i+1)}' | tr -d ',')
  if [ "${rcode:-}" = "SERVFAIL" ]; then
    note "KRITISK" "SERVFAIL — sandsynligvis brudt DNSSEC-kæde."
    note ""        "Tjek: dig +dnssec $d SOA $RESOLVER | grep RRSIG"
    note ""        "Nødløsning: fjern DS-recorden hos registret, så virker domænet igen."
    bump 2; continue
  fi

  # ---------- 2. Svarer domænet med en adresse? ----------
  if ! dig +short "$d" A "$RESOLVER" 2>/dev/null | grep -qE '^[0-9]'; then
    note "KRITISK" "domænet svarer ikke med en A-record (rcode=${rcode:-ukendt})"
    bump 2; continue
  fi

  # ---------- 3. DNSSEC ----------
  if dig +short DS "$d" "$RESOLVER" 2>/dev/null | grep -q .; then
    exp=$(dig +dnssec "$d" SOA "$RESOLVER" 2>/dev/null | awk '/RRSIG[ \t]+SOA/ {print $9; exit}')
    if [ -n "${exp:-}" ] && [ ${#exp} -eq 14 ]; then
      es=$(date -u -d "${exp:0:8} ${exp:8:2}:${exp:10:2}:${exp:12:2}" +%s 2>/dev/null || echo "")
      if [ -n "$es" ]; then
        days=$(( (es - $(date -u +%s)) / 86400 ))
        if   [ "$days" -lt "$CRIT_DAYS" ]; then note "KRITISK" "signaturer udløber om $days dage — kontakt e-studio NU"; bump 2
        elif [ "$days" -lt "$WARN_DAYS" ]; then note "ADVARSEL" "signaturer udløber om $days dage"; bump 1
        else note "ok" "signaturer gyldige $days dage endnu"
        fi
      else note "ADVARSEL" "kunne ikke fortolke RRSIG-dato ($exp)"; bump 1
      fi
    else note "ADVARSEL" "kunne ikke læse RRSIG-udløb"; bump 1
    fi

    # antal DS-records — fanger en forkert digest der er blevet tilføjet
    ds_count=$(dig +short DS "$d" "$RESOLVER" 2>/dev/null | grep -c .)
    exp_ds=${EXPECTED_DS[$d]:-0}
    if [ "$exp_ds" -gt 0 ] && [ "$ds_count" -ne "$exp_ds" ]; then
      note "ADVARSEL" "$ds_count DS-records, forventet $exp_ds — tjek for en forkert digest"
      bump 1
    fi

    if dig +dnssec "$d" A "$RESOLVER" 2>/dev/null | grep -q 'flags:.* ad'; then
      note "ok" "DNSSEC validerer (ad-flag sat)"
    else
      note "ADVARSEL" "ad-flag ikke sat — kan være cache; tjek igen om et par timer"; bump 1
    fi
  else
    note "info" "ingen DS registreret — DNSSEC ikke aktivt for dette domæne"
  fi

  # ---------- 4. DMARC ----------
  dmarc=$(dig +short TXT "_dmarc.$d" "$RESOLVER" 2>/dev/null | tr -d '"')
  cnt=$(printf '%s\n' "$dmarc" | grep -c 'v=DMARC1' || true)
  if   [ "$cnt" -eq 0 ]; then note "KRITISK" "ingen DMARC-record"; bump 2
  elif [ "$cnt" -gt 1 ]; then note "KRITISK" "$cnt DMARC-records — RFC 7489: = ingen politik"; bump 2
  else
    case "$dmarc" in
      *vali.email*) note "ok" "DMARC med rapportering til Valimail" ;;
      *rua=*)       note "ADVARSEL" "DMARC uden Valimail-adresse"; bump 1 ;;
      *)            note "KRITISK" "DMARC uden rua= — ingen rapporter"; bump 2 ;;
    esac
  fi

  # ---------- 5. CAA ----------
  caa=$(dig +short CAA "$d" "$RESOLVER" 2>/dev/null)
  if [ -z "$caa" ]; then
    note "ADVARSEL" "ingen CAA-record"; bump 1
  elif ! printf '%s' "$caa" | grep -q 'issue[^w]'; then
    # RFC 8659: CAA-RRset uden issue-tag = INGEN CA må udstede
    note "KRITISK" "CAA findes men mangler 'issue' — ingen CA må udstede certifikat"; bump 2
  elif printf '%s' "$caa" | grep 'issue[^w]' | grep -q "$EXPECTED_CA"; then
    note "ok" "CAA tillader $EXPECTED_CA"
  else
    note "KRITISK" "CAA 'issue' nævner ikke $EXPECTED_CA — fornyelse vil fejle"; bump 2
  fi

  # rester på subdomæner — flag KUN hvis svaret er friskt (ikke cache)
  for sub in issue issuewild iodef; do
    if dig +short CAA "$sub.$d" "$RESOLVER" 2>/dev/null | grep -q .; then
      ttl=$(get_ttl "$sub.$d" CAA)
      if [ -n "${ttl:-}" ] && [ "$ttl" -gt "$FRESH_TTL" ]; then
        note "ADVARSEL" "rest på $sub.$d — CAA skal ligge på domænet selv"; bump 1
      fi
      # lav TTL = gammel cache, ignoreres bevidst
    fi
  done

  # ---------- 6. SPF ----------
  spf=$(dig +short TXT "$d" "$RESOLVER" 2>/dev/null | tr -d '"' | grep -c 'v=spf1' || true)
  [ "$spf" -eq 1 ] || { note "ADVARSEL" "$spf SPF-records (skal være præcis 1)"; bump 1; }
done

echo
echo "=============================================="
case $status in
  0) echo "RESULTAT: alt OK" ;;
  1) echo "RESULTAT: ADVARSLER — se ovenfor" ;;
  2) echo "RESULTAT: KRITISK — handling påkrævet" ;;
esac
echo "=============================================="
exit $status
