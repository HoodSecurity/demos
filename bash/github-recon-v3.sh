#!/usr/bin/env bash
# ============================================================================
# github-recon-v3.sh – GitHub OSINT & Secrets Scanner (mit Token-Setup)
#
# Neu in v3 gegenüber v2:
#   * Interaktiver Token-Setup (--setup-token), Token-Persistenz mit chmod 600
#   * Anleitung & Direktlink zur Token-Erstellung, gh-CLI Auto-Detect
#   * Workflow-Files-Scan (.github/workflows/*.yml – häufigste Secret-Quelle)
#   * Wayback-Machine-Lookup (gelöschte/umbenannte Repos)
#   * Diff-Modus (--diff-from=<findings.json>)
#   * Aktivitäts-Heatmap → Zeitzone-Inferenz
#   * noseyparker als bevorzugter Deep-Scanner (10× schneller als trufflehog)
#
# Nutzung:
#   ./github-recon-v3.sh --setup-token            # Interaktiver Token-Setup
#   ./github-recon-v3.sh <user> [--mode=quick|standard|deep]
#   ./github-recon-v3.sh <user> --diff-from=/path/to/old-findings.json
#
# Exit-Codes: 0=clean | 10=LOW | 20=MEDIUM | 30=HIGH | 40=CRITICAL | 2=usage
# ============================================================================

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Fehler: bash >= 4 nötig (aktuell: $BASH_VERSION). macOS: brew install bash" >&2
    exit 2
fi

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

GITHUB_TOKEN_FILE="${GITHUB_TOKEN_FILE:-$HOME/.config/github-recon/token}"

# ============================================================================
# TOKEN MANAGEMENT
# ============================================================================
print_token_help() {
    printf '%b' "$(cat <<EOF
${BOLD}${CYAN}━━━ GitHub Personal Access Token (PAT) ━━━${NC}

Warum ein Token?
  • Ohne Token: 60 Core-Calls/h, 10 Search-Calls/min (Scan crasht oft)
  • Mit Token : 5000 Core-Calls/h, 30 Search-Calls/min

${BOLD}So bekommst du einen Token:${NC}

  ${GREEN}Option A – Fine-grained (empfohlen, weniger Rechte):${NC}
    1) Öffne: ${CYAN}https://github.com/settings/personal-access-tokens/new${NC}
    2) Name:        "github-recon"
    3) Expiration:  z.B. 30 Tage
    4) Repository access: "Public Repositories (read-only)"
    5) Permissions: ${BOLD}keine zusätzlichen nötig${NC} für nur-öffentliche Scans
    6) "Generate token" → kopieren (beginnt mit ${BOLD}github_pat_${NC})

  ${GREEN}Option B – Classic Token:${NC}
    1) Öffne: ${CYAN}https://github.com/settings/tokens/new?description=github-recon${NC}
    2) Scopes:       ${BOLD}keine markieren${NC} (Public-Read reicht)
    3) "Generate token" → kopieren (beginnt mit ${BOLD}ghp_${NC})

  ${GREEN}Option C – via gh CLI (am einfachsten):${NC}
    ${CYAN}brew install gh && gh auth login${NC}
    Token holst du dann mit: ${CYAN}gh auth token${NC}

EOF
)"
}

setup_token() {
    print_token_help

    # gh CLI auto-detect
    if command -v gh &>/dev/null && gh auth status &>/dev/null; then
        local gh_token
        gh_token=$(gh auth token 2>/dev/null || true)
        if [[ -n "$gh_token" ]]; then
            echo -e "${GREEN}gh CLI ist authentifiziert.${NC}"
            read -r -p "Token aus gh CLI übernehmen? [Y/n] " yn
            if [[ -z "$yn" || "$yn" =~ ^[Yy]$ ]]; then
                store_token "$gh_token" && return 0
            fi
        fi
    fi

    echo ""
    echo -e "${BOLD}Token unten einfügen (Eingabe wird ${YELLOW}nicht${NC}${BOLD} angezeigt, Enter zum Abbrechen):${NC}"
    local token
    read -r -s -p "Token: " token
    echo ""

    if [[ -z "$token" ]]; then
        echo -e "${YELLOW}Kein Token eingegeben – Abbruch.${NC}"
        return 1
    fi

    store_token "$token"
}

store_token() {
    local token="$1"
    echo -e "${CYAN}Validiere Token...${NC}"
    local resp
    resp=$(curl -sL -o /dev/null -w '%{http_code}' \
        -H "Authorization: token $token" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/user")
    if [[ "$resp" != "200" ]]; then
        echo -e "${RED}Token-Validierung fehlgeschlagen (HTTP $resp)${NC}"
        return 1
    fi

    local who
    who=$(curl -sL -H "Authorization: token $token" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/user" | jq -r '.login')
    echo -e "${GREEN}✓ Token gültig für: ${BOLD}$who${NC}"

    mkdir -p "$(dirname "$GITHUB_TOKEN_FILE")"
    printf '%s\n' "$token" > "$GITHUB_TOKEN_FILE"
    chmod 600 "$GITHUB_TOKEN_FILE"
    echo -e "${GREEN}✓ Gespeichert in ${BOLD}$GITHUB_TOKEN_FILE${NC} (chmod 600)"

    # Rate-Limit anzeigen
    local rl
    rl=$(curl -sL -H "Authorization: token $token" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/rate_limit")
    echo -e "  ${CYAN}Rate-Limit: core=$(echo "$rl" | jq -r '.resources.core.remaining')/5000, search=$(echo "$rl" | jq -r '.resources.search.remaining')/30${NC}"
}

load_token() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        return 0
    fi
    if [[ -r "$GITHUB_TOKEN_FILE" ]]; then
        GITHUB_TOKEN=$(<"$GITHUB_TOKEN_FILE")
        export GITHUB_TOKEN
        return 0
    fi
    return 1
}

# ============================================================================
# ARG PARSING
# ============================================================================
MODE="standard"
USERNAME=""
DIFF_FROM=""

for arg in "$@"; do
    case "$arg" in
        --setup-token)
            setup_token
            exit $?
            ;;
        --mode=*)        MODE="${arg#*=}" ;;
        --clone)         MODE="deep" ;;
        --diff-from=*)   DIFF_FROM="${arg#*=}" ;;
        --token-help)    print_token_help; exit 0 ;;
        --help|-h)
            sed -n '2,25p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        -*) echo "Unbekannter Schalter: $arg" >&2; exit 2 ;;
        *)  USERNAME="$arg" ;;
    esac
done

[[ -z "$USERNAME" ]] && {
    echo "Nutzung: $0 <github-username> [--mode=quick|standard|deep] [--diff-from=<json>]"
    echo "         $0 --setup-token         (interaktiver Token-Setup)"
    echo "         $0 --token-help          (zeigt Token-Erstellungs-Anleitung)"
    exit 2
}
[[ "$MODE" =~ ^(quick|standard|deep)$ ]] || { echo "Ungültiger Modus: $MODE" >&2; exit 2; }

# Token laden (oder Hinweis ausgeben)
if ! load_token; then
    echo -e "${YELLOW}[!] Kein GITHUB_TOKEN gefunden.${NC}"
    echo -e "    Scan läuft mit Public-Limit (60/h core, 10/min search) – wahrscheinlich unvollständig."
    echo -e "    Token erstellen: ${CYAN}$0 --setup-token${NC}"
    echo ""
    read -r -p "Trotzdem ohne Token fortfahren? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 2
fi

WORKDIR="/tmp/github-recon-${USERNAME}"
REPORT_MD="${WORKDIR}/recon-report.md"
REPORT_JSON="${WORKDIR}/findings.json"
mkdir -p "$WORKDIR"

# ============================================================================
# FINDINGS
# ============================================================================
declare -A SEVERITY_COUNTS=( [CRITICAL]=0 [HIGH]=0 [MEDIUM]=0 [LOW]=0 [INFO]=0 )
FINDINGS_JSON="[]"

add_finding() {
    local severity="$1" category="$2" title="$3" detail="$4"
    SEVERITY_COUNTS[$severity]=$(( SEVERITY_COUNTS[$severity] + 1 ))
    FINDINGS_JSON=$(jq -c \
        --arg sev "$severity" --arg cat "$category" --arg t "$title" --arg d "$detail" \
        '. += [{severity:$sev, category:$cat, title:$t, detail:$d}]' \
        <<<"$FINDINGS_JSON")
}

# ============================================================================
# HTTP LAYER
# ============================================================================
AUTH_HEADER=()
[[ -n "${GITHUB_TOKEN:-}" ]] && AUTH_HEADER=(-H "Authorization: token $GITHUB_TOKEN")

api_get() {
    local url="$1" expect="${2:-}"
    local attempt=0 max_attempts=3
    while (( attempt < max_attempts )); do
        local body http_code
        body=$(curl -sL -w '\n%{http_code}' "${AUTH_HEADER[@]}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$url" 2>/dev/null) || { sleep 2; attempt=$((attempt+1)); continue; }
        http_code="${body##*$'\n'}"; body="${body%$'\n'*}"

        if [[ "$http_code" == "200" ]]; then
            if [[ -n "$expect" ]]; then
                if echo "$body" | jq -e "type == \"$expect\"" >/dev/null 2>&1; then
                    echo "$body"; return 0
                else
                    [[ "$expect" == "array" ]] && echo "[]" || echo "{}"
                    return 1
                fi
            fi
            echo "$body"; return 0
        elif [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
            wait_for_rate_reset
            attempt=$((attempt+1))
        elif [[ "$http_code" == "404" ]]; then
            [[ "$expect" == "array" ]] && echo "[]" || echo "{}"
            return 1
        else
            [[ "$expect" == "array" ]] && echo "[]" || echo "{}"
            return 1
        fi
    done
    [[ "$expect" == "array" ]] && echo "[]" || echo "{}"
    return 1
}

wait_for_rate_reset() {
    local rl reset now wait_s
    rl=$(curl -sL "${AUTH_HEADER[@]}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/rate_limit" 2>/dev/null) || return
    reset=$(echo "$rl" | jq -r '.resources.core.reset // 0')
    now=$(date +%s); wait_s=$(( reset - now + 5 ))
    if (( wait_s > 0 && wait_s < 3700 )); then
        echo -e "${YELLOW}[~] Rate-Limit – warte ${wait_s}s${NC}" >&2
        sleep "$wait_s"
    fi
}

api_get_paginated() {
    local base="$1" page=1 sep="?"
    [[ "$base" == *"?"* ]] && sep="&"
    local all="[]"
    while true; do
        local page_data
        page_data=$(api_get "${base}${sep}per_page=100&page=${page}" "array")
        local count
        count=$(echo "$page_data" | jq 'length')
        (( count == 0 )) && break
        all=$(jq -c -n --argjson a "$all" --argjson b "$page_data" '$a + $b')
        (( count < 100 )) && break
        page=$((page+1))
        (( page > 10 )) && break
    done
    echo "$all"
}

check_rate_limit() {
    local rl
    rl=$(curl -sL "${AUTH_HEADER[@]}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/rate_limit" 2>/dev/null) || return
    echo -e "  ${CYAN}Rate-Limit: core=$(echo "$rl" | jq -r '.resources.core.remaining'), search=$(echo "$rl" | jq -r '.resources.search.remaining')${NC}"
}

# ============================================================================
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  GitHub OSINT Recon v3 – $USERNAME (mode: $MODE)"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
[[ -n "${GITHUB_TOKEN:-}" ]] && echo -e "${GREEN}[+] Token aktiv${NC}"
check_rate_limit

cat > "$REPORT_MD" <<EOF
# GitHub Recon Report: $USERNAME
**Datum:** $(date '+%Y-%m-%d %H:%M:%S')
**Modus:** $MODE
**Token:** $(if [[ -n "${GITHUB_TOKEN:-}" ]]; then echo "✓ aktiv"; else echo "✗ ohne Token"; fi)

---

EOF

# ============================================================================
# 1. PROFIL
# ============================================================================
echo -e "\n${BOLD}[1] Profil${NC}"
PROFILE=$(api_get "https://api.github.com/users/${USERNAME}" "object")
if [[ "$(echo "$PROFILE" | jq -r '.login // empty')" == "" ]]; then
    echo -e "${RED}User nicht gefunden${NC}"; exit 3
fi

declare -A P
for key in name bio company location blog email twitter_username created_at public_repos followers; do
    P[$key]=$(echo "$PROFILE" | jq -r ".${key} // \"-\"")
done
echo -e "  Name: ${P[name]} | Company: ${P[company]} | Location: ${P[location]}"

[[ "${P[name]}"     != "-" ]] && add_finding LOW Profil "Klarname exponiert" "${P[name]}"
[[ "${P[company]}"  != "-" ]] && add_finding LOW Profil "Arbeitgeber sichtbar" "${P[company]}"
[[ "${P[location]}" != "-" ]] && add_finding LOW Profil "Standort sichtbar" "${P[location]}"
[[ "${P[email]}"    != "-" ]] && add_finding HIGH Profil "E-Mail öffentlich" "${P[email]}"

{
    echo "## 1. Profil"; echo ""
    echo "| Feld | Wert |"; echo "|------|------|"
    for k in name bio company location blog email twitter_username created_at public_repos followers; do
        echo "| $k | ${P[$k]} |"
    done
    echo ""
} >> "$REPORT_MD"

# ============================================================================
# 2. SSH/GPG
# ============================================================================
echo -e "\n${BOLD}[2] Public Keys${NC}"
SSH_KEYS=$(curl -sL "https://github.com/${USERNAME}.keys" 2>/dev/null || echo "")
GPG_KEYS=$(curl -sL "https://github.com/${USERNAME}.gpg" 2>/dev/null || echo "")
SSH_COUNT=$(echo "$SSH_KEYS" | grep -c '^ssh-' || true)
GPG_PRESENT=$(echo "$GPG_KEYS" | grep -c 'BEGIN PGP' || true)
echo -e "  SSH: $SSH_COUNT | GPG: $GPG_PRESENT"
{
    echo "## 2. Public Keys"; echo ""
    echo "- SSH-Keys: $SSH_COUNT"
    echo "- GPG-Keys: $GPG_PRESENT"
    echo ""
} >> "$REPORT_MD"
(( SSH_COUNT > 0 )) && add_finding INFO Keys "SSH-Keys public" "${SSH_COUNT} key(s)"
(( GPG_PRESENT > 0 )) && add_finding INFO Keys "GPG-Keys public" "PGP UID prüfen"

# ============================================================================
# 3. ORGS
# ============================================================================
echo -e "\n${BOLD}[3] Organisationen${NC}"
ORGS=$(api_get "https://api.github.com/users/${USERNAME}/orgs" "array")
ORG_COUNT=$(echo "$ORGS" | jq 'length')
echo -e "  Orgs: $ORG_COUNT"
{
    echo "## 3. Organisationen ($ORG_COUNT)"; echo ""
    if (( ORG_COUNT > 0 )); then
        echo "$ORGS" | jq -r '.[] | "- [\(.login)](https://github.com/\(.login))"'
        while IFS= read -r o; do add_finding INFO Orgs "Mitglied in Org" "$o"; done < <(echo "$ORGS" | jq -r '.[].login')
    else
        echo "Keine."
    fi
    echo ""
} >> "$REPORT_MD"

# ============================================================================
# 4. REPOS
# ============================================================================
echo -e "\n${BOLD}[4] Repositories${NC}"
REPOS_JSON=$(api_get_paginated "https://api.github.com/users/${USERNAME}/repos?sort=updated")
REPO_COUNT=$(echo "$REPOS_JSON" | jq 'length')
FORK_COUNT=$(echo "$REPOS_JSON" | jq '[.[] | select(.fork)] | length')
REPO_NAMES=$(echo "$REPOS_JSON" | jq -r '.[] | select(.fork|not) | .name')
TOP_LANGS=$(echo "$REPOS_JSON" | jq -r '[.[] | select(.fork|not) | .language] | map(select(.!=null)) | group_by(.) | map({l:.[0],c:length}) | sort_by(-.c) | .[0:5] | .[] | "\(.l)(\(.c))"' | tr '\n' ' ')
echo -e "  $REPO_COUNT Repos ($FORK_COUNT Forks) | Top: $TOP_LANGS"
{
    echo "## 4. Repos ($REPO_COUNT total, $FORK_COUNT Forks)"; echo ""
    echo "**Top-Sprachen:** $TOP_LANGS"
    echo ""
} >> "$REPORT_MD"

# ============================================================================
# 5. AKTIVITÄT + ZEITZONE  (neu!)
# ============================================================================
echo -e "\n${BOLD}[5] Aktivitäts-Heatmap & Zeitzone${NC}"
EVENTS=$(api_get_paginated "https://api.github.com/users/${USERNAME}/events/public")
EVENT_COUNT=$(echo "$EVENTS" | jq 'length')

# Stunden-Histogramm aus Push-Events (UTC)
HOURS_HIST=$(echo "$EVENTS" | jq -r '
    [.[] | select(.type=="PushEvent") | .created_at] | .[]' 2>/dev/null \
    | sed -E 's/.*T([0-9]{2}):.*/\1/' \
    | sort | uniq -c | sort -k2)

# Median-Stunde (gewichtet) → Zeitzonen-Schätzung
if [[ -n "$HOURS_HIST" ]]; then
    # Aktive Stunden: top 8 buckets (~ Arbeitszeit + Abend)
    ACTIVE_HOURS=$(echo "$HOURS_HIST" | sort -rn | head -8 | awk '{print $2}' | sort -n)
    # Geometrisches Zentrum
    MID_HOUR=$(echo "$ACTIVE_HOURS" | awk '
        BEGIN{sx=0;sy=0;n=0}
        {h=$1; rad=h*3.14159/12; sx+=cos(rad); sy+=sin(rad); n++}
        END{if(n>0){a=atan2(sy/n, sx/n)*12/3.14159; if(a<0)a+=24; printf "%d\n", a}}')
    # Zwei Heuristiken parallel (Berufs- vs. Hobby-Coder)
    [[ -n "$MID_HOUR" ]] && {
        # Berufs-Hypothese: Aktivitäts-Mitte = 14:00 lokal
        OFF_PRO=$(( 14 - MID_HOUR ))
        (( OFF_PRO > 12 )) && OFF_PRO=$(( OFF_PRO - 24 ))
        (( OFF_PRO < -12 )) && OFF_PRO=$(( OFF_PRO + 24 ))
        # Hobby-Hypothese: Aktivitäts-Mitte = 21:00 lokal (abends/nachts)
        OFF_HOBBY=$(( 21 - MID_HOUR ))
        (( OFF_HOBBY > 12 )) && OFF_HOBBY=$(( OFF_HOBBY - 24 ))
        (( OFF_HOBBY < -12 )) && OFF_HOBBY=$(( OFF_HOBBY + 24 ))
        SP="+"; (( OFF_PRO < 0 )) && SP=""
        SH="+"; (( OFF_HOBBY < 0 )) && SH=""
        echo -e "  Aktive UTC-Stunden Mitte: ${MID_HOUR}h"
        echo -e "    Wenn Berufs-Coder (Peak 14h lokal): UTC${SP}${OFF_PRO}"
        echo -e "    Wenn Hobby/Abend-Coder (Peak 21h lokal): UTC${SH}${OFF_HOBBY}"
        add_finding INFO Activity "Aktivitäts-Mittel ${MID_HOUR}h UTC" "Berufs-TZ-Schätzung: UTC${SP}${OFF_PRO} · Hobby-TZ-Schätzung: UTC${SH}${OFF_HOBBY}"
    }
fi

{
    echo "## 5. Aktivität & Zeitzone"; echo ""
    echo "- Analysierte Events: $EVENT_COUNT"
    if [[ -n "$HOURS_HIST" ]]; then
        echo ""
        echo "**Push-Events nach UTC-Stunde:**"
        echo '```'
        echo "$HOURS_HIST" | awk '{
            bar=""; for(i=0;i<$1;i++) bar=bar "█";
            printf "%sh %-30s (%d)\n", $2, bar, $1
        }'
        echo '```'
        [[ -n "${MID_HOUR:-}" ]] && {
            echo ""
            echo "**Aktivitäts-Mitte UTC:** ${MID_HOUR}h"
            echo "- Falls Berufs-Coder (Peak 14h lokal): **UTC${SP}${OFF_PRO}**"
            echo "- Falls Hobby-/Abend-Coder (Peak 21h lokal): **UTC${SH}${OFF_HOBBY}**"
        }
    fi
    echo ""
} >> "$REPORT_MD"

# Commit-E-Mails
COMMIT_EMAILS=$(echo "$EVENTS" | jq -r '[.[] | select(.type=="PushEvent") | .payload.commits[]?.author.email] | unique | .[]' 2>/dev/null || true)
{
    echo "## 6. Commit-E-Mails"; echo ""
    if [[ -n "$COMMIT_EMAILS" ]]; then
        while IFS= read -r e; do
            [[ -z "$e" ]] && continue
            if [[ "$e" == *"noreply.github.com"* ]]; then
                echo "- ✅ \`$e\` (noreply)"
            else
                echo "- 🔴 \`$e\`"
                add_finding HIGH Email "E-Mail in Commits" "$e"
            fi
        done <<<"$COMMIT_EMAILS"
    else
        echo "Keine."
    fi
    echo ""
} >> "$REPORT_MD"

# ============================================================================
# 7. WAYBACK MACHINE – gelöschte/umbenannte Repos  (neu!)
# ============================================================================
echo -e "\n${BOLD}[7] Wayback-Machine (historische Repos)${NC}"
WB=$(curl -sL "https://web.archive.org/cdx/search/cdx?url=github.com/${USERNAME}/*&output=json&fl=original&collapse=urlkey&limit=500" 2>/dev/null || echo "[]")

# Aktuelle Repo-Namen Lowercase für Vergleich
CURRENT_LC=$(echo "$REPO_NAMES" | tr '[:upper:]' '[:lower:]' | sort -u)

# Aus Wayback-URLs Repo-Namen extrahieren
HIST_REPOS=$(echo "$WB" | jq -r '.[1:][]? | .[0]' 2>/dev/null \
    | sed -nE "s|.*github\\.com/${USERNAME}/([A-Za-z0-9_.-]+).*|\\1|p" \
    | grep -viE '^(followers|following|repositories|stars|tab|projects)$' \
    | tr '[:upper:]' '[:lower:]' \
    | sort -u || true)

GONE_REPOS=$(comm -23 <(echo "$HIST_REPOS") <(echo "$CURRENT_LC") | head -50 || true)
if [[ -z "$GONE_REPOS" ]]; then GONE_COUNT=0; else GONE_COUNT=$(echo "$GONE_REPOS" | wc -l | tr -d ' '); fi
if [[ -z "$HIST_REPOS" ]]; then HIST_COUNT=0; else HIST_COUNT=$(echo "$HIST_REPOS" | wc -l | tr -d ' '); fi
echo -e "  Wayback gefunden: $HIST_COUNT | nicht mehr existent: $GONE_COUNT"

{
    echo "## 7. Wayback Machine"; echo ""
    if (( GONE_COUNT > 0 )); then
        echo "**Gelöscht/umbenannt seit letztem Wayback-Snapshot:**"
        echo ""
        while IFS= read -r r; do
            [[ -n "$r" ]] && echo "- 🟡 \`$r\` – [Archive prüfen](https://web.archive.org/web/*/github.com/${USERNAME}/${r})"
        done <<<"$GONE_REPOS"
        add_finding MEDIUM Wayback "Gelöschte/umbenannte Repos in Archive" "${GONE_COUNT} Stück – manuell prüfen"
    else
        echo "✅ Keine gelöschten Repos im Archive."
    fi
    echo ""
} >> "$REPORT_MD"

# ============================================================================
# 8. SENSITIVE FILES
# ============================================================================
if [[ "$MODE" != "quick" ]]; then
echo -e "\n${BOLD}[8] Sensitive Dateien${NC}"
SENSITIVE_PATTERNS=(".env" ".env.local" ".env.production" "id_rsa" "id_ed25519"
    ".npmrc" ".pypirc" "kubeconfig" "terraform.tfvars" "wp-config.php"
    "credentials" ".htpasswd" "service-account.json" ".aws/credentials" ".pgpass")
{ echo "## 8. Sensitive Dateien"; echo ""; } >> "$REPORT_MD"
found_any=false
for pattern in "${SENSITIVE_PATTERNS[@]}"; do
    enc=$(printf '%s' "$pattern" | jq -sRr @uri)
    R=$(api_get "https://api.github.com/search/code?q=user:${USERNAME}+filename:${enc}" "object")
    COUNT=$(echo "$R" | jq -r '.total_count // 0')
    if (( COUNT > 0 )); then
        REPOS_HIT=$(echo "$R" | jq -r '[.items[].repository.name] | unique | join(", ")')
        echo -e "  ${RED}[!] ${pattern}: ${COUNT}x [${REPOS_HIT}]${NC}"
        echo "- 🔴 \`${pattern}\`: ${COUNT}x in ${REPOS_HIT}" >> "$REPORT_MD"
        add_finding HIGH SensitiveFile "${pattern}" "${REPOS_HIT}"
        found_any=true
    fi
    sleep 2
done
$found_any || { echo -e "  ${GREEN}Nichts${NC}"; echo "✅ Keine." >> "$REPORT_MD"; }
echo "" >> "$REPORT_MD"
fi

# ============================================================================
# 9. WORKFLOW-FILES (neu! – CI-YAMLs mit hardcoded Secrets)
# ============================================================================
if [[ "$MODE" != "quick" ]]; then
echo -e "\n${BOLD}[9] CI/CD Workflow-Scan (.github/workflows)${NC}"
# Gefährliche Patterns in Workflow-Files
WF_PATTERNS=("AWS_SECRET_ACCESS_KEY:" "DOCKER_PASSWORD:" "NPM_TOKEN:" "SSH_PRIVATE_KEY:"
    "DEPLOY_KEY:" "password:" "token:" "ghp_" "github_pat_" "BEGIN RSA")
{ echo "## 9. CI/CD Workflow Secrets"; echo ""; } >> "$REPORT_MD"
found_wf=false
for pat in "${WF_PATTERNS[@]}"; do
    enc=$(printf '"%s"' "$pat" | jq -sRr @uri)
    R=$(api_get "https://api.github.com/search/code?q=${enc}+user:${USERNAME}+path:.github/workflows" "object")
    COUNT=$(echo "$R" | jq -r '.total_count // 0')
    if (( COUNT > 0 )); then
        # Filter false-positives: "${{ secrets.X }}" Verwendung ist OK
        REAL_HITS=$(echo "$R" | jq -r '.items[] | "\(.repository.name)|\(.path)"')
        echo -e "  ${YELLOW}[?] ${pat}: ${COUNT}x – manuell prüfen ob Klartext oder \${{ secrets.* }}${NC}"
        echo "- 🟡 \`${pat}\` ${COUNT}x:" >> "$REPORT_MD"
        echo "$REAL_HITS" | while IFS='|' read -r r p; do
            echo "  - [\`$r/$p\`](https://github.com/${USERNAME}/$r/blob/HEAD/$p)" >> "$REPORT_MD"
        done
        add_finding HIGH WorkflowSecret "${pat} in workflow yml" "${COUNT} matches – auf Klartext vs. secrets-ref prüfen"
        found_wf=true
    fi
    sleep 2
done
$found_wf || { echo -e "  ${GREEN}Sauber${NC}"; echo "✅ Keine verdächtigen Tokens in Workflows." >> "$REPORT_MD"; }
echo "" >> "$REPORT_MD"
fi

# ============================================================================
# 10. SECRET PATTERNS
# ============================================================================
if [[ "$MODE" != "quick" ]]; then
echo -e "\n${BOLD}[10] Secret-Pattern-Scan${NC}"
SECRET_LABELS=("AWS Access Key" "GitHub Token" "Slack Bot Token" "Anthropic Key"
    "OpenAI Key" "Stripe Live" "Private Key Block" "MongoDB URI" "Postgres URI")
SECRET_PATTERNS=("AKIA" "ghp_" "xoxb-" "sk-ant-" "sk-proj-" "sk_live_"
    "BEGIN RSA PRIVATE KEY" "mongodb+srv://" "postgresql://")
{ echo "## 10. Secrets im Code"; echo ""; } >> "$REPORT_MD"
found_secret=false
for i in "${!SECRET_PATTERNS[@]}"; do
    pat="${SECRET_PATTERNS[$i]}"; lbl="${SECRET_LABELS[$i]}"
    enc=$(printf '%s' "$pat" | jq -sRr @uri)
    R=$(api_get "https://api.github.com/search/code?q=${enc}+user:${USERNAME}" "object")
    COUNT=$(echo "$R" | jq -r '.total_count // 0')
    if (( COUNT > 0 )); then
        REPOS_HIT=$(echo "$R" | jq -r '[.items[].repository.name] | unique | join(", ")')
        echo -e "  ${RED}[!] ${lbl}: ${COUNT}x [${REPOS_HIT}]${NC}"
        echo "- 🔴 **${lbl}**: ${COUNT}x in ${REPOS_HIT}" >> "$REPORT_MD"
        add_finding CRITICAL Secret "${lbl}" "${REPOS_HIT}"
        found_secret=true
    fi
    sleep 2
done
$found_secret || { echo -e "  ${GREEN}Sauber${NC}"; echo "✅ Keine." >> "$REPORT_MD"; }
echo "" >> "$REPORT_MD"
fi

# ============================================================================
# 11. DEEP SCAN: noseyparker > gitleaks > trufflehog
# ============================================================================
if [[ "$MODE" == "deep" ]]; then
echo -e "\n${BOLD}[11] Deep Scan (Clone + Secret-Scanner)${NC}"
CLONE_DIR="${WORKDIR}/repos"; mkdir -p "$CLONE_DIR"

HAS_NP=false; HAS_GL=false; HAS_TH=false
command -v noseyparker &>/dev/null && HAS_NP=true && echo -e "  ${GREEN}noseyparker erkannt (bevorzugt)${NC}"
command -v gitleaks    &>/dev/null && HAS_GL=true && echo -e "  ${GREEN}gitleaks erkannt${NC}"
command -v trufflehog  &>/dev/null && HAS_TH=true && echo -e "  ${GREEN}trufflehog erkannt${NC}"
$HAS_NP || $HAS_GL || $HAS_TH || echo -e "  ${YELLOW}Kein Secret-Scanner installiert. Empfehlung: brew install noseyparker${NC}"

{ echo "## 11. Deep Scan"; echo ""; } >> "$REPORT_MD"

NP_STORE="${WORKDIR}/np-datastore"

while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    echo -e "  ${CYAN}→ ${repo}${NC}"
    RD="${CLONE_DIR}/${repo}"
    [[ -d "$RD" ]] || git clone --quiet "https://github.com/${USERNAME}/${repo}.git" "$RD" 2>/dev/null || continue

    # E-Mails in History
    HE=$(cd "$RD" && git log --all --format='%ae' 2>/dev/null | sort -u | grep -v noreply.github.com || true)
    while IFS= read -r e; do
        [[ -n "$e" ]] && add_finding HIGH Email "E-Mail in History" "${repo}: $e"
    done <<<"$HE"

    # Gelöschte sensitive Dateien
    DS=$(cd "$RD" && git log --all --diff-filter=D --name-only --pretty=format: -- '*.env' '*.pem' '*.key' '*credentials*' 2>/dev/null | sort -u | grep -v '^$' || true)
    while IFS= read -r d; do
        [[ -n "$d" ]] && add_finding CRITICAL SensitiveFile "Gelöscht (noch in History)" "${repo}: $d"
    done <<<"$DS"

    # noseyparker (bevorzugt)
    if $HAS_NP; then
        noseyparker scan --datastore "$NP_STORE" "$RD" --quiet 2>/dev/null || true
    elif $HAS_GL; then
        OUT="${WORKDIR}/gitleaks-${repo}.json"
        gitleaks detect --no-banner --source="$RD" --report-format=json --report-path="$OUT" --redact 2>/dev/null || true
        if [[ -s "$OUT" ]]; then
            LC=$(jq 'length' "$OUT" 2>/dev/null || echo 0)
            (( LC > 0 )) && add_finding CRITICAL Secret "gitleaks: ${LC} findings" "$repo"
        fi
    elif $HAS_TH; then
        TC=$(trufflehog git "file://$RD" --json --no-update 2>/dev/null | grep -c '"SourceMetadata"' || true)
        (( TC > 0 )) && add_finding CRITICAL Secret "trufflehog: ${TC} findings" "$repo"
    fi
done <<<"$REPO_NAMES"

# noseyparker Report einmal am Ende
if $HAS_NP && [[ -d "$NP_STORE" ]]; then
    NP_REPORT="${WORKDIR}/noseyparker-summary.json"
    noseyparker report --datastore "$NP_STORE" --format json > "$NP_REPORT" 2>/dev/null || true
    if [[ -s "$NP_REPORT" ]]; then
        NP_COUNT=$(jq '[.[] | .num_matches] | add // 0' "$NP_REPORT" 2>/dev/null || echo 0)
        (( NP_COUNT > 0 )) && {
            add_finding CRITICAL Secret "noseyparker: ${NP_COUNT} matches insgesamt" "Details: noseyparker-summary.json"
            echo "**noseyparker:** ${NP_COUNT} matches total – siehe \`noseyparker-summary.json\`" >> "$REPORT_MD"
        }
    fi
fi
fi

# ============================================================================
# DIFF MODE
# ============================================================================
if [[ -n "$DIFF_FROM" ]]; then
    if [[ ! -r "$DIFF_FROM" ]]; then
        echo -e "${YELLOW}[!] Diff-Quelle nicht lesbar: $DIFF_FROM${NC}"
    else
        echo -e "\n${BOLD}[Δ] Diff zu $DIFF_FROM${NC}"
        # NEW: in current, not in old
        NEW=$(jq -c -n --argjson cur "$FINDINGS_JSON" --slurpfile old "$DIFF_FROM" '
            $cur | map(select(. as $c | ($old[0] | any(.title==$c.title and .detail==$c.detail)) | not))')
        # RESOLVED: in old, not in current
        RESOLVED=$(jq -c -n --argjson cur "$FINDINGS_JSON" --slurpfile old "$DIFF_FROM" '
            $old[0] | map(select(. as $o | ($cur | any(.title==$o.title and .detail==$o.detail)) | not))')

        NEW_COUNT=$(echo "$NEW" | jq 'length')
        RES_COUNT=$(echo "$RESOLVED" | jq 'length')
        echo -e "  ${RED}+${NEW_COUNT} neu${NC}, ${GREEN}-${RES_COUNT} gelöst${NC}"

        {
            echo "## Δ Diff zum letzten Scan"
            echo ""
            echo "**Quelle:** \`$DIFF_FROM\`"
            echo ""
            echo "### NEU (${NEW_COUNT})"
            echo "$NEW" | jq -r '.[] | "- [\(.severity)] \(.title): \(.detail)"' || echo "_keine_"
            echo ""
            echo "### GELÖST (${RES_COUNT})"
            echo "$RESOLVED" | jq -r '.[] | "- [\(.severity)] \(.title): \(.detail)"' || echo "_keine_"
            echo ""
        } >> "$REPORT_MD"
    fi
fi

# ============================================================================
# FINALIZE
# ============================================================================
echo "$FINDINGS_JSON" | jq '.' > "$REPORT_JSON"

{
    echo "---"; echo ""
    echo "## Severity-Zusammenfassung"; echo ""
    echo "| Stufe | Anzahl |"; echo "|-------|--------|"
    for s in CRITICAL HIGH MEDIUM LOW INFO; do echo "| $s | ${SEVERITY_COUNTS[$s]} |"; done
    echo ""
    echo "*Generiert: $(date '+%Y-%m-%d %H:%M:%S')*"
} >> "$REPORT_MD"

echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Scan abgeschlossen${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "  CRITICAL: ${RED}${SEVERITY_COUNTS[CRITICAL]}${NC} | HIGH: ${RED}${SEVERITY_COUNTS[HIGH]}${NC} | MEDIUM: ${YELLOW}${SEVERITY_COUNTS[MEDIUM]}${NC} | LOW: ${YELLOW}${SEVERITY_COUNTS[LOW]}${NC} | INFO: ${SEVERITY_COUNTS[INFO]}"
echo -e "  Markdown: $REPORT_MD"
echo -e "  JSON:     $REPORT_JSON"

(( SEVERITY_COUNTS[CRITICAL] > 0 )) && exit 40
(( SEVERITY_COUNTS[HIGH]     > 0 )) && exit 30
(( SEVERITY_COUNTS[MEDIUM]   > 0 )) && exit 20
(( SEVERITY_COUNTS[LOW]      > 0 )) && exit 10
exit 0
