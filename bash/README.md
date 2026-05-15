# Bash Demos

| Script | Beschreibung |
|--------|--------------|
| [`github-recon.sh`](./github-recon.sh) | Original GitHub OSINT & Secrets Scanner |
| [`github-recon-v3.sh`](./github-recon-v3.sh) | Erweiterte Version: Token-Setup, Pagination, Severity-Levels, Wayback Machine, Activity-Heatmap, CI/CD-Workflow-Scan, Diff-Modus, noseyparker/gitleaks/trufflehog-Integration |

## github-recon-v3.sh — Was ist neu?

| Bereich | Verbesserung |
|---------|--------------|
| **Robustheit** | API-Error-Handling (kein Crash bei Rate-Limit-Antworten), vollständige Pagination, Retry mit Backoff bei 403/429 |
| **Performance** | Step "Sensitive Files" von 1800 auf 18 API-Calls reduziert (`user:X filename:Y` statt Repo×Pattern), Auto-Wait bis Rate-Limit-Reset |
| **Mehr OSINT** | Public SSH-/GPG-Keys (`.keys`/`.gpg`), Organisationen, Aktivitäts-Heatmap mit Zeitzonen-Inferenz, Wayback Machine für gelöschte Repos |
| **Mehr Security** | CI/CD-Workflow-YAML-Scan (häufige Secret-Quelle), Internal-Endpoint-Detection (`192.168.*`, `.local`, `localhost:*`) |
| **Deep Scan** | noseyparker/gitleaks/trufflehog werden tatsächlich aufgerufen (statt nur erwähnt) |
| **Workflow** | Interaktiver Token-Setup mit `--setup-token` (gh-CLI-Auto-Detect), Diff-Modus gegen vorheriges Findings-JSON |
| **CI-Tauglich** | Severity-Levels (CRITICAL/HIGH/MEDIUM/LOW/INFO), Exit-Codes (40/30/20/10/0), JSON-Output zusätzlich zu Markdown |

### Quick Start

```bash
chmod +x github-recon-v3.sh

# Interaktiver Token-Setup mit Anleitung & Links
./github-recon-v3.sh --setup-token

# Quick-Scan (~10s, keine Search-API-Calls)
./github-recon-v3.sh <user> --mode=quick

# Standard (Default, ~3min mit Token)
./github-recon-v3.sh <user>

# Deep (Clone aller Repos + Full-History-Secret-Scan)
./github-recon-v3.sh <user> --mode=deep

# Diff gegen letzten Scan
./github-recon-v3.sh <user> --diff-from=/path/to/old-findings.json
```

### Voraussetzungen

- `bash >= 4.0` (macOS: `brew install bash`)
- `curl`, `jq`, `git`
- Optional: `noseyparker` (10× schneller als trufflehog), `gitleaks`, `trufflehog`, `gh` CLI
- Optional: GitHub Personal Access Token (5000 statt 60 req/h)

### Disclaimer

Nur für **Bildungszwecke & Self-Audits**. Scanne keine GitHub-Accounts, für die du keine Erlaubnis hast.
