# DNS Sundhedstjek HTML Report Script

Converts the plain-text output of `Dns_Sundhedstjek.sh` into a styled HTML status page in the same visual style as the other report pages under `dragic.com` (e.g. `GPS_Status_Rapport.html`): cream background, Cormorant Garamond, quiet grey/amber/red status colours. Intended to run right after the check script, daily via cron.

---

## Usage

```console
chmod +x Dns_Sundhedstjek_html.sh
./Dns_Sundhedstjek_html.sh                 # runs Dns_Sundhedstjek.sh and generates the HTML
./Dns_Sundhedstjek_html.sh report.txt      # converts an existing text report instead
```

Typically scheduled right after `Dns_Sundhedstjek.sh`:

```console
0 7 * * *  /path/to/Dns_Sundhedstjek_html.sh >> /var/log/dns-tjek-html.log 2>&1
```

Prerequisites:

- `Dns_Sundhedstjek.sh` present next to this script — only needed when no argument is given.
- Write access to the output directory (created with `mkdir -p` if missing).

### Configuration

| Variable | Default | Meaning |
|---|---|---|
| `OUTFILE` | `dragic.com/DNSSEC/index.html` (relative to the repo, resolved from the script's own location) | Path the generated HTML page is written to; can be overridden by setting the `OUTFILE` environment variable |

---

## What the Script Does

### Step 1 – Get the report text
With an argument, reads that file. Without one, runs `Dns_Sundhedstjek.sh` (found next to this script) and captures its stdout. Either way exits with status 1 if the input can't be obtained.

### Step 2 – Parse the report
Reads the text line by line and builds three parallel arrays (`ROW_DOMAIN`, `ROW_STATUS`, `ROW_TEXT`):
- `"--- domain"` starts a new section; a blank line resets the current domain back to `"General"` (used for notes that aren't tied to a specific domain, e.g. the CAA-leftover-check-skipped note).
- A line indented by exactly two spaces with a non-space label (`ok`, `WARNING`, `CRITICAL`, `info`) starts a new row.
- A line indented further, with no label (the continuation format `Dns_Sundhedstjek.sh`'s `note()` helper prints for multi-line messages), is appended to the previous row's text instead of starting a new one.
- The header line (`DNS health check — ...`), the `Resolver: ...` line, and the final `RESULT: ...` line are captured separately rather than turned into rows.

### Step 3 – Determine the overall result badge
Matches the captured `RESULT:` line against `all OK` / `WARNINGS` / `CRITICAL` to pick a badge label, a CSS class, and an exit code (0/1/2). Anything unrecognised falls back to a warning-coloured `UNKNOWN` badge and exit code 3.

### Step 4 – Render the HTML
Builds the page: site header, an info block (resolver, thresholds, result badge, status legend), a meta line with the run and generation timestamps, then one table row per parsed check — colour-coded by status (`status-ok`/`status-warn`/`status-alarm`/`status-info`), with `warn`/`alarm` row classes tinting the whole row for warnings and critical findings.

### Step 5 – Write the file
Writes to a temp file (`mktemp "$OUTFILE.XXXXXX"`) in the target directory, sets permissions to `644` (matching the other files under `dragic.com`; `mktemp` otherwise creates it `600`), then `mv`s it into place atomically. Prints a one-line summary (row count and result) and exits with the code from Step 3.

---

## Notes

- Parses `Dns_Sundhedstjek.sh`'s plain-text output format exactly (two-space-indented `label  text` lines, blank-label continuation lines, `--- domain` section headers, `Resolver:`/`RESULT:` prefixes) — a change to that script's wording or spacing will silently break parsing here.
- Not destructive: only ever writes to `$OUTFILE`, via a temp file plus an atomic `mv`; nothing else on disk is touched.
- The per-check detail text in each table row is copied straight from `Dns_Sundhedstjek.sh`'s output, so this page is only ever as multilingual as that script's output is.
- Safe to re-run any time; each run is independent and stateless.
