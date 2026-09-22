# DNS Sundhedstjek Script

Checks DNSSEC, DMARC, CAA, and SPF for seven fixed domains and reports OK / warning / critical per check. Its main purpose is catching expiring DNSSEC signatures early: e-studio auto-resigns records but does not rotate KSKs, so if their signing job stops, signatures expire and the domain becomes invisible to validating resolvers. Intended to run daily via cron.

---

## Usage

```console
chmod +x Dns_Sundhedstjek.sh
./Dns_Sundhedstjek.sh
```

Typically scheduled via cron:

```console
0 7 * * *  /path/to/Dns_Sundhedstjek.sh >> /var/log/dns-tjek.log 2>&1
```

Prerequisites:

- `dig` (from `bind9-dnsutils` / `dnsutils`) — the script checks for it at startup and exits with status 2 if missing.
- Network access to the hardcoded resolver `1.1.1.1` (Cloudflare) on port 53.
- No arguments are taken; the domain list is fixed in the script.

### Configuration (top of script)

| Variable | Default | Meaning |
|---|---|---|
| `DOMAINS` | 7 hardcoded domains (`ahlstrom-itsec.com`, `ahlstrom-itsec.dk`, `coldicewarmblood.info`, `dragic-playground.info`, `dragic.com`, `taenkeboksen.dk`, `xn--tnkeboksen-d6a.dk`) | Domains checked each run |
| `RESOLVER` | `@1.1.1.1` | Resolver `dig` queries against |
| `WARN_DAYS` | `5` | Warn when DNSSEC signatures expire in fewer than this many days |
| `CRIT_DAYS` | `2` | Critical when signatures expire in fewer than this many days |
| `EXPECTED_CA` | `letsencrypt.org` | CA name expected in the CAA `issue` tag |
| `FRESH_TTL` | `13000` | TTL above which a CAA answer is treated as fresh rather than cached (e-studio's zones cap CAA TTL at 14400) |
| `EXPECTED_DS` | associative array, 1 or 2 per domain | Expected number of DS records per domain; `.dk` domains get 2 because DK Hostmaster computes an extra SHA-384 variant from the SHA-256 digest |

---

## What the Script Does

### Step 1 – Prerequisite check
Verifies `dig` is on `PATH`; exits with status 2 and an error message if not.

### Step 2 – Loop over domains
For each domain in `DOMAINS`, runs the following checks in order and tracks the worst severity seen (`status`, via the `bump` helper: 0=OK, 1=warning, 2=critical).

### Step 3 – SERVFAIL check (first, before anything else)
Queries the domain's A record and checks the response's `status:` code. If it's `SERVFAIL`, this is reported first as critical (likely a broken DNSSEC chain), with a suggested diagnostic command and the emergency fix (remove the DS record at the registrar), then skips the remaining checks for that domain (`continue`).

### Step 4 – A-record reachability
If `dig +short A` returns nothing IP-like, reports critical ("domain does not answer with an A record") and skips the rest for that domain.

### Step 5 – DNSSEC
If a DS record exists for the domain:
- Reads the SOA RRSIG's expiration field and computes days until expiry, escalating to critical (`< CRIT_DAYS`) or warning (`< WARN_DAYS`), or reporting OK if further out. If the expiry field can't be parsed, reports a warning.
- Counts DS records and compares to `EXPECTED_DS`; a mismatch is reported as a warning (likely an extra/wrong digest).
- Checks whether an A-record query set the `ad` (authenticated data) flag; missing flag is reported as a warning (may just be cache).

If no DS record exists, reports an informational line that DNSSEC isn't active for that domain (not a warning).

### Step 6 – DMARC
Reads `_dmarc.<domain>` TXT records. Zero `v=DMARC1` records or more than one is critical (per RFC 7489, multiple records mean no policy applies). Exactly one record is checked further: reports OK if it mentions `vali.email` (Valimail reporting), warning if it has `rua=` but not Valimail, critical if it has no `rua=` at all (no reports delivered).

### Step 7 – CAA
Reads the domain's CAA records. No CAA record: warning. CAA present without an `issue` tag: critical (per RFC 8659, this means no CA may issue a certificate). `issue` tag present but doesn't mention `EXPECTED_CA`: critical (renewal will fail). Otherwise: OK.

Also checks `issue`/`issuewild`/`iodef` CAA leftovers on the subdomains `issue.<domain>`, `issuewild.<domain>`, `iodef.<domain>` — flagged as a warning only if the answer's TTL is above `FRESH_TTL` (to avoid flagging stale cached answers).

### Step 8 – SPF
Counts TXT records containing `v=spf1`; anything other than exactly 1 is reported as a warning.

### Step 9 – Summary
After all domains are processed, prints an overall result line based on the worst `status` seen (OK / warnings / critical) and exits with that status code.

---

## Notes

- Not destructive: the script only queries DNS via `dig`; it makes no changes to any system or zone.
- Safe to re-run any time; each run is independent and stateless (no cache/state file between runs).
- Output messages (including the "CRITICAL"/"WARNING"/"ok"/"info" labels and summary) are in English.
- Hardcoded values: the domain list, the resolver (`1.1.1.1`), all thresholds (`WARN_DAYS`, `CRIT_DAYS`, `FRESH_TTL`), the expected CA, and the per-domain expected DS counts. Adding/removing a domain requires editing both `DOMAINS` and `EXPECTED_DS`.
- Relies on parsing `dig`'s plain-text output (e.g. RRSIG expiration field position, `status:` field in the header) — a change in `dig`/BIND output formatting could silently break parsing.
- Uses `set -uo pipefail` but not `-e`; individual command failures inside the loop are handled explicitly via checks rather than aborting the whole script.
