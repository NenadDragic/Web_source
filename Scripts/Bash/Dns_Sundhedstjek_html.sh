#!/usr/bin/env bash
# Dns_Sundhedstjek_html.sh — turns the output of Sundhedstjech.sh into an HTML report
# in the same style as the other status pages under dragic.com (e.g. GPS_Status_Rapport.html):
# cream background, Cormorant Garamond, quiet grey/red/amber status colours.
#
# Accepts both the Danish and the English output format of the check script:
#   header  "DNS-sundhedstjek — ..."  or  "DNS health check — ..."
#   labels  ok / ADVARSEL|WARNING / KRITISK|CRITICAL / info  (case-insensitive)
# The overall result is derived from the rows themselves, so it does not depend
# on a particular "RESULT:"/"RESULTAT:" line.
#
# Usage:
#   ./Dns_Sundhedstjek_html.sh report.txt       converts an existing text report
#   ./Dns_Sundhedstjek_html.sh                  runs Sundhedstjech.sh and converts its output
#
# Output: $OUTFILE (default: index.html next to this script)
# Exit:   0 = all OK, 1 = warnings, 2 = critical, 3 = no rows could be parsed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTFILE="${OUTFILE:-$SCRIPT_DIR/index.html}"

if [ $# -ge 1 ]; then
  input_file="$1"
  [ -f "$input_file" ] || { echo "ERROR: $input_file does not exist." >&2; exit 3; }
  report="$(cat "$input_file")"
else
  check_script="$SCRIPT_DIR/Sundhedstjech.sh"
  [ -f "$check_script" ] || { echo "ERROR: can't find Sundhedstjech.sh next to this script." >&2; exit 3; }
  report="$(bash "$check_script")"
fi

html_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

# --- Parse the text report -------------------------------------------------------
# Line format:
#   "--- domain"                      new section
#   "  <label>   text"                status line
#   "              text"              continuation of the previous status line
#   ""                                separates sections — resets the "current domain"
declare -a ROW_DOMAIN=() ROW_STATUS=() ROW_TEXT=()
current_domain="General"
header_line=""
resolver_line=""

while IFS= read -r line; do
  line="${line%$'\r'}"
  case "$line" in
    "")
      current_domain="General"
      continue
      ;;
    "--- "*)
      current_domain="${line#--- }"
      continue
      ;;
    "="*)
      continue
      ;;
    "DNS health check"*|"DNS-sundhedstjek"*|"DNS-Sundhedstjek"*)
      header_line="$line"
      continue
      ;;
    "Resolver:"*)
      resolver_line="$line"
      continue
      ;;
    "RESULT"*|"RESULTAT"*|"Resultat"*|"SAMLET"*|"Samlet"*)
      continue
      ;;
  esac

  rest="${line#  }"
  [ "$rest" = "$line" ] && continue   # line without the expected 2-space indent — skip it

  if [ -n "$rest" ] && [ "${rest:0:1}" != " " ]; then
    label="${rest%% *}"
    text="${rest#"$label"}"
    text="${text#"${text%%[![:space:]]*}"}"
    ROW_DOMAIN+=("$current_domain")
    ROW_STATUS+=("$label")
    ROW_TEXT+=("$text")
  else
    text="${rest#"${rest%%[![:space:]]*}"}"
    if [ ${#ROW_TEXT[@]} -gt 0 ] && [ -n "$text" ]; then
      idx=$(( ${#ROW_TEXT[@]} - 1 ))
      ROW_TEXT[$idx]="${ROW_TEXT[$idx]} $text"
    fi
  fi
done <<< "$report"

# --- Overall result badge: derived from the rows themselves ----------------------
n_crit=0; n_warn=0
for s in ${ROW_STATUS[@]+"${ROW_STATUS[@]}"}; do
  case "${s^^}" in
    CRITICAL|KRITISK) n_crit=$((n_crit+1)) ;;
    WARNING|ADVARSEL) n_warn=$((n_warn+1)) ;;
  esac
done

if   [ ${#ROW_STATUS[@]} -eq 0 ]; then badge_class="status-warn";  badge_text="UNKNOWN (no rows)";  exit_code=3
elif [ "$n_crit" -gt 0 ];         then badge_class="status-alarm"; badge_text="CRITICAL ($n_crit)"; exit_code=2
elif [ "$n_warn" -gt 0 ];         then badge_class="status-warn";  badge_text="WARNINGS ($n_warn)"; exit_code=1
else                                   badge_class="status-ok";    badge_text="ALL OK";             exit_code=0
fi

generated="$(date '+%Y-%m-%d %H:%M %Z')"
year="$(date '+%Y')"
if [ -n "$header_line" ] && [[ "$header_line" == *" — "* ]]; then
  timestamp="${header_line#* — }"
else
  timestamp="$generated"
fi
resolver_text="${resolver_line#Resolver: }"
[ -n "$resolver_text" ] || resolver_text="—"

# --- Build HTML --------------------------------------------------------------------
mkdir -p "$(dirname "$OUTFILE")"
tmpfile="$(mktemp "${OUTFILE}.XXXXXX")" || { echo "ERROR: cannot create temp file next to $OUTFILE" >&2; exit 3; }
trap 'rm -f "$tmpfile"' EXIT

{
cat <<HEADER
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>DNS Health Check — Dragic.com</title>
  <link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:ital,wght@0,300;0,400;1,300&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background-color: #f7f5f1;
      font-family: 'Cormorant Garamond', Georgia, serif;
      color: #1a1a1a;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 4rem 2rem 6rem;
    }
    main { max-width: 900px; width: 100%; animation: fadein 1.4s ease both; }
    @keyframes fadein {
      from { opacity: 0; transform: translateY(14px); }
      to   { opacity: 1; transform: translateY(0); }
    }
    .site-name {
      display: block;
      font-size: 0.75rem; font-weight: 300; letter-spacing: 0.3em;
      text-transform: uppercase; color: #999; margin-bottom: 3.5rem; text-align: center;
      text-decoration: none; transition: color 0.2s;
    }
    .site-name:hover { color: #666; }
    h1 { font-size: 2.6rem; font-weight: 300; letter-spacing: 0.03em; margin-bottom: 0.4rem; line-height: 1.2; }
    .tagline { font-size: 1.05rem; font-style: italic; font-weight: 300; color: #777; margin-bottom: 2.8rem; }
    .divider { width: 40px; height: 1px; background: #ccc; margin: 0 0 2.8rem 0; }
    .meta {
      font-size: 0.75rem; font-weight: 300; letter-spacing: 0.15em;
      text-transform: uppercase; color: #aaa; margin-bottom: 2rem;
    }
    table { width: 100%; border-collapse: collapse; }
    thead tr { border-bottom: 1px solid #ccc; }
    thead th {
      font-size: 0.7rem; font-weight: 300; letter-spacing: 0.25em;
      text-transform: uppercase; color: #999; padding: 0 0.5rem 0.9rem; text-align: left;
    }
    thead th:first-child { padding-left: 0; }
    tbody tr { border-bottom: 1px solid #e8e4de; transition: background 0.15s; }
    tbody tr:hover { background: #f0ede8; }
    tbody tr.alarm { background: #fdf0f0; }
    tbody tr.alarm:hover { background: #f9e4e4; }
    tbody tr.warn { background: #fdf8ee; }
    tbody tr.warn:hover { background: #faf0dc; }
    tbody td {
      font-size: 1.0rem; font-weight: 300; line-height: 1.5;
      padding: 0.85rem 0.5rem; color: #333; vertical-align: top;
    }
    tbody td:first-child { padding-left: 0; }
    .status-ok { color: #888; }
    .status-alarm { font-weight: 400; color: #b94a48; }
    .status-warn { font-weight: 400; color: #c07a2a; }
    .status-info { font-style: italic; color: #6a7c8c; }
    .info-block {
      border-top: 1px solid #e8e4de;
      margin-bottom: 2.2rem;
    }
    .info-row {
      display: flex;
      gap: 1.5rem;
      padding: 0.7rem 0;
      border-bottom: 1px solid #e8e4de;
      align-items: baseline;
    }
    .info-label {
      font-size: 0.68rem;
      font-weight: 300;
      letter-spacing: 0.25em;
      text-transform: uppercase;
      color: #aaa;
      min-width: 80px;
      flex-shrink: 0;
    }
    .info-text {
      font-size: 0.92rem;
      font-weight: 300;
      color: #555;
      font-style: italic;
      line-height: 1.55;
    }
    .badge {
      display: inline-block;
      font-size: 0.95rem;
      font-weight: 400;
      letter-spacing: 0.1em;
    }
    .legend-ok   { color: #888; margin-right: 1.2rem; }
    .legend-warn { color: #c07a2a; margin-right: 1.2rem; }
    .legend-alarm { color: #b94a48; }
    footer {
      margin-top: 5rem; font-size: 0.7rem; font-weight: 300;
      letter-spacing: 0.18em; color: #bbb; text-align: center;
    }
  </style>
</head>
<body>
  <main>
    <a href="https://www.dragic.com" class="site-name">Dragic.com</a>
    <h1>DNS Health Check</h1>
    <p class="tagline">DNSSEC · DMARC · CAA · SPF — domain status</p>
    <div class="divider"></div>

    <div class="info-block">
      <div class="info-row">
        <span class="info-label">Resolver</span>
        <span class="info-text">$(html_escape "$resolver_text")</span>
      </div>
      <div class="info-row">
        <span class="info-label">Thresholds</span>
        <span class="info-text">DNSSEC signatures: warning under 5 days to expiry, critical under 2 days &nbsp;·&nbsp; CAA must allow letsencrypt.org</span>
      </div>
      <div class="info-row">
        <span class="info-label">Result</span>
        <span class="info-text"><span class="badge $badge_class">$(html_escape "$badge_text")</span></span>
      </div>
      <div class="info-row">
        <span class="info-label">Status</span>
        <span class="info-text">
          <span class="legend-ok">&#9679; OK</span>
          <span class="legend-warn">&#9679; Warning</span>
          <span class="legend-alarm">&#9679; Critical</span>
        </span>
      </div>
    </div>

    <p class="meta">Run: $(html_escape "$timestamp") &nbsp;·&nbsp; Generated: $generated</p>
    <table>
      <thead>
        <tr>
          <th>Domain</th>
          <th>Status</th>
          <th>Details</th>
        </tr>
      </thead>
      <tbody>
HEADER

for i in ${ROW_DOMAIN[@]+"${!ROW_DOMAIN[@]}"}; do
  status="${ROW_STATUS[$i]}"
  case "${status^^}" in
    OK)               row_class="";      cell_class="status-ok";    label_text="OK" ;;
    WARNING|ADVARSEL) row_class="warn";  cell_class="status-warn";  label_text="WARNING" ;;
    CRITICAL|KRITISK) row_class="alarm"; cell_class="status-alarm"; label_text="CRITICAL" ;;
    INFO)             row_class="";      cell_class="status-info";  label_text="INFO" ;;
    *)                row_class="";      cell_class="status-info";  label_text="$(html_escape "$status")" ;;
  esac
  printf '        <tr class="%s"><td>%s</td><td class="%s">%s</td><td>%s</td></tr>\n' \
    "$row_class" \
    "$(html_escape "${ROW_DOMAIN[$i]}")" \
    "$cell_class" \
    "$label_text" \
    "$(html_escape "${ROW_TEXT[$i]}")"
done

cat <<FOOTER
      </tbody>
    </table>
  </main>
  <footer>© $year Nenad Ahlstrøm Dragic</footer>
</body>
</html>
FOOTER
} > "$tmpfile" || { echo "ERROR: writing $tmpfile failed" >&2; exit 3; }

chmod 644 "$tmpfile"
mv "$tmpfile" "$OUTFILE" || { echo "ERROR: cannot move report to $OUTFILE" >&2; exit 3; }
trap - EXIT
echo "Wrote $OUTFILE (${#ROW_DOMAIN[@]} rows, result: $badge_text)"
exit "$exit_code"