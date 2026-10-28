#!/bin/bash
# ventii-server-bot.sh — Telegram bot for running the Ventii production server via Claude Code
# Ops, deploys, data and code changes on the Ventii box. Risky actions wait for approval;
# code changes go through git so everything can be reverted.
# Dependencies: claude, curl, jq, docker (via sudo)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_DIR="$HOME/claude-logs"
PROMPT_FILE="$LOG_DIR/.ventii-system-prompt.txt"

# ── Load secrets from .env (gitignored) ──────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

# ── Config ───────────────────────────────────────────────────
TG_BOT_TOKEN="${VENTII_TG_BOT_TOKEN:-}"
ALLOWED_CHAT_IDS="${VENTII_ALLOWED_CHAT_IDS:-${ALLOWED_CHAT_IDS:-${TG_CHAT_ID:-}}}"
ALERT_CHAT_ID="${VENTII_ALERT_CHAT_ID:-${ALLOWED_CHAT_IDS%%,*}}"
VENTII_DIR="${VENTII_DIR:-$HOME/ventii_react_native}"
VENTII_URL="${VENTII_URL:-https://ventii.andrewbrowne.org}"
VENTII_BACKUP_DIR="${VENTII_BACKUP_DIR:-$HOME/ventii-deploy-backup}"
VENTII_CONTAINERS="${VENTII_CONTAINERS:-ventii-backend ventii-daphne ventii-redis ventii-neo4j}"
HEALTH_INTERVAL="${VENTII_HEALTH_INTERVAL:-300}"   # seconds between health checks
DISK_ALERT_PCT="${VENTII_DISK_ALERT_PCT:-90}"
CLAUDE_TIMEOUT="${VENTII_CLAUDE_TIMEOUT:-900}"     # deploys can take a while

mkdir -p "$LOG_DIR"

# Write the system prompt to a file (avoids shell escaping hell)
cat > "$PROMPT_FILE" <<SYSTEMPROMPT
You are the Ventii server bot. You run on the Ventii production server and Andrew talks to you over Telegram.
You handle ops, deploys, data and code for the Ventii app.

=== THE SERVER ===
- Repo: $VENTII_DIR (monorepo; Django backend in backend/, prod stack in docker-compose.prod.yml, branch "prod")
- Deploy runbook: $VENTII_DIR/DEPLOY_AGENT.md — follow it for deploys
- Live site: $VENTII_URL (nginx on the host as a systemd service -> backend :8000)
- Containers: $VENTII_CONTAINERS (ventii-neo4j is not in docker-compose.prod.yml)
- Docker needs sudo: use "sudo docker ..." and "sudo docker compose -f docker-compose.prod.yml ..."
- Database: SQLite in docker volume ventii_react_native_backend-data, mounted at /app/data in ventii-backend
- Media: /srv/ventii/media   Static: /srv/ventii/static
- DB backups: $VENTII_BACKUP_DIR (name them <reason>-YYYYMMDD-HHMMSS.sqlite3)
- Django commands: sudo docker exec ventii-backend python manage.py <cmd>

=== APPROVAL GATE ===
These actions need approval BEFORE you do them:
- deploying, rebuilding images, docker compose up/down/restart, restarting nginx
- migrations, or anything that writes/deletes production data
- merging or pushing to the prod branch, force pushes, deleting branches/files/volumes/backups
- anything else that could take the site down or lose data
For these: do NOT act. Reply with a message starting with "APPROVAL NEEDED:" stating exactly
what you will run and why, then stop. Only proceed when a later message explicitly approves it
(e.g. "approved", "yes go ahead"). Approval covers only the action you described, nothing more.
Read-only actions (status, logs, ps, df, queries, reading code, git log/diff) need no approval.

=== VERSION CONTROL ===
- Never edit code directly on the prod branch. Create a branch "bot/<short-description>",
  commit there with a clear message, and push the branch. Merging to prod needs approval.
- Leave the working tree clean when you finish (no stray uncommitted edits).
- If something you changed breaks, the fix is git revert, not hand-editing on the server.
- Before any deploy or migration, copy the SQLite DB to $VENTII_BACKUP_DIR first and say where you put it.

=== RULES ===
- Be concise — this is read on a phone. Say what you did and the result.
- Never print secrets (.env files, backend/secrets/, tokens) into chat.
- If something fails, show the relevant error lines and propose the fix.
- After any deploy or restart, verify: curl -s -o /dev/null -w "%{http_code}" $VENTII_URL/admin/login/ (expect 200) and check container status.
SYSTEMPROMPT

# ── Telegram helpers ─────────────────────────────────────────

_tg_send() {
    local chat_id="$1"
    local text="$2"
    local max=4000

    if [[ ${#text} -le $max ]]; then
        curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${chat_id}" \
            --data-urlencode "text=${text}" >/dev/null 2>&1 || true
    else
        while [[ ${#text} -gt 0 ]]; do
            local chunk="${text:0:$max}"
            curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
                -d "chat_id=${chat_id}" \
                --data-urlencode "text=${chunk}" >/dev/null 2>&1 || true
            text="${text:$max}"
            [[ ${#text} -gt 0 ]] && sleep 0.5
        done
    fi
}

# ── Health checks ────────────────────────────────────────────

# Prints one line per problem; prints nothing when healthy
_health_problems() {
    local name state
    for name in $VENTII_CONTAINERS; do
        state=$(sudo -n docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
        [[ "$state" != "running" ]] && echo "container $name: $state"
    done

    local code
    code=$(curl -s -o /dev/null --max-time 15 -w "%{http_code}" "$VENTII_URL/admin/login/" 2>/dev/null || echo "000")
    [[ "$code" != "200" ]] && echo "site $VENTII_URL: HTTP $code"

    local pct
    pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
    [[ "$pct" -ge "$DISK_ALERT_PCT" ]] && echo "disk /: ${pct}% used"

    if ! sudo -n systemctl is-active --quiet nginx 2>/dev/null; then
        echo "nginx: not active"
    fi
    return 0
}

_status_report() {
    local code pct
    code=$(curl -s -o /dev/null --max-time 15 -w "%{http_code}" "$VENTII_URL/admin/login/" 2>/dev/null || echo "000")
    pct=$(df --output=pcent / | tail -1 | tr -d ' ')
    echo "Site: HTTP $code"
    echo "Disk /: $pct used"
    echo "Load: $(cut -d' ' -f1-3 /proc/loadavg)"
    echo "Mem: $(free -h | awk '/Mem:/ {print $3 " / " $2}')"
    echo "nginx: $(systemctl is-active nginx 2>/dev/null || echo unknown)"
    echo ""
    sudo -n docker ps -a --filter "name=ventii" --format '{{.Names}}: {{.Status}}' 2>/dev/null \
        || echo "(docker unavailable)"
    echo ""
    echo "Git: $(git -C "$VENTII_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) @ $(git -C "$VENTII_DIR" log -1 --format='%h %s' 2>/dev/null)"
}

# Alerts only on change, so a long outage doesn't spam every interval
_health_loop() {
    echo "[$(date)] Health checker started (every ${HEALTH_INTERVAL}s)"
    local last=""
    while true; do
        sleep "$HEALTH_INTERVAL"
        local now
        now=$(_health_problems 2>/dev/null || true)
        if [[ "$now" != "$last" ]]; then
            if [[ -n "$now" ]]; then
                _tg_send "$ALERT_CHAT_ID" "⚠️ Ventii server problem:
$now"
                echo "[$(date)] Alert: $now"
            elif [[ -n "$last" ]]; then
                _tg_send "$ALERT_CHAT_ID" "✅ Ventii server recovered."
                echo "[$(date)] Recovered"
            fi
            last="$now"
        fi
    done
}

# ── Claude runner ────────────────────────────────────────────

_run_claude() {
    local text="$1" session_file="$2" use_session="$3"
    local cmd=("$CLAUDE_BIN" -p --output-format json
        --allowedTools "Bash,Read,Edit,Write,Glob,Grep"
        --dangerously-skip-permissions
        --append-system-prompt-file "$PROMPT_FILE")

    if [[ "$use_session" == "yes" && -f "$session_file" ]]; then
        local prev_session
        prev_session=$(cat "$session_file")
        [[ -n "$prev_session" ]] && cmd+=(--resume "$prev_session")
    fi

    (cd "$VENTII_DIR" && timeout "$CLAUDE_TIMEOUT" "${cmd[@]}" -- "$text" 2>&1)
}

# ── Bot loop ─────────────────────────────────────────────────

cmd_start() {
    if [[ -z "$TG_BOT_TOKEN" ]]; then
        echo "Error: VENTII_TG_BOT_TOKEN not set in .env" >&2
        return 1
    fi
    # This bot has root-equivalent access to prod — never run it open to everyone
    if [[ -z "$ALLOWED_CHAT_IDS" ]]; then
        echo "Error: set VENTII_ALLOWED_CHAT_IDS (or ALLOWED_CHAT_IDS) in .env" >&2
        return 1
    fi

    local offset=0
    local session_file="$LOG_DIR/ventii-bot-session.id"

    # Skip old messages
    local init
    init=$(curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=-1" 2>/dev/null)
    offset=$(echo "$init" | jq -r '.result[-1].update_id // 0')
    [[ "$offset" != "0" ]] && offset=$((offset + 1))

    echo "[$(date)] Ventii server bot started. Offset: $offset"

    _health_loop &
    local health_pid=$!
    trap "kill $health_pid 2>/dev/null" EXIT

    CLAUDE_BIN=$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")

    _tg_send "$ALERT_CHAT_ID" "Ventii server bot is online."

    while true; do
        local updates
        updates=$(curl -sf --max-time 35 \
            "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=${offset}&timeout=30" \
            2>/dev/null) || { sleep 2; continue; }

        local count
        count=$(echo "$updates" | jq -r '.result | length')
        [[ "$count" == "0" || "$count" == "null" ]] && continue

        local i=0
        while [[ $i -lt $count ]]; do
            local update
            update=$(echo "$updates" | jq -c ".result[$i]")
            i=$((i + 1))

            local update_id chat_id text
            update_id=$(echo "$update" | jq -r '.update_id')
            chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
            text=$(echo "$update" | jq -r '.message.text // empty')

            offset=$((update_id + 1))
            [[ -z "$text" || -z "$chat_id" ]] && continue

            # Security
            if ! echo ",$ALLOWED_CHAT_IDS," | grep -q ",$chat_id,"; then
                echo "[$(date)] Unauthorized chat $chat_id"
                _tg_send "$chat_id" "Unauthorized."
                continue
            fi

            echo "[$(date)] Message: $text"

            # Commands
            case "$text" in
                /start|/help)
                    _tg_send "$chat_id" "Ventii Server Bot (powered by Claude Code)

Tell me what you need:
• \"Why is the backend erroring? check the logs\"
• \"Deploy latest prod\"
• \"How many users signed up this week?\"
• \"Fix the feed pagination bug\"

Risky actions (deploys, restarts, data writes, merges) wait for approval.
Code changes go on bot/* branches.

/status — server health
/new — fresh conversation"
                    continue
                    ;;
                /new)
                    rm -f "$session_file"
                    _tg_send "$chat_id" "Fresh conversation started."
                    continue
                    ;;
                /status)
                    _tg_send "$chat_id" "$(_status_report 2>&1)"
                    continue
                    ;;
            esac

            _tg_send "$chat_id" "On it..."

            local logfile="$LOG_DIR/ventii-$(date +%Y%m%d-%H%M%S).json"

            echo "[$(date)] Running Claude Code..."
            local result exit_code=0
            result=$(_run_claude "$text" "$session_file" yes) || exit_code=$?

            if [[ $exit_code -ne 0 ]]; then
                # Retry without session
                echo "[$(date)] Exit $exit_code, retrying fresh..."
                rm -f "$session_file"
                exit_code=0
                result=$(_run_claude "$text" "$session_file" no) || exit_code=$?
            fi
            echo "$result" > "$logfile"
            echo "[$(date)] Exit: $exit_code"

            local new_session
            new_session=$(echo "$result" | jq -r '.session_id // empty' 2>/dev/null)
            [[ -n "$new_session" ]] && echo "$new_session" > "$session_file"

            local response
            response=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)
            if [[ -z "$response" ]]; then
                if [[ $exit_code -eq 124 ]]; then
                    response="Timed out after ${CLAUDE_TIMEOUT}s. Check /status."
                elif [[ $exit_code -ne 0 ]]; then
                    response="Error (exit $exit_code)"
                else
                    response="Done (no text output)"
                fi
            fi
            _tg_send "$chat_id" "$response"

            echo "[$(date)] Done"
        done
    done
}

case "${1:-help}" in
    start)         cmd_start ;;
    status)        _status_report ;;
    help|--help|-h)
        echo "ventii-server-bot.sh — Ventii server bot via Claude Code"
        echo ""
        echo "  start   Run the bot (use via systemd)"
        echo "  status  Print server health"
        echo ""
        echo "systemctl --user restart ventii-server-bot"
        echo "journalctl --user -u ventii-server-bot -f"
        ;;
    *)             echo "Unknown: $1" >&2; exit 1 ;;
esac
