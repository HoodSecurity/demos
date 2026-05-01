#!/usr/bin/env bash
# ============================================================================
# github-recon.sh – GitHub OSINT & Secrets Scanner
# das gute ding wurde gevibe coded , erfüllt aber seinen zweck :P
# Ziel: Eigene GitHub-Repos auf exponierte Daten prüfen
# Nutzung: ./github-recon.sh <github-username> [--clone]
# 
# Flags:
#   --clone    Klont alle public Repos lokal und scannt Git-History
#              (ohne Flag: nur API-basierte Analyse, kein Clone)
# 
# Voraussetzungen:
#   - curl, jq, git (Standard)
#   - Optional: gitleaks, trufflehog (für Deep-Scans)
#   - Optional: GITHUB_TOKEN env-var für höheres API-Rate-Limit
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CLONE_REPOS=false
USERNAME=""
WORKDIR=""
REPORT_FILE=""

# --- Argument Parsing ---
for arg in "$@"; do
    case "$arg" in
        --clone) CLONE_REPOS=true ;;
        --help|-h)
            echo "Nutzung: $0 <github-username> [--clone]"
            echo "  --clone  Klont Repos und scannt Git-History (langsamer, gründlicher)"
            exit 0
            ;;
        *) USERNAME="$arg" ;;
    esac
done

if [[ -z "$USERNAME" ]]; then
    echo -e "${RED}Fehler: GitHub-Username als Argument angeben.${NC}"
    echo "Nutzung: $0 <github-username> [--clone]"
    exit 1
fi

WORKDIR="/tmp/github-recon-${USERNAME}"
REPORT_FILE="${WORKDIR}/recon-report.md"
mkdir -p "$WORKDIR"

# GitHub API Header
AUTH_HEADER=""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
    echo -e "${GREEN}[+] GitHub Token erkannt – höheres Rate-Limit aktiv${NC}"
fi

api_get() {
    local url="$1"
    if [[ -n "$AUTH_HEADER" ]]; then
        curl -sL -H "$AUTH_HEADER" -H "Accept: application/vnd.github+json" "$url"
    else
        curl -sL -H "Accept: application/vnd.github+json" "$url"
    fi
}

# ============================================================================
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           GitHub OSINT Recon – $USERNAME"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# --- Report initialisieren ---
cat > "$REPORT_FILE" << EOF
# GitHub Recon Report: $USERNAME
**Datum:** $(date '+%Y-%m-%d %H:%M:%S')
**Modus:** $(if $CLONE_REPOS; then echo "Deep Scan (mit Clone)"; else echo "API-Only (ohne Clone)"; fi)

---

EOF

# ============================================================================
# 1. PROFIL-ANALYSE
# ============================================================================
echo -e "${BOLD}[1/7] Profil-Analyse${NC}"

PROFILE=$(api_get "https://api.github.com/users/${USERNAME}")

REAL_NAME=$(echo "$PROFILE" | jq -r '.name // "nicht gesetzt"')
BIO=$(echo "$PROFILE" | jq -r '.bio // "nicht gesetzt"')
COMPANY=$(echo "$PROFILE" | jq -r '.company // "nicht gesetzt"')
LOCATION=$(echo "$PROFILE" | jq -r '.location // "nicht gesetzt"')
BLOG=$(echo "$PROFILE" | jq -r '.blog // "nicht gesetzt"')
EMAIL_PUBLIC=$(echo "$PROFILE" | jq -r '.email // "nicht gesetzt"')
TWITTER=$(echo "$PROFILE" | jq -r '.twitter_username // "nicht gesetzt"')
CREATED=$(echo "$PROFILE" | jq -r '.created_at // "unbekannt"')
PUBLIC_REPOS=$(echo "$PROFILE" | jq -r '.public_repos // 0')
FOLLOWERS=$(echo "$PROFILE" | jq -r '.followers // 0')

echo -e "  Name:       $REAL_NAME"
echo -e "  Bio:        $BIO"
echo -e "  Company:    $COMPANY"
echo -e "  Location:   $LOCATION"
echo -e "  Blog:       $BLOG"
echo -e "  E-Mail:     $EMAIL_PUBLIC"
echo -e "  Twitter:    $TWITTER"
echo -e "  Erstellt:   $CREATED"
echo -e "  Repos:      $PUBLIC_REPOS"
echo -e "  Followers:  $FOLLOWERS"

# Risikobewertung Profil
PROFILE_RISKS=""
[[ "$REAL_NAME" != "nicht gesetzt" ]] && PROFILE_RISKS+="  - ⚠️  Klarname im Profil: $REAL_NAME\n"
[[ "$COMPANY" != "nicht gesetzt" ]] && PROFILE_RISKS+="  - ⚠️  Arbeitgeber sichtbar: $COMPANY\n"
[[ "$LOCATION" != "nicht gesetzt" ]] && PROFILE_RISKS+="  - ⚠️  Standort sichtbar: $LOCATION\n"
[[ "$EMAIL_PUBLIC" != "nicht gesetzt" ]] && PROFILE_RISKS+="  - 🔴 E-Mail öffentlich: $EMAIL_PUBLIC\n"

if [[ -n "$PROFILE_RISKS" ]]; then
    echo -e "\n${YELLOW}  Findings:${NC}"
    echo -e "$PROFILE_RISKS"
fi

cat >> "$REPORT_FILE" << EOF
## 1. Profil-Analyse

| Feld | Wert | Risiko |
|------|------|--------|
| Name | $REAL_NAME | $(if [[ "$REAL_NAME" != "nicht gesetzt" ]]; then echo "⚠️ Klarname exponiert"; else echo "✅"; fi) |
| Bio | $BIO | Info |
| Company | $COMPANY | $(if [[ "$COMPANY" != "nicht gesetzt" ]]; then echo "⚠️ Arbeitgeber sichtbar"; else echo "✅"; fi) |
| Location | $LOCATION | $(if [[ "$LOCATION" != "nicht gesetzt" ]]; then echo "⚠️ Standort sichtbar"; else echo "✅"; fi) |
| Blog | $BLOG | Info |
| E-Mail | $EMAIL_PUBLIC | $(if [[ "$EMAIL_PUBLIC" != "nicht gesetzt" ]]; then echo "🔴 Öffentlich"; else echo "✅"; fi) |
| Twitter | $TWITTER | Info |
| Erstellt | $CREATED | Info |
| Public Repos | $PUBLIC_REPOS | Info |

EOF

# ============================================================================
# 2. REPO-ANALYSE
# ============================================================================
echo -e "\n${BOLD}[2/7] Repository-Analyse${NC}"

REPOS_JSON=$(api_get "https://api.github.com/users/${USERNAME}/repos?per_page=100&sort=updated")
REPO_COUNT=$(echo "$REPOS_JSON" | jq length)
echo -e "  Gefundene Repos: $REPO_COUNT"

cat >> "$REPORT_FILE" << EOF
## 2. Repositories ($REPO_COUNT gefunden)

| Repo | Sterne | Forks | Sprache | Beschreibung |
|------|--------|-------|---------|--------------|
EOF

echo "$REPOS_JSON" | jq -r '.[] | "| [\(.name)](https://github.com/'"$USERNAME"'/\(.name)) | \(.stargazers_count) | \(.forks_count) | \(.language // "-") | \(.description // "-") |"' >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# ============================================================================
# 3. COMMIT-E-MAIL-EXTRAKTION (via API Events)
# ============================================================================
echo -e "\n${BOLD}[3/7] Commit-E-Mail-Extraktion${NC}"

EVENTS=$(api_get "https://api.github.com/users/${USERNAME}/events/public?per_page=100")
COMMIT_EMAILS=$(echo "$EVENTS" | jq -r '
    [.[] | select(.type == "PushEvent") | .payload.commits[]? | .author.email] 
    | unique | .[]' 2>/dev/null || echo "")

COMMIT_NAMES=$(echo "$EVENTS" | jq -r '
    [.[] | select(.type == "PushEvent") | .payload.commits[]? | .author.name] 
    | unique | .[]' 2>/dev/null || echo "")

cat >> "$REPORT_FILE" << EOF
## 3. Commit-Metadaten (aus Public Events)

### E-Mail-Adressen in Commits
EOF

if [[ -n "$COMMIT_EMAILS" ]]; then
    echo -e "${YELLOW}  Gefundene E-Mail-Adressen:${NC}"
    while IFS= read -r email; do
        echo -e "    - $email"
        # Prüfe ob es eine noreply-Adresse ist
        if [[ "$email" == *"noreply.github.com"* ]]; then
            echo "- ✅ \`$email\` (GitHub noreply – sicher)" >> "$REPORT_FILE"
        else
            echo "- 🔴 \`$email\` (persönliche E-Mail exponiert!)" >> "$REPORT_FILE"
        fi
    done <<< "$COMMIT_EMAILS"
else
    echo -e "  ${GREEN}Keine E-Mails in öffentlichen Events gefunden${NC}"
    echo "Keine E-Mails in öffentlichen Events gefunden." >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "### Commit-Autornamen" >> "$REPORT_FILE"

if [[ -n "$COMMIT_NAMES" ]]; then
    echo -e "\n${YELLOW}  Gefundene Commit-Autornamen:${NC}"
    while IFS= read -r name; do
        echo -e "    - $name"
        echo "- \`$name\`" >> "$REPORT_FILE"
    done <<< "$COMMIT_NAMES"
fi
echo "" >> "$REPORT_FILE"

# ============================================================================
# 4. SENSITIVE-DATEI-SCAN (via API)
# ============================================================================
echo -e "\n${BOLD}[4/7] Sensitive-Datei-Scan (API-basiert)${NC}"

SENSITIVE_PATTERNS=(
    ".env"
    ".env.local"
    ".env.production"
    "docker-compose.yml"
    "Dockerfile"
    ".htaccess"
    ".htpasswd"
    "wp-config.php"
    "config.json"
    "config.yml"
    "credentials"
    "id_rsa"
    "id_ed25519"
    ".npmrc"
    ".pypirc"
    "kubeconfig"
    "terraform.tfvars"
    ".aws/credentials"
)

cat >> "$REPORT_FILE" << EOF
## 4. Sensitive Dateien

EOF

FOUND_SENSITIVE=0

for repo_name in $(echo "$REPOS_JSON" | jq -r '.[].name'); do
    for pattern in "${SENSITIVE_PATTERNS[@]}"; do
        # GitHub Code Search API
        SEARCH_RESULT=$(api_get "https://api.github.com/search/code?q=filename:${pattern}+repo:${USERNAME}/${repo_name}" 2>/dev/null || echo '{"total_count":0}')
        COUNT=$(echo "$SEARCH_RESULT" | jq -r '.total_count // 0')
        
        if [[ "$COUNT" -gt 0 ]]; then
            echo -e "  ${RED}[!] ${repo_name}: ${pattern} gefunden (${COUNT}x)${NC}"
            echo "- 🔴 **${repo_name}**: \`${pattern}\` gefunden (${COUNT}x)" >> "$REPORT_FILE"
            FOUND_SENSITIVE=$((FOUND_SENSITIVE + 1))
        fi
    done
    
    # Rate-Limit-Schutz
    sleep 0.5
done

if [[ "$FOUND_SENSITIVE" -eq 0 ]]; then
    echo -e "  ${GREEN}Keine offensichtlich sensitiven Dateien gefunden${NC}"
    echo "✅ Keine offensichtlich sensitiven Dateien in Repos gefunden." >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ============================================================================
# 5. SECRET-PATTERN-SCAN (via GitHub Code Search)
# ============================================================================
echo -e "\n${BOLD}[5/7] Secret-Pattern-Scan${NC}"

declare -A SECRET_PATTERNS=(
    ["AWS Access Key"]="AKIA"
    ["GitHub Token"]="ghp_"
    ["GitHub OAuth"]="gho_"
    ["Slack Token"]="xoxb-"
    ["Slack Webhook"]="hooks.slack.com"
    ["Anthropic API Key"]="sk-ant-"
    ["OpenAI API Key"]="sk-proj-"
    ["Stripe Key"]="sk_live_"
    ["Stripe Test Key"]="sk_test_"
    ["Private Key"]="PRIVATE KEY"
    ["Password Assignment"]="password="
    ["DB Connection String"]="postgresql://"
    ["MongoDB URI"]="mongodb+srv://"
    ["JWT Secret"]="JWT_SECRET"
    ["API_KEY variable"]="API_KEY="
    ["Sendgrid"]="SG."
    ["Twilio"]="TWILIO"
)

cat >> "$REPORT_FILE" << EOF
## 5. Secret-Pattern-Scan

EOF

FOUND_SECRETS=0

for label in "${!SECRET_PATTERNS[@]}"; do
    pattern="${SECRET_PATTERNS[$label]}"
    SEARCH_RESULT=$(api_get "https://api.github.com/search/code?q=${pattern}+user:${USERNAME}" 2>/dev/null || echo '{"total_count":0}')
    COUNT=$(echo "$SEARCH_RESULT" | jq -r '.total_count // 0')
    
    if [[ "$COUNT" -gt 0 ]]; then
        REPOS_WITH_SECRET=$(echo "$SEARCH_RESULT" | jq -r '.items[].repository.name' 2>/dev/null | sort -u | tr '\n' ', ' | sed 's/,$//')
        echo -e "  ${RED}[!] ${label}: ${COUNT} Treffer in [${REPOS_WITH_SECRET}]${NC}"
        echo "- 🔴 **${label}** (\`${pattern}\`): ${COUNT} Treffer in ${REPOS_WITH_SECRET}" >> "$REPORT_FILE"
        FOUND_SECRETS=$((FOUND_SECRETS + 1))
    fi
    
    # Rate-Limit-Schutz (Search API ist streng limitiert)
    sleep 2
done

if [[ "$FOUND_SECRETS" -eq 0 ]]; then
    echo -e "  ${GREEN}Keine Secret-Patterns in Code gefunden${NC}"
    echo "✅ Keine Secret-Patterns in öffentlichem Code gefunden." >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ============================================================================
# 6. GIST-ANALYSE
# ============================================================================
echo -e "\n${BOLD}[6/7] Gist-Analyse${NC}"

GISTS=$(api_get "https://api.github.com/users/${USERNAME}/gists?per_page=100")
GIST_COUNT=$(echo "$GISTS" | jq length)
echo -e "  Öffentliche Gists: $GIST_COUNT"

cat >> "$REPORT_FILE" << EOF
## 6. Öffentliche Gists ($GIST_COUNT)

EOF

if [[ "$GIST_COUNT" -gt 0 ]]; then
    echo "$GISTS" | jq -r '.[] | "- [\(.description // .id)](\(.html_url)) – Dateien: \([.files | keys[]] | join(", "))"' >> "$REPORT_FILE"
    
    # Prüfe Gist-Dateinamen auf sensitive Muster
    GIST_FILES=$(echo "$GISTS" | jq -r '.[].files | keys[]')
    while IFS= read -r gfile; do
        case "$gfile" in
            *.env*|*credential*|*secret*|*password*|*token*|*.pem|*.key)
                echo -e "  ${RED}[!] Sensitiver Gist-Dateiname: ${gfile}${NC}"
                echo "- 🔴 Sensitiver Dateiname: \`${gfile}\`" >> "$REPORT_FILE"
                ;;
        esac
    done <<< "$GIST_FILES"
else
    echo "Keine öffentlichen Gists." >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ============================================================================
# 7. DEEP SCAN (nur mit --clone)
# ============================================================================
if $CLONE_REPOS; then
    echo -e "\n${BOLD}[7/7] Deep Scan – Git-History${NC}"
    
    CLONE_DIR="${WORKDIR}/repos"
    mkdir -p "$CLONE_DIR"
    
    cat >> "$REPORT_FILE" << EOF
## 7. Deep Scan – Git-History

EOF
    
    # Prüfe ob gitleaks verfügbar ist
    HAS_GITLEAKS=false
    if command -v gitleaks &>/dev/null; then
        HAS_GITLEAKS=true
        echo -e "  ${GREEN}gitleaks erkannt – wird für Deep-Scan verwendet${NC}"
    fi
    
    for repo_name in $(echo "$REPOS_JSON" | jq -r '.[].name'); do
        echo -e "  Scanne: ${CYAN}${repo_name}${NC}"
        REPO_DIR="${CLONE_DIR}/${repo_name}"
        
        if [[ ! -d "$REPO_DIR" ]]; then
            git clone --quiet "https://github.com/${USERNAME}/${repo_name}.git" "$REPO_DIR" 2>/dev/null || continue
        fi
        
        cd "$REPO_DIR"
        
        # E-Mails aus gesamter Git-History
        HIST_EMAILS=$(git log --all --format='%ae' 2>/dev/null | sort -u)
        HIST_NAMES=$(git log --all --format='%an' 2>/dev/null | sort -u)
        
        NEW_EMAILS=""
        while IFS= read -r e; do
            [[ -z "$e" ]] && continue
            [[ "$e" == *"noreply.github.com"* ]] && continue
            NEW_EMAILS+="$e\n"
        done <<< "$HIST_EMAILS"
        
        if [[ -n "$NEW_EMAILS" ]]; then
            echo -e "    ${YELLOW}E-Mails: $(echo -e "$NEW_EMAILS" | tr '\n' ', ')${NC}"
            echo "### ${repo_name}" >> "$REPORT_FILE"
            echo "**Commit-E-Mails:**" >> "$REPORT_FILE"
            echo -e "$NEW_EMAILS" | while read -r em; do
                [[ -n "$em" ]] && echo "- \`$em\`" >> "$REPORT_FILE"
            done
        fi
        
        # Suche nach gelöschten .env Dateien in History
        DELETED_SECRETS=$(git log --all --diff-filter=D --name-only --pretty=format: -- '*.env' '*.env.*' '*.pem' '*.key' '*credentials*' 2>/dev/null | sort -u | grep -v '^$' || true)
        if [[ -n "$DELETED_SECRETS" ]]; then
            echo -e "    ${RED}[!] Gelöschte sensitive Dateien in History:${NC}"
            echo "**Gelöschte sensitive Dateien (noch in Git-History!):**" >> "$REPORT_FILE"
            while IFS= read -r df; do
                echo -e "      - $df"
                echo "- 🔴 \`$df\`" >> "$REPORT_FILE"
            done <<< "$DELETED_SECRETS"
        fi
        
        # Gitleaks Deep-Scan
        if $HAS_GITLEAKS; then
            GITLEAKS_REPORT="${WORKDIR}/gitleaks-${repo_name}.json"
            gitleaks detect --source="$REPO_DIR" --report-path="$GITLEAKS_REPORT" --report-format=json 2>/dev/null || true
            
            if [[ -f "$GITLEAKS_REPORT" ]] && [[ $(jq length "$GITLEAKS_REPORT") -gt 0 ]]; then
                LEAK_COUNT=$(jq length "$GITLEAKS_REPORT")
                echo -e "    ${RED}[!] gitleaks: ${LEAK_COUNT} potenzielle Secrets gefunden${NC}"
                echo "**gitleaks: ${LEAK_COUNT} Findings** (Details in \`gitleaks-${repo_name}.json\`)" >> "$REPORT_FILE"
            fi
        fi
        
        # Manuelle Pattern-Suche in History (Fallback ohne gitleaks)
        if ! $HAS_GITLEAKS; then
            HISTORY_SECRETS=$(git log --all -p 2>/dev/null | grep -iE '(AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36}|sk-ant-|sk-proj-|xoxb-|-----BEGIN (RSA |EC )?PRIVATE KEY)' | head -20 || true)
            if [[ -n "$HISTORY_SECRETS" ]]; then
                MATCH_COUNT=$(echo "$HISTORY_SECRETS" | wc -l)
                echo -e "    ${RED}[!] ${MATCH_COUNT} potenzielle Secrets in Git-History${NC}"
                echo "**Pattern-Scan: ${MATCH_COUNT} potenzielle Secrets in History**" >> "$REPORT_FILE"
            fi
        fi
        
        cd "$WORKDIR"
    done
else
    echo -e "\n${BOLD}[7/7] Deep Scan – übersprungen (nutze --clone für Git-History-Analyse)${NC}"
    echo "## 7. Deep Scan" >> "$REPORT_FILE"
    echo "Übersprungen – \`--clone\` Flag nicht gesetzt." >> "$REPORT_FILE"
fi

# ============================================================================
# ZUSAMMENFASSUNG
# ============================================================================
echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Scan abgeschlossen!${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e " Report: ${GREEN}${REPORT_FILE}${NC}"
echo -e " Workdir: ${WORKDIR}"
echo ""

cat >> "$REPORT_FILE" << EOF

---

## Empfohlene nächste Schritte

1. **Sofort:** Alle exponierten E-Mails in Git auf noreply umstellen: \`git config user.email "user@users.noreply.github.com"\`
2. **Sofort:** Gefundene Secrets rotieren (neue Keys generieren, alte revoken)
3. **Kurzfristig:** \`.gitignore\` in allen Repos auf sensitive Dateien prüfen
4. **Kurzfristig:** GitHub-Profil bereinigen (Klarname, Company, Location entfernen falls ungewünscht)
5. **Mittelfristig:** \`git filter-branch\` oder \`git-filter-repo\` um Secrets aus History zu entfernen
6. **Laufend:** GitHub Secret Scanning und Push Protection aktivieren

---
*Generiert von github-recon.sh am $(date '+%Y-%m-%d %H:%M:%S')*
EOF

echo -e " ${BOLD}Tipp:${NC} Für maximale Tiefe:"
echo -e "   1. \`gitleaks\` installieren"
echo -e "   2. Script mit \`--clone\` ausführen"
echo -e "   3. \`GITHUB_TOKEN=ghp_xxx ./github-recon.sh $USERNAME --clone\`"
