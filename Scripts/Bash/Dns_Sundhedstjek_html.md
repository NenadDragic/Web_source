# DNS Sundhedstjek HTML Report Script

Converts the plain-text output of the DNS check script into a styled HTML status page in the same visual style as the other report pages under `dragic.com` (e.g. `GPS_Status_Rapport.html`): cream background, Cormorant Garamond, quiet grey/amber/red status colours. It accepts both the Danish and the English output format of the check script. Intended to run right after the check script, daily via cron.

---

## Usage

```console
chmod +x Dns_Sundhedstjek_html.sh
./Dns_Sundhedstjek_html.sh report.txt      # converts an existing text report
./Dns_Sundhedstjek_html.sh                 # runs Sundhedstjech.sh and converts its output
```

Typically scheduled right after the check script:

```console
0 7 * * *  /path/to/Dns_Sundhedstjek_html.sh >> /var/log/dns-tjek-html.log 2>&1
```

Prerequisites:

- `Sundhedstjech.sh` present next to this script — only needed when no argument is given (see the note below about this file name).
- Write access to the output directory (created with `mkdir -p` if missing).

### Configuration

| Variable | Default | Meaning |
|---|---|---|
| `OUTFILE` | `index.html` next to the script | Path the generated HTML page is written to; can be overridden by setting the `OUTFILE` environment variable |

---

## What the Script Does

### Step 1 – Get the report text
With an argument, reads that file. Without one, runs `Sundhedstjech.sh` (found next to this script) and captures its stdout. Either way exits with status 3 if the input can't be obtained. Windows line endings (`\r`) are stripped from every line.

### Step 2 – Parse the report
Reads the text line by line and builds three parallel arrays (`ROW_DOMAIN`, `ROW_STATUS`, `ROW_TEXT`):
- `"--- domain"` starts a new section; a blank line resets the current domain back to `"General"` (used for notes that aren't tied to a specific domain, e.g. the CAA-leftover-check-skipped note).
- A line indented by exactly two spaces with a non-space label starts a new row. Labels are `ok`, `ADVARSEL`/`WARNING`, `KRITISK`/`CRITICAL` and `info`, matched case-insensitively.
- A line indented further, with no label, is appended to the previous row's text instead of starting a new one; blank continuation lines are ignored.
- The header line (`DNS health check — ...` or `DNS-sundhedstjek — ...`) and the `Resolver: ...` line are captured separately rather than turned into rows. Any `RESULT`/`RESULTAT`/`SAMLET` line is skipped — the result is not read from it.

### Step 3 – Determine the overall result badge
The result is derived from the parsed rows, not from a result line in the input:

| Rows | Badge | Exit code |
|---|---|---|
| No rows parsed | `UNKNOWN (no rows)` | `3` |
| At least one critical row | `CRITICAL (n)` | `2` |
| Otherwise, at least one warning row | `WARNINGS (n)` | `1` |
| Otherwise | `ALL OK` | `0` |

### Step 4 – Render the HTML
Builds the page: site header, an info block (resolver, thresholds, result badge, status legend), a meta line with the run and generation timestamps, then one table row per parsed check — colour-coded by status (`status-ok`/`status-warn`/`status-alarm`/`status-info`), with `warn`/`alarm` row classes tinting the whole row for warnings and critical findings.

### Step 5 – Write the file
Writes to a temp file (`mktemp "$OUTFILE.XXXXXX"`) in the target directory, sets permissions to `644` (matching the other files under `dragic.com`; `mktemp` otherwise creates it `600`), then `mv`s it into place atomically. If writing or moving the file fails, exits with status 3; the temp file is removed by an `EXIT` trap. Prints a one-line summary (row count and result) and exits with the code from Step 3.

---

## Notes

- Parses the check script's plain-text output format (two-space-indented `label  text` lines, continuation lines, `--- domain` section headers, `Resolver:` prefix) — a change to the wording of the labels or the spacing will break parsing here. The overall result no longer depends on a `RESULT:` line, so changes to that line are harmless.
- **Check-script file name.** The no-argument mode looks for `Sundhedstjech.sh`, and the script's own header comments use the same name, but the check script in this folder is `Dns_Sundhedstjek.sh`. Until that is aligned, run without an argument only if a file with that name exists, or pass a saved report as the argument.
- Not destructive: only ever writes to `$OUTFILE`, via a temp file plus an atomic `mv`; nothing else on disk is touched.
- The per-check detail text in each table row is copied straight from the check script's output, so the language of the details follows that script; only the status labels are normalised to English (`OK`, `WARNING`, `CRITICAL`, `INFO`).
- The default output is `index.html` next to the script (earlier versions wrote to `dragic.com/DNSSEC/index.html`); set `OUTFILE` to publish to a specific location.
- Safe to re-run any time; each run is independent and stateless.
