#!/bin/bash
# =============================================================================
# git-rewrite-ai.sh — Generate and apply conventional commit messages using LLMs
# =============================================================================
#
# Usage:
#   cd /path/to/your/repo
#   bash git-rewrite-ai.sh [--model qwen3.5:9b] [--apply]
#
# Steps:
#   1. Without --apply: Generates mapping.txt in repo root (Review this first!)
#   2. With --apply:    Applies mapping.txt via git filter-branch
#
# Requirements: 
#   - Ollama running with your chosen model
#   - git, curl, python3
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Defaults ---
MODEL="qwen3.5:9b"
APPLY=false
OLLAMA_URL="http://localhost:11434"
MAPPING_FILE="mapping.txt"

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        --mapping) MAPPING_FILE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: bash git-rewrite-ai.sh [options]"
            echo ""
            echo "Options:"
            echo "  --model MODEL    Ollama model (default: qwen3.5:9b)"
            echo "  --mapping FILE   Mapping file (default: mapping.txt)"
            echo "  --apply          Apply the existing mapping.txt to history"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "Step 1: Generate mapping"
            echo "  bash git-rewrite-ai.sh"
            echo "  -> Generates mapping.txt. Review and edit as needed."
            echo ""
            echo "Step 2: Apply changes"
            echo "  bash git-rewrite-ai.sh --apply"
            echo "  -> Rewrites git history based on mapping.txt"
            exit 0 ;;
        *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
    esac
done

# --- Validation ---
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo -e "${RED}Error: Not a git repository. Please cd into your repo first.${NC}"
    exit 1
fi

REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
CURRENT_BRANCH=$(git branch --show-current)
TOTAL_COMMITS=$(git rev-list --count HEAD)

# =============================================================================
# PHASE 2: --apply — Apply the mapping
# =============================================================================
if [ "$APPLY" = true ]; then
    if [ ! -f "$MAPPING_FILE" ]; then
        echo -e "${RED}Error: ${MAPPING_FILE} not found. Run without --apply first.${NC}"
        exit 1
    fi

    # Normalize encoding (UTF-16, BOM, CRLF)
    CLEAN_MAPPING=$(mktemp)
    ENCODING=$(file --brief "$MAPPING_FILE")
    if echo "$ENCODING" | grep -qi 'utf-16\|ucs-2'; then
        iconv -f UTF-16 -t UTF-8 "$MAPPING_FILE" | tr -d '\r' | sed '1s/^\xEF\xBB\xBF//' > "$CLEAN_MAPPING"
    elif echo "$ENCODING" | grep -qi 'utf-8.*bom\|bom.*utf-8'; then
        sed '1s/^\xEF\xBB\xBF//' "$MAPPING_FILE" | tr -d '\r' > "$CLEAN_MAPPING"
    else
        tr -d '\r' < "$MAPPING_FILE" > "$CLEAN_MAPPING"
    fi

    REWRITE_COUNT=$(grep -c '|REWRITE|' "$CLEAN_MAPPING" || true)

    if [ "$REWRITE_COUNT" -eq 0 ]; then
        echo -e "${RED}Error: No |REWRITE| lines found in ${MAPPING_FILE}${NC}"
        rm -f "$CLEAN_MAPPING"
        exit 1
    fi

    echo -e "${CYAN}=== Git History Rewriter — APPLY ===${NC}"
    echo ""
    echo -e "  Repo:            ${GREEN}${REPO_NAME}${NC}"
    echo -e "  Branch:          ${GREEN}${CURRENT_BRANCH}${NC}"
    echo -e "  Total Commits:   ${GREEN}${TOTAL_COMMITS}${NC}"
    echo -e "  To Rewrite:      ${GREEN}${REWRITE_COUNT}${NC}"
    echo ""

    # Validate Hashes
    echo -e "${CYAN}Validating mapping...${NC}"
    MISSING=0
    while IFS='|' read -r HASH ACTION _ _; do
        if [ "$ACTION" = "REWRITE" ]; then
            if ! git cat-file -t "$HASH" > /dev/null 2>&1; then
                echo -e "  ${RED}Hash not found: ${HASH}${NC}"
                MISSING=$((MISSING + 1))
            fi
        fi
    done < "$CLEAN_MAPPING"

    if [ "$MISSING" -gt 0 ]; then
        echo -e "${RED}${MISSING} hash(es) missing. Are you in the correct repository?${NC}"
        rm -f "$CLEAN_MAPPING"
        exit 1
    fi
    echo -e "  ${GREEN}All ${REWRITE_COUNT} hashes verified.${NC}"
    echo ""

    # Backup
    BACKUP_BRANCH="backup-before-rewrite-$(date +%Y%m%d-%H%M%S)"
    git branch "$BACKUP_BRANCH"
    echo -e "${GREEN}Backup created: ${BACKUP_BRANCH}${NC}"
    echo ""

    # Prepare lookup file
    LOOKUP_FILE=$(mktemp)
    grep '|REWRITE|' "$CLEAN_MAPPING" | awk -F'|' '{print $1"\t"$4}' > "$LOOKUP_FILE"

    FILTER_SCRIPT=$(mktemp)
    cat > "$FILTER_SCRIPT" << FILTEREOF
#!/bin/bash
NEW_MSG=\$(grep "^\${GIT_COMMIT}	" "${LOOKUP_FILE}" | cut -f2-)
if [ -n "\$NEW_MSG" ]; then
    printf '%s' "\$NEW_MSG"
else
    cat
fi
FILTEREOF

    # Stash worktree changes if any
    STASHED=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        echo -e "${YELLOW}Changes detected in worktree. Creating stash...${NC}"
        git stash push -m "git-rewrite-ai: auto-stash" --include-untracked
        STASHED=true
    fi

    # Execute
    echo -e "${YELLOW}Starting git filter-branch... (This may take a while)${NC}"
    echo ""

    FILTER_BRANCH_SQUELCH_WARNING=1 \
    git filter-branch -f --msg-filter "bash \"${FILTER_SCRIPT}\"" -- HEAD 2>&1 | tail -3

    # Restore stash
    if [ "$STASHED" = true ]; then
        echo ""
        echo -e "${YELLOW}Restoring stash...${NC}"
        git stash pop
    fi

    echo ""

    # Verification
    echo -e "${CYAN}Verification...${NC}"
    NEW_TOTAL=$(git rev-list --count HEAD)
    CONVENTIONAL=$(git log --oneline | grep -cE '^[a-f0-9]+ (feat|fix|chore|docs|refactor|style|perf|test|ci|build|revert)[(!:]' || true)

    echo ""
    echo -e "  Commits before:  ${GREEN}${TOTAL_COMMITS}${NC}"
    echo -e "  Commits after:   ${GREEN}${NEW_TOTAL}${NC}"
    echo -e "  Conventional:    ${GREEN}${CONVENTIONAL}${NC}"
    echo ""

    if [ "$TOTAL_COMMITS" -eq "$NEW_TOTAL" ]; then
        echo -e "${GREEN}Commit count matches.${NC}"
    else
        echo -e "${RED}WARNING: Commit count mismatch! Expected ${TOTAL_COMMITS}, got ${NEW_TOTAL}.${NC}"
    fi

    rm -f "$CLEAN_MAPPING" "$LOOKUP_FILE" "$FILTER_SCRIPT"

    echo ""
    echo -e "${GREEN}=== Finished! ===${NC}"
    echo ""
    echo -e "  Backup branch: ${CYAN}${BACKUP_BRANCH}${NC}"
    echo -e "  To push:       ${YELLOW}git push --force origin ${CURRENT_BRANCH}${NC}"
    echo -e "  To undo:       ${YELLOW}git reset --hard ${BACKUP_BRANCH}${NC}"
    exit 0
fi

# =============================================================================
# PHASE 1: Generate mapping via Ollama
# =============================================================================

# Check Ollama status
if ! curl -s "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
    echo -e "${RED}Error: Ollama not reachable at ${OLLAMA_URL}${NC}"
    echo -e "${RED}Please start Ollama first.${NC}"
    exit 1
fi

# Check if model exists
if ! curl -s "${OLLAMA_URL}/api/tags" | grep -q "\"${MODEL}\""; then
    echo -e "${RED}Error: Model '${MODEL}' not found in Ollama.${NC}"
    echo -e "${RED}Available models:${NC}"
    curl -s "${OLLAMA_URL}/api/tags" | grep '"name"' | sed 's/.*"name":"\([^"]*\)".*/  \1/'
    exit 1
fi

echo -e "${CYAN}=== Git History Rewriter — GENERATE ===${NC}"
echo ""
echo -e "  Repo:            ${GREEN}${REPO_NAME}${NC}"
echo -e "  Branch:          ${GREEN}${CURRENT_BRANCH}${NC}"
echo -e "  Total Commits:   ${GREEN}${TOTAL_COMMITS}${NC}"
echo -e "  Ollama Model:    ${GREEN}${MODEL}${NC}"
echo -e "  Output File:     ${GREEN}${MAPPING_FILE}${NC}"
echo ""

# Conventional commit regex
CC_REGEX='^(feat|fix|chore|docs|refactor|style|perf|test|ci|build|revert)[(!\:]'

# Tracking
DONE=0
SKIPPED=0
REWRITTEN=0
RESUMED=0

# Check for resume support
EXISTING_HASHES=""
if [ -f "$MAPPING_FILE" ] && [ -s "$MAPPING_FILE" ]; then
    EXISTING_HASHES=$(cut -d'|' -f1 "$MAPPING_FILE")
    RESUMED=$(wc -l < "$MAPPING_FILE" | tr -d ' ')
    echo -e "  ${CYAN}Existing mapping found: ${RESUMED} commits already processed. Resuming...${NC}"
    echo ""
fi

while IFS= read -r LINE; do
    HASH=$(echo "$LINE" | cut -d' ' -f1)
    MSG=$(echo "$LINE" | cut -d' ' -f2-)

    DONE=$((DONE + 1))

    # Skip if already in mapping
    if echo "$EXISTING_HASHES" | grep -q "^${HASH}$"; then
        printf "\r  [%d/%d] ${CYAN}SKIP${NC}:    %-60.60s" "$DONE" "$TOTAL_COMMITS" "(already mapped)"
        continue
    fi

    # Skip if already conventional
    if echo "$MSG" | grep -qE "$CC_REGEX"; then
        echo "${HASH}|OK|${MSG}" >> "$MAPPING_FILE"
        SKIPPED=$((SKIPPED + 1))
        printf "\r  [%d/%d] ${GREEN}OK${NC}:      %-60.60s" "$DONE" "$TOTAL_COMMITS" "$MSG"
        continue
    fi

    # Get context (changed files)
    CHANGED_FILES=$(git diff-tree --no-commit-id --name-only -r "$HASH" 2>/dev/null | head -15 | tr '\n' ', ' | sed 's/,$//')

    # Ollama Prompt
    PROMPT="Rewrite this git commit message as a single conventional commit.

Rules:
- Format: type(scope): description
- Types: feat, fix, chore, docs, refactor, style, perf, test, ci, build
- Scope: short, based on the changed files (optional if unclear)
- Description: lowercase, imperative, max 72 chars total
- Output ONLY the new commit message, nothing else
- No quotes or backticks

Changed files: ${CHANGED_FILES}
Original message: ${MSG}"

    # JSON-safe encoding
    JSON_PROMPT=$(printf '%s' "$PROMPT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

    RESPONSE=$(curl -s "${OLLAMA_URL}/api/chat" \
        -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":${JSON_PROMPT}}],\"stream\":false,\"options\":{\"temperature\":0.1,\"num_predict\":100}}" \
        --max-time 60 2>/dev/null)

    # Parse JSON response
    NEW_MSG=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    msg = data.get('message', {}).get('content', '').strip()
    msg = msg.split(chr(10))[0].strip()
    for c in [chr(96), chr(34), chr(39), chr(42)]:
        msg = msg.strip(c)
    print(msg)
except:
    print('')
" 2>/dev/null)

    # Fallback if AI fails
    if [ -z "$NEW_MSG" ] || [ ${#NEW_MSG} -gt 120 ]; then
        echo "${HASH}|REWRITE|${MSG}|chore: ${MSG}" >> "$MAPPING_FILE"
        REWRITTEN=$((REWRITTEN + 1))
        printf "\r  [%d/%d] ${YELLOW}FALLBACK${NC}: %-55.55s" "$DONE" "$TOTAL_COMMITS" "$MSG"
    else
        echo "${HASH}|REWRITE|${MSG}|${NEW_MSG}" >> "$MAPPING_FILE"
        REWRITTEN=$((REWRITTEN + 1))
        printf "\r  [%d/%d] ${GREEN}REWRITE${NC}:  %-55.55s" "$DONE" "$TOTAL_COMMITS" "$NEW_MSG"
    fi

done < <(git log --reverse --format='%H %s')

echo ""
echo ""
echo -e "${GREEN}=== Mapping Generation Complete ===${NC}"
echo ""
if [ "$RESUMED" -gt 0 ]; then
    echo -e "  Resumed from:    ${CYAN}${RESUMED}${NC}"
fi
echo -e "  Already OK:      ${GREEN}${SKIPPED}${NC}"
echo -e "  Rewritten:       ${GREEN}${REWRITTEN}${NC}"
echo -e "  Total:           ${GREEN}${DONE}${NC}"
echo -e "  Saved to:        ${GREEN}${MAPPING_FILE}${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "  1. Review ${MAPPING_FILE} and manually edit any messages you don't like."
echo -e "  2. Run: bash git-rewrite-ai.sh --apply"
