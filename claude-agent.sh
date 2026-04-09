#!/bin/bash
# claude-agent.sh — Claude Code automation for server + Telegram two-way chat
# Your setup: SSH into server, tmux sessions, notifications via ntfy/Telegram
# Dependencies: claude, curl, jq (that's it)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_DIR="$HOME/claude-logs"
CRON_TAG="# claude-agent"
PIDFILE="$HOME/.claude-telegram-bot.pid"

# ── Load secrets from .env (gitignored) ──────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

# ── Config (edit these or run 'setup') ───────────────────────
NOTIFY_METHOD="${NOTIFY_METHOD:-auto}"       # auto, ntfy, telegram, both, none
NTFY_TOPIC="${NTFY_TOPIC:-}"                 # your ntfy.sh topic (pick something secret)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
ALLOWED_CHAT_IDS="${ALLOWED_CHAT_IDS:-}"
DEFAULT_TOOLS="Bash,Read,Edit,Write,Glob,Grep"
DEFAULT_MODEL=""           # e.g. opus, sonnet — leave empty for default
DEFAULT_EFFORT=""          # e.g. high — leave empty for default
BOT_SYSTEM_PROMPT=""
PLAN_DIR="$HOME/claude-plans"  # where plans are stored

mkdir -p "$LOG_DIR" "$PLAN_DIR"

# ══════════════════════════════════════════════════════════════
#  NOTIFICATIONS
# ══════════════════════════════════════════════════════════════

notify() {
    local title="${1:-Claude Agent}"
    local message="${2:-Task completed}"

    case "$NOTIFY_METHOD" in
        ntfy)       _notify_ntfy "$title" "$message" ;;
        telegram)   _notify_telegram "$title" "$message" ;;
        both|auto)
            _notify_ntfy "$title" "$message"
            _notify_telegram "$title" "$message"
            ;;
        none) ;;
    esac
}

_notify_ntfy() {
    local title="$1" message="$2"
    [[ -z "$NTFY_TOPIC" ]] && return 0
    curl -sf \
        -H "Title: $title" \
        -H "Priority: high" \
        -H "Tags: robot" \
        -d "$message" \
        "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

_notify_telegram() {
    local title="$1" message="$2"
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    local text="${title}: ${message}"
    curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

# Send a long message to Telegram (handles 4096 char limit)
_tg_send() {
    local chat_id="$1"
    local text="$2"
    local max=4000

    # Truncate if way too long (Telegram max is ~4096 per message)
    if [[ ${#text} -le $max ]]; then
        curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${chat_id}" \
            --data-urlencode "text=${text}" 2>&1 || true
    else
        # Split into chunks
        while [[ ${#text} -gt 0 ]]; do
            local chunk="${text:0:$max}"
            curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
                -d "chat_id=${chat_id}" \
                --data-urlencode "text=${chunk}" 2>&1 || true
            text="${text:$max}"
            [[ ${#text} -gt 0 ]] && sleep 0.5
        done
    fi
}

# ══════════════════════════════════════════════════════════════
#  TELEGRAM TWO-WAY BOT
# ══════════════════════════════════════════════════════════════

cmd_bot() {
    local action="${1:-start}"

    case "$action" in
        start)  _bot_start ;;
        stop)   _bot_stop ;;
        status) _bot_status ;;
        *)      echo "Usage: $SCRIPT_NAME bot [start|stop|status]" ;;
    esac
}

_bot_start() {
    if [[ -z "$TG_BOT_TOKEN" ]]; then
        echo "Error: TG_BOT_TOKEN not set. Run '$SCRIPT_NAME setup' first." >&2
        return 1
    fi

    # Check if already running
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Bot already running (PID $(cat "$PIDFILE"))"
        return 0
    fi

    echo "Starting Telegram bot..."

    # Auto-detect chat ID if not set
    if [[ -z "$TG_CHAT_ID" ]]; then
        echo "TG_CHAT_ID not set. Send any message to your bot, then press Enter."
        read -r
        local updates
        updates=$(curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates" 2>/dev/null)
        TG_CHAT_ID=$(echo "$updates" | jq -r '.result[-1].message.chat.id // empty')
        if [[ -z "$TG_CHAT_ID" ]]; then
            echo "Error: Could not detect chat ID. Send a message to your bot and try again." >&2
            return 1
        fi
        echo "Detected chat ID: $TG_CHAT_ID"
        sed -i "s/^TG_CHAT_ID=.*/TG_CHAT_ID=\"$TG_CHAT_ID\"/" "$0"
        ALLOWED_CHAT_IDS="$TG_CHAT_ID"
        sed -i "s/^ALLOWED_CHAT_IDS=.*/ALLOWED_CHAT_IDS=\"$TG_CHAT_ID\"/" "$0"
    fi

    # Launch bot loop in background
    nohup "$0" _bot_loop > "$LOG_DIR/telegram-bot.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$PIDFILE"
    echo "Bot started (PID $pid)"
    echo "Log: $LOG_DIR/telegram-bot.log"
    echo ""
    echo "Now message your bot on Telegram!"

    # Send startup message
    _tg_send "$TG_CHAT_ID" "Claude Agent bot is online. Send me a message and I'll run it through Claude Code."
}

_bot_stop() {
    if [[ -f "$PIDFILE" ]]; then
        local pid
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            # Kill any child claude processes
            pkill -P "$pid" 2>/dev/null || true
            echo "Bot stopped (PID $pid)"
            _tg_send "$TG_CHAT_ID" "Claude Agent bot is going offline."
        else
            echo "Bot was not running"
        fi
        rm -f "$PIDFILE"
    else
        echo "Bot is not running"
    fi
}

_bot_status() {
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Bot is running (PID $(cat "$PIDFILE"))"
        echo "Log: $LOG_DIR/telegram-bot.log"
        echo ""
        echo "Last 5 log lines:"
        tail -5 "$LOG_DIR/telegram-bot.log" 2>/dev/null || true
    else
        echo "Bot is not running"
    fi
}

# Internal: the actual bot polling loop (run via nohup)
cmd__bot_loop() {
    local offset=0

    # Get initial offset (skip old messages)
    local init
    init=$(curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=-1" 2>/dev/null)
    offset=$(echo "$init" | jq -r '.result[-1].update_id // 0')
    [[ "$offset" != "0" ]] && offset=$((offset + 1))

    echo "[$(date)] Bot loop started. Offset: $offset"

    while true; do
        # Long poll (30 second timeout — Telegram holds the connection open)
        local updates
        updates=$(curl -sf --max-time 35 \
            "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=${offset}&timeout=30" \
            2>/dev/null) || { sleep 2; continue; }

        local count
        count=$(echo "$updates" | jq -r '.result | length')

        if [[ "$count" == "0" || "$count" == "null" ]]; then
            continue
        fi

        # Process each update (no subshell — offset stays in scope)
        local i=0
        while [[ $i -lt $count ]]; do
            local update
            update=$(echo "$updates" | jq -c ".result[$i]")
            i=$((i + 1))

            local update_id chat_id text username
            update_id=$(echo "$update" | jq -r '.update_id')
            chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
            text=$(echo "$update" | jq -r '.message.text // empty')
            username=$(echo "$update" | jq -r '.message.from.username // .message.from.first_name // "unknown"')

            # Update offset IMMEDIATELY
            offset=$((update_id + 1))

            # Skip empty messages
            [[ -z "$text" || -z "$chat_id" ]] && continue

            echo "[$(date)] Message from @$username ($chat_id): $text"

            # Security: only allow configured chat IDs
            if [[ -n "$ALLOWED_CHAT_IDS" ]]; then
                if ! echo ",$ALLOWED_CHAT_IDS," | grep -q ",$chat_id,"; then
                    echo "[$(date)] Blocked message from unauthorized chat: $chat_id"
                    _tg_send "$chat_id" "Unauthorized. Your chat ID ($chat_id) is not in the allowed list."
                    continue
                fi
            fi

            # Handle bot commands
            case "$text" in
                    /start)
                        _tg_send "$chat_id" "$(cat <<'MSG'
Claude Agent Bot

Send me any message and I'll run it through Claude Code.

Modes:
• Just send text — runs immediately
• /plan <task> — make a plan first, then approve

Commands:
/plan <task> — create a plan (review before executing)
/plans — list all plans
/new — start a fresh conversation
/status — server status
/jobs — scheduled and background jobs
/log — latest task result
/cancel — cancel running task
/help — this message

Plan responses:
• go / approve — execute the pending plan
• revise: <feedback> — ask for changes
• cancel — discard the plan
MSG
)"
                        continue
                        ;;
                    /help)
                        _tg_send "$chat_id" "Send text to run immediately. Use /plan <task> for plan-first mode. Reply 'go' to approve, 'revise: feedback' to change, 'cancel' to discard."
                        continue
                        ;;
                    /status)
                        local uptime_info load_info
                        uptime_info=$(uptime 2>/dev/null || echo "unknown")
                        load_info=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "unknown")
                        _tg_send "$chat_id" "Server: $(hostname)
Uptime: $uptime_info
Load: $load_info
Bot PID: $$
Working dir: $PWD"
                        continue
                        ;;
                    /jobs)
                        local jobs_output
                        jobs_output=$("$0" jobs 2>&1)
                        _tg_send "$chat_id" "$jobs_output"
                        continue
                        ;;
                    /log)
                        local log_output
                        log_output=$("$0" log 2>&1 | head -c 3500)
                        _tg_send "$chat_id" "$log_output"
                        continue
                        ;;
                    /cancel)
                        # Cancel running tasks AND pending plans
                        local killed=0
                        for pid in $(pgrep -f "claude -p" 2>/dev/null); do
                            kill "$pid" 2>/dev/null && killed=$((killed + 1))
                        done
                        # Also cancel pending plan
                        local pending
                        pending=$("$0" _get_pending_plan 2>/dev/null)
                        if [[ -n "$pending" ]]; then
                            "$0" plan-cancel "$pending" 2>/dev/null
                            _tg_send "$chat_id" "Cancelled $killed task(s) and plan $pending."
                        else
                            _tg_send "$chat_id" "Cancelled $killed running task(s)."
                        fi
                        continue
                        ;;
                    /plans)
                        local plans_output
                        plans_output=$("$0" plan-list 2>&1)
                        _tg_send "$chat_id" "$plans_output"
                        continue
                        ;;
                    /plan\ *)
                        # Create a plan
                        local plan_task="${text#/plan }"
                        _tg_send "$chat_id" "Creating plan..."
                        "$0" plan "$plan_task" 2>&1
                        # plan command already sends to Telegram
                        continue
                        ;;
                esac

                # Handle plan approval/revision responses
                local pending_plan
                pending_plan=$("$0" _get_pending_plan 2>/dev/null || true)

                if [[ -n "$pending_plan" ]]; then
                    local lower_text
                    lower_text=$(echo "$text" | tr '[:upper:]' '[:lower:]')

                    case "$lower_text" in
                        go|approve|yes|lgtm|ship\ it|do\ it|execute|run\ it|send\ it)
                            _tg_send "$chat_id" "Executing plan $pending_plan..."
                            "$0" plan-approve "$pending_plan" 2>&1
                            continue
                            ;;
                        revise:*|change:*|modify:*|update:*|fix:*)
                            local feedback="${text#*: }"
                            _tg_send "$chat_id" "Revising plan..."
                            "$0" plan-revise "$pending_plan" "$feedback" 2>&1
                            continue
                            ;;
                        cancel|nah|nope|scratch\ that|nevermind|never\ mind)
                            "$0" plan-cancel "$pending_plan" 2>&1
                            continue
                            ;;
                    esac
                fi

                # Handle /new to start fresh conversation
                if [[ "$text" == "/new" ]]; then
                    rm -f "$LOG_DIR/tg-session-${chat_id}.id"
                    _tg_send "$chat_id" "Started fresh conversation."
                    continue
                fi

                # Run the prompt through Claude Code
                _tg_send "$chat_id" "Working on it..."

                local logfile="$LOG_DIR/tg-$(date +%Y%m%d-%H%M%S).json"
                local session_file="$LOG_DIR/tg-session-${chat_id}.id"

                # Check for existing session to continue
                local claude_bin
                claude_bin=$(command -v claude 2>/dev/null || echo "/home/andrew/.nvm/versions/node/v24.3.0/bin/claude")

                local cmd=("$claude_bin" -p --output-format json --allowedTools "$DEFAULT_TOOLS" --dangerously-skip-permissions)
                [[ -n "$DEFAULT_MODEL" ]] && cmd+=(--model "$DEFAULT_MODEL")
                [[ -n "$DEFAULT_EFFORT" ]] && cmd+=(--effort "$DEFAULT_EFFORT")
                # Write system prompt to file to avoid shell escaping issues
                if [[ -n "$BOT_SYSTEM_PROMPT" ]]; then
                    local prompt_file="$LOG_DIR/.bot-system-prompt.txt"
                    printf '%s' "$BOT_SYSTEM_PROMPT" > "$prompt_file"
                    cmd+=(--append-system-prompt-file "$prompt_file")
                fi

                # Resume existing session if we have one
                if [[ -f "$session_file" ]]; then
                    local prev_session
                    prev_session=$(cat "$session_file")
                    if [[ -n "$prev_session" ]]; then
                        cmd+=(--resume "$prev_session")
                        echo "[$(date)] Resuming session: $prev_session"
                    fi
                fi

                echo "[$(date)] Running: ${cmd[*]} \"${text}\""
                local result exit_code=0
                result=$(timeout 600 "${cmd[@]}" -- "$text" 2>&1) || exit_code=$?
                echo "[$(date)] Claude exit: $exit_code"
                echo "$result" > "$logfile"

                # Save session ID for next message
                local new_session_id
                new_session_id=$(echo "$result" | jq -r '.session_id // empty' 2>/dev/null)
                if [[ -n "$new_session_id" ]]; then
                    echo "$new_session_id" > "$session_file"
                    echo "[$(date)] Session saved: $new_session_id"
                fi

                if [[ $exit_code -eq 0 ]]; then
                    local response
                    response=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)
                    if [[ -z "$response" ]]; then
                        response="$result"
                    fi
                    _tg_send "$chat_id" "$response"
                elif [[ $exit_code -eq 124 ]]; then
                    _tg_send "$chat_id" "Task timed out after 10 minutes. Check server logs."
                else
                    # If resume failed, try without resume
                    echo "[$(date)] Retrying without session resume..."
                    rm -f "$session_file"
                    local cmd2=("$claude_bin" -p --output-format json --allowedTools "$DEFAULT_TOOLS" --dangerously-skip-permissions)
                    [[ -n "$DEFAULT_MODEL" ]] && cmd2+=(--model "$DEFAULT_MODEL")
                    [[ -n "$DEFAULT_EFFORT" ]] && cmd2+=(--effort "$DEFAULT_EFFORT")
                    if [[ -n "$BOT_SYSTEM_PROMPT" ]]; then
                        local prompt_file="$LOG_DIR/.bot-system-prompt.txt"
                        printf '%s' "$BOT_SYSTEM_PROMPT" > "$prompt_file"
                        cmd2+=(--append-system-prompt-file "$prompt_file")
                    fi

                    result=$(timeout 600 "${cmd2[@]}" -- "$text" 2>&1) || exit_code=$?
                    echo "$result" > "$logfile"

                    new_session_id=$(echo "$result" | jq -r '.session_id // empty' 2>/dev/null)
                    [[ -n "$new_session_id" ]] && echo "$new_session_id" > "$session_file"

                    local response
                    response=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)
                    [[ -z "$response" ]] && response="Error (exit $exit_code). Check: $logfile"
                    _tg_send "$chat_id" "$response"
                fi

                echo "[$(date)] Task complete (exit $exit_code)"
            done
    done
}

# ══════════════════════════════════════════════════════════════
#  PLAN MODE — plan → review → approve → execute cycle
# ══════════════════════════════════════════════════════════════

# Plan mode flow:
#   1. You send a task (via Telegram or CLI)
#   2. Claude makes a plan in read-only mode (no file changes)
#   3. Plan is sent to you on Telegram with inline keyboard
#   4. You reply: "go" / "approve" → execute | "revise: ..." → new plan | "cancel"
#   5. On execute, Claude runs the plan with full tools
#   6. Result sent back to you

cmd_plan() {
    local prompt="${1:?Usage: $SCRIPT_NAME plan \"what you want done\"}"
    shift
    local dir="${1:-$PWD}"

    local plan_id="plan-$(date +%Y%m%d-%H%M%S)"
    local plan_file="$PLAN_DIR/${plan_id}.md"
    local session_file="$PLAN_DIR/${plan_id}.session"

    echo "Creating plan for: $prompt"

    # Step 1: Generate plan in read-only mode
    local plan_prompt="I need you to create a detailed implementation plan for the following task. Do NOT make any changes yet. Just analyze the codebase and create a step-by-step plan.

Task: $prompt

Your plan should include:
1. What files need to be created/modified
2. Step-by-step implementation order
3. Any risks or things to watch out for
4. Estimated complexity (simple/medium/complex)

Output ONLY the plan, formatted in markdown."

    local cmd=(claude -p --output-format json --permission-mode plan)
    [[ -n "$DEFAULT_MODEL" ]] && cmd+=(--model "$DEFAULT_MODEL")
    cmd+=("$plan_prompt")

    local result
    result=$(cd "$dir" && timeout 300 "${cmd[@]}" 2>&1) || true

    local plan_text session_id
    plan_text=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)
    session_id=$(echo "$result" | jq -r '.session_id // empty' 2>/dev/null)

    if [[ -z "$plan_text" ]]; then
        echo "Error generating plan"
        echo "$result"
        return 1
    fi

    # Save plan and session
    echo "$plan_text" > "$plan_file"
    echo "$session_id" > "$session_file"
    # Save metadata
    cat > "$PLAN_DIR/${plan_id}.meta" <<META
PROMPT=$(printf '%q' "$prompt")
DIR=$dir
STATUS=pending
CREATED=$(date -Iseconds)
META

    echo "$plan_text"
    echo ""
    echo "Plan saved: $plan_id"
    echo "  approve:  $SCRIPT_NAME plan-approve $plan_id"
    echo "  revise:   $SCRIPT_NAME plan-revise $plan_id \"your feedback\""
    echo "  cancel:   $SCRIPT_NAME plan-cancel $plan_id"

    # Send to Telegram if configured
    if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
        _tg_send "$TG_CHAT_ID" "📋 *Plan: ${plan_id}*

${plan_text:0:3500}

Reply with:
• \`go\` or \`approve\` — execute this plan
• \`revise: your feedback\` — ask for changes
• \`cancel\` — discard"
    fi

    # Also notify via ntfy
    if [[ -n "$NTFY_TOPIC" ]]; then
        curl -sf \
            -H "Title: Plan Ready: $plan_id" \
            -H "Priority: high" \
            -H "Tags: clipboard" \
            -H "Actions: view, Open plan, $(_plan_ntfy_url "$plan_id")" \
            -d "${plan_text:0:3500}" \
            "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
    fi
}

_plan_ntfy_url() {
    echo "https://ntfy.sh/$NTFY_TOPIC"
}

cmd_plan_approve() {
    local plan_id="${1:?Usage: $SCRIPT_NAME plan-approve <plan-id>}"
    local plan_file="$PLAN_DIR/${plan_id}.md"
    local meta_file="$PLAN_DIR/${plan_id}.meta"

    if [[ ! -f "$plan_file" ]]; then
        echo "Plan not found: $plan_id" >&2
        return 1
    fi

    # Load metadata
    source "$meta_file"
    local prompt="$PROMPT"
    local dir="$DIR"

    # Mark as approved
    sed -i 's/^STATUS=.*/STATUS=executing/' "$meta_file"

    local plan_text
    plan_text=$(cat "$plan_file")

    echo "Executing plan: $plan_id"
    notify "Plan Approved" "Executing: $plan_id"

    # Execute with full tools, referencing the plan
    local exec_prompt="Execute the following plan. Follow it step by step. Do not deviate from the plan unless you encounter an issue, in which case explain what happened.

Original task: $prompt

Plan:
$plan_text"

    local logfile="$LOG_DIR/${plan_id}-exec.json"
    local cmd=(claude -p --output-format json --allowedTools "$DEFAULT_TOOLS" --dangerously-skip-permissions)
    [[ -n "$DEFAULT_MODEL" ]] && cmd+=(--model "$DEFAULT_MODEL")
    [[ -n "$DEFAULT_EFFORT" ]] && cmd+=(--effort "$DEFAULT_EFFORT")
    cmd+=("$exec_prompt")

    local result exit_code=0
    result=$(cd "$dir" && timeout 600 "${cmd[@]}" 2>&1) || exit_code=$?
    echo "$result" > "$logfile"

    local response
    response=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)
    [[ -z "$response" ]] && response="Error (exit $exit_code): $(echo "$result" | head -c 500)"

    sed -i 's/^STATUS=.*/STATUS=completed/' "$meta_file"

    echo "$response"
    notify "Plan Complete" "${response:0:200}"

    if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
        _tg_send "$TG_CHAT_ID" "Plan $plan_id completed:

$response"
    fi
}

cmd_plan_revise() {
    local plan_id="${1:?Usage: $SCRIPT_NAME plan-revise <plan-id> \"feedback\"}"
    local feedback="${2:?Usage: $SCRIPT_NAME plan-revise <plan-id> \"your feedback\"}"
    local plan_file="$PLAN_DIR/${plan_id}.md"
    local meta_file="$PLAN_DIR/${plan_id}.meta"

    if [[ ! -f "$plan_file" ]]; then
        echo "Plan not found: $plan_id" >&2
        return 1
    fi

    source "$meta_file"
    local prompt="$PROMPT"
    local dir="$DIR"

    local old_plan
    old_plan=$(cat "$plan_file")

    echo "Revising plan: $plan_id"

    local revise_prompt="I previously created this plan:

$old_plan

The user wants changes:
$feedback

Original task: $prompt

Create a revised plan incorporating this feedback. Output ONLY the revised plan in markdown."

    local cmd=(claude -p --output-format json --permission-mode plan)
    [[ -n "$DEFAULT_MODEL" ]] && cmd+=(--model "$DEFAULT_MODEL")
    cmd+=("$revise_prompt")

    local result
    result=$(cd "$dir" && timeout 300 "${cmd[@]}" 2>&1) || true

    local new_plan
    new_plan=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)

    if [[ -z "$new_plan" ]]; then
        echo "Error revising plan"
        return 1
    fi

    # Save revised plan
    echo "$new_plan" > "$plan_file"
    sed -i 's/^STATUS=.*/STATUS=revised/' "$meta_file"

    echo "$new_plan"
    echo ""
    echo "Revised plan saved: $plan_id"

    if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
        _tg_send "$TG_CHAT_ID" "📋 *Revised Plan: ${plan_id}*

${new_plan:0:3500}

Reply with:
• \`go\` or \`approve\` — execute this plan
• \`revise: more feedback\` — revise again
• \`cancel\` — discard"
    fi
}

cmd_plan_cancel() {
    local plan_id="${1:?Usage: $SCRIPT_NAME plan-cancel <plan-id>}"
    local meta_file="$PLAN_DIR/${plan_id}.meta"

    if [[ -f "$meta_file" ]]; then
        sed -i 's/^STATUS=.*/STATUS=cancelled/' "$meta_file"
        echo "Cancelled: $plan_id"
        if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
            _tg_send "$TG_CHAT_ID" "Plan $plan_id cancelled."
        fi
    else
        echo "Plan not found: $plan_id" >&2
        return 1
    fi
}

cmd_plan_list() {
    echo "=== Plans ==="
    local found=false
    for meta in "$PLAN_DIR"/*.meta; do
        [[ -f "$meta" ]] || continue
        found=true
        source "$meta"
        local id
        id=$(basename "$meta" .meta)
        printf "  %-25s  %-10s  %s\n" "$id" "$STATUS" "$PROMPT"
    done
    [[ "$found" == false ]] && echo "  (none)"
}

# Get the latest pending plan ID
_get_pending_plan() {
    ls -1t "$PLAN_DIR"/*.meta 2>/dev/null | while read -r meta; do
        source "$meta"
        if [[ "$STATUS" == "pending" || "$STATUS" == "revised" ]]; then
            basename "$meta" .meta
            return 0
        fi
    done
}

# ══════════════════════════════════════════════════════════════
#  RUN TASKS
# ══════════════════════════════════════════════════════════════

cmd_run() {
    local prompt=""
    local tools="$DEFAULT_TOOLS"
    local model="$DEFAULT_MODEL"
    local effort="$DEFAULT_EFFORT"
    local max_turns=""
    local max_budget=""
    local name=""
    local extra_flags=()
    local quiet=false
    local dangerous=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--tools)      tools="$2"; shift 2 ;;
            -m|--model)      model="$2"; shift 2 ;;
            -e|--effort)     effort="$2"; shift 2 ;;
            --max-turns)     max_turns="$2"; shift 2 ;;
            --max-budget)    max_budget="$2"; shift 2 ;;
            -n|--name)       name="$2"; shift 2 ;;
            -q|--quiet)      quiet=true; shift ;;
            --yolo)          dangerous=true; shift ;;
            --append-prompt) extra_flags+=(--append-system-prompt "$2"); shift 2 ;;
            --continue|-c)   extra_flags+=(--continue); shift ;;
            --resume|-r)     extra_flags+=(--resume "$2"); shift 2 ;;
            -*)              echo "Unknown flag: $1" >&2; return 1 ;;
            *)               prompt="$1"; shift ;;
        esac
    done

    if [[ -z "$prompt" ]]; then
        echo "Usage: $SCRIPT_NAME run \"your prompt here\" [options]" >&2
        return 1
    fi

    local cmd=(claude -p --output-format json --allowedTools "$tools")
    [[ -n "$model" ]] && cmd+=(--model "$model")
    [[ -n "$effort" ]] && cmd+=(--effort "$effort")
    [[ -n "$max_turns" ]] && cmd+=(--max-turns "$max_turns")
    [[ -n "$max_budget" ]] && cmd+=(--max-budget-usd "$max_budget")
    [[ -n "$name" ]] && cmd+=(--name "$name")
    [[ "$dangerous" == true ]] && cmd+=(--dangerously-skip-permissions)
    cmd+=("${extra_flags[@]}")
    cmd+=("$prompt")

    local logfile="$LOG_DIR/$(date +%Y%m%d-%H%M%S).json"

    if [[ "$quiet" == true ]]; then
        "${cmd[@]}" > "$logfile" 2>&1
        local exit_code=$?
    else
        "${cmd[@]}" | tee "$logfile"
        local exit_code=${PIPESTATUS[0]}
    fi

    local result_preview="" session_id=""
    if [[ -f "$logfile" ]]; then
        result_preview=$(jq -r '.result // "No result"' "$logfile" 2>/dev/null | head -c 200)
        session_id=$(jq -r '.session_id // "unknown"' "$logfile" 2>/dev/null)
    fi

    if [[ $exit_code -eq 0 ]]; then
        notify "Claude Done" "${result_preview:-Task completed}"
    elif [[ $exit_code -eq 2 ]]; then
        notify "Claude Stopped" "Max turns reached. Session: ${session_id:-unknown}"
    else
        notify "Claude Error" "Exit code $exit_code"
    fi

    return $exit_code
}

# ── Run in background ────────────────────────────────────────

cmd_bg() {
    local logfile="$LOG_DIR/bg-$(date +%Y%m%d-%H%M%S).log"
    echo "Running in background. Log: $logfile"
    nohup "$0" run "$@" -q > "$logfile" 2>&1 &
    local pid=$!
    echo "PID: $pid"
    echo "$pid $(date +%Y%m%d-%H%M%S) $*" >> "$LOG_DIR/bg-jobs.txt"
}

# ── Continue / Resume ────────────────────────────────────────

cmd_continue() {
    local prompt="${1:?Usage: $SCRIPT_NAME continue \"follow-up prompt\"}"
    shift
    cmd_run "$prompt" --continue "$@"
}

cmd_resume() {
    local session="${1:?Usage: $SCRIPT_NAME resume <session-id-or-name> \"prompt\"}"
    local prompt="${2:?Usage: $SCRIPT_NAME resume <session-id-or-name> \"prompt\"}"
    shift 2
    cmd_run "$prompt" --resume "$session" "$@"
}

# ══════════════════════════════════════════════════════════════
#  SCHEDULING
# ══════════════════════════════════════════════════════════════

cmd_schedule() {
    local schedule=""
    local prompt=""
    local name=""
    local tools="$DEFAULT_TOOLS"
    local dir="$PWD"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--schedule) schedule="$2"; shift 2 ;;
            -n|--name)     name="$2"; shift 2 ;;
            -t|--tools)    tools="$2"; shift 2 ;;
            -d|--dir)      dir="$2"; shift 2 ;;
            -*)            echo "Unknown flag: $1" >&2; return 1 ;;
            *)             prompt="$1"; shift ;;
        esac
    done

    if [[ -z "$schedule" || -z "$prompt" ]]; then
        cat <<'USAGE'
Usage: claude-agent.sh schedule "prompt" -s "cron expression" [options]

Presets: hourly, daily, weekly, every5m, every30m

Examples:
  claude-agent.sh schedule "run tests" -s hourly
  claude-agent.sh schedule "check deps" -s "0 9 * * 1" -n weekly-deps
  claude-agent.sh schedule "monitor logs" -s every5m -t "Bash,Read"
USAGE
        return 1
    fi

    case "$schedule" in
        hourly)    schedule="0 * * * *" ;;
        daily)     schedule="0 9 * * *" ;;
        weekly)    schedule="0 9 * * 1" ;;
        every5m)   schedule="*/5 * * * *" ;;
        every30m)  schedule="*/30 * * * *" ;;
    esac

    local script_path
    script_path="$(realpath "$0")"
    local job_line="$schedule cd $dir && $script_path run $(printf '%q' "$prompt") -t $(printf '%q' "$tools") -q $CRON_TAG${name:+ $name}"

    (crontab -l 2>/dev/null; echo "$job_line") | crontab -
    echo "Scheduled: $job_line"
}

cmd_unschedule() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Current scheduled jobs:"
        crontab -l 2>/dev/null | grep -n "$CRON_TAG" || echo "  (none)"
        echo ""
        echo "Usage: $SCRIPT_NAME unschedule <name-or-line-number>"
        return 1
    fi

    if [[ "$name" =~ ^[0-9]+$ ]]; then
        local line_to_remove
        line_to_remove=$(crontab -l 2>/dev/null | grep "$CRON_TAG" | sed -n "${name}p")
        if [[ -n "$line_to_remove" ]]; then
            crontab -l 2>/dev/null | grep -vF "$line_to_remove" | crontab -
            echo "Removed: $line_to_remove"
        fi
    else
        crontab -l 2>/dev/null | grep -v "$CRON_TAG $name" | crontab -
        echo "Removed jobs matching: $name"
    fi
}

# ══════════════════════════════════════════════════════════════
#  LOGS & JOBS
# ══════════════════════════════════════════════════════════════

cmd_jobs() {
    echo "=== Telegram Bot ==="
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "  Running (PID $(cat "$PIDFILE"))"
    else
        echo "  Not running"
    fi

    echo ""
    echo "=== Scheduled (cron) ==="
    crontab -l 2>/dev/null | grep "$CRON_TAG" || echo "  (none)"

    echo ""
    echo "=== Background ==="
    local found=false
    if [[ -f "$LOG_DIR/bg-jobs.txt" ]]; then
        while IFS= read -r line; do
            local pid
            pid=$(echo "$line" | awk '{print $1}')
            if kill -0 "$pid" 2>/dev/null; then
                echo "  PID $pid — ${line#* * }"
                found=true
            fi
        done < "$LOG_DIR/bg-jobs.txt"
    fi
    [[ "$found" == false ]] && echo "  (none)"

    echo ""
    echo "=== Recent logs ==="
    ls -1t "$LOG_DIR"/*.json 2>/dev/null | head -5 | while read -r f; do
        local ts
        ts=$(basename "$f" .json)
        local result
        result=$(jq -r '.result // "no result"' "$f" 2>/dev/null | head -c 80)
        echo "  $ts: $result"
    done || echo "  (none)"
}

cmd_log() {
    local target="${1:-latest}"

    if [[ "$target" == "latest" ]]; then
        target=$(ls -1t "$LOG_DIR"/*.json 2>/dev/null | head -1)
        if [[ -z "$target" ]]; then
            echo "No logs found in $LOG_DIR"
            return 1
        fi
    elif [[ ! -f "$target" ]]; then
        target=$(ls -1t "$LOG_DIR"/*"$target"* 2>/dev/null | head -1)
    fi

    if [[ -f "$target" ]]; then
        echo "=== $target ==="
        jq -r '
            "Session: " + (.session_id // "unknown"),
            "Model:   " + (.model // "unknown"),
            "Tokens:  " + ((.usage.input_tokens // 0) | tostring) + " in / " + ((.usage.output_tokens // 0) | tostring) + " out",
            "",
            .result // "No result"
        ' "$target" 2>/dev/null || cat "$target"
    else
        echo "Log not found: $1" >&2
        return 1
    fi
}

cmd_clean() {
    local days="${1:-7}"
    local count
    count=$(find "$LOG_DIR" -name "*.json" -mtime +"$days" -type f 2>/dev/null | wc -l)
    find "$LOG_DIR" \( -name "*.json" -o -name "*.log" \) -mtime +"$days" -type f -delete 2>/dev/null
    echo "Cleaned $count logs older than $days days"
}

# ══════════════════════════════════════════════════════════════
#  NTFY LISTENER (two-way via ntfy.sh)
# ══════════════════════════════════════════════════════════════

cmd_ntfy_listen() {
    if [[ -z "$NTFY_TOPIC" ]]; then
        echo "Error: NTFY_TOPIC not set. Run '$SCRIPT_NAME setup' first." >&2
        return 1
    fi

    local inbox="${NTFY_TOPIC}-inbox"
    echo "Listening on ntfy.sh/$inbox for prompts..."
    echo "Send prompts from your phone: publish to '$inbox'"
    echo "Results will be pushed to '$NTFY_TOPIC'"
    echo ""

    # Subscribe with long polling
    curl -sf "https://ntfy.sh/$inbox/json" 2>/dev/null | while IFS= read -r line; do
        local msg
        msg=$(echo "$line" | jq -r '.message // empty' 2>/dev/null)
        [[ -z "$msg" ]] && continue

        echo "[$(date)] Received: $msg"

        local logfile="$LOG_DIR/ntfy-$(date +%Y%m%d-%H%M%S).json"
        local cmd=(claude -p --output-format json --allowedTools "$DEFAULT_TOOLS")
        [[ -n "$DEFAULT_MODEL" ]] && cmd+=(--model "$DEFAULT_MODEL")
        cmd+=("$msg")

        local result
        result=$(timeout 600 "${cmd[@]}" 2>&1) || true
        echo "$result" > "$logfile"

        local response
        response=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)
        [[ -z "$response" ]] && response="Error: $(echo "$result" | head -c 500)"

        # Push result back
        curl -sf \
            -H "Title: Claude Result" \
            -H "Priority: high" \
            -d "${response:0:4000}" \
            "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true

        echo "[$(date)] Response sent"
    done
}

# ══════════════════════════════════════════════════════════════
#  SETUP
# ══════════════════════════════════════════════════════════════

cmd_setup() {
    echo "=== Claude Agent Setup ==="
    echo ""
    echo "Your setup: SSH into server + tmux"
    echo "Notifications go to your phone, you chat from your phone."
    echo ""

    # Step 1: Notification method
    echo "How do you want to be notified?"
    echo "  1) ntfy.sh only (simplest — install ntfy app, pick a topic)"
    echo "  2) Telegram bot only (two-way chat from your phone)"
    echo "  3) Both ntfy + Telegram"
    echo "  4) None (just logs)"
    echo ""
    read -rp "Choice [3]: " choice
    choice="${choice:-3}"

    case "$choice" in
        1) NOTIFY_METHOD="ntfy" ;;
        2) NOTIFY_METHOD="telegram" ;;
        3) NOTIFY_METHOD="both" ;;
        4) NOTIFY_METHOD="none" ;;
    esac

    # Step 2: ntfy setup
    if [[ "$NOTIFY_METHOD" == "ntfy" || "$NOTIFY_METHOD" == "both" ]]; then
        echo ""
        echo "── ntfy.sh setup ──"
        echo "Pick a secret topic name (like a password — anyone who knows it can read your messages)"
        read -rp "Topic name: " NTFY_TOPIC
        echo ""
        echo "Install the ntfy app on your phone:"
        echo "  Android: https://play.google.com/store/apps/details?id=io.heckel.ntfy"
        echo "  iOS: https://apps.apple.com/app/ntfy/id1625396347"
        echo "Subscribe to topic: $NTFY_TOPIC"
        echo ""
        echo "For two-way ntfy: also subscribe to ${NTFY_TOPIC}-inbox"
        echo "  Send prompts there, results come back on $NTFY_TOPIC"
        echo "  Run: $SCRIPT_NAME ntfy-listen (in a tmux pane)"
    fi

    # Step 3: Telegram setup
    if [[ "$NOTIFY_METHOD" == "telegram" || "$NOTIFY_METHOD" == "both" ]]; then
        echo ""
        echo "── Telegram bot setup ──"
        echo "1. Open Telegram, search for @BotFather"
        echo "2. Send /newbot, pick a name and username"
        echo "3. Copy the token it gives you"
        echo ""
        read -rp "Bot token: " TG_BOT_TOKEN

        echo ""
        echo "Now send any message to your new bot, then press Enter..."
        read -r
        local updates
        updates=$(curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates" 2>/dev/null)
        TG_CHAT_ID=$(echo "$updates" | jq -r '.result[-1].message.chat.id // empty')

        if [[ -n "$TG_CHAT_ID" ]]; then
            echo "Detected your chat ID: $TG_CHAT_ID"
            ALLOWED_CHAT_IDS="$TG_CHAT_ID"
        else
            echo "Couldn't auto-detect. You can set TG_CHAT_ID manually later."
            read -rp "Chat ID (or leave empty): " TG_CHAT_ID
            ALLOWED_CHAT_IDS="$TG_CHAT_ID"
        fi
    fi

    # Step 4: Defaults
    echo ""
    echo "── Defaults ──"
    read -rp "Default model (opus/sonnet/haiku, or empty for default): " DEFAULT_MODEL
    read -rp "Default effort (low/medium/high/max, or empty): " DEFAULT_EFFORT
    read -rp "Extra system prompt for bot mode (or empty): " BOT_SYSTEM_PROMPT

    # Save config
    sed -i "s/^NOTIFY_METHOD=.*/NOTIFY_METHOD=\"$NOTIFY_METHOD\"/" "$0"
    sed -i "s/^NTFY_TOPIC=.*/NTFY_TOPIC=\"$NTFY_TOPIC\"/" "$0"
    sed -i "s/^TG_BOT_TOKEN=.*/TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"/" "$0"
    sed -i "s/^TG_CHAT_ID=.*/TG_CHAT_ID=\"$TG_CHAT_ID\"/" "$0"
    sed -i "s/^ALLOWED_CHAT_IDS=.*/ALLOWED_CHAT_IDS=\"$ALLOWED_CHAT_IDS\"/" "$0"
    sed -i "s/^DEFAULT_MODEL=.*/DEFAULT_MODEL=\"$DEFAULT_MODEL\"/" "$0"
    sed -i "s/^DEFAULT_EFFORT=.*/DEFAULT_EFFORT=\"$DEFAULT_EFFORT\"/" "$0"
    sed -i "s|^BOT_SYSTEM_PROMPT=.*|BOT_SYSTEM_PROMPT=\"$BOT_SYSTEM_PROMPT\"|" "$0"

    # Write Claude Code hooks
    local settings_file="$HOME/.claude/settings.json"
    mkdir -p "$(dirname "$settings_file")"

    local hook_cmd="$(realpath "$0") _notify_hook"
    if [[ -f "$settings_file" ]]; then
        local tmp
        tmp=$(mktemp)
        jq --arg cmd "$hook_cmd" '.hooks.Stop = [{"hooks": [{"type": "command", "command": $cmd}]}]' "$settings_file" > "$tmp"
        mv "$tmp" "$settings_file"
    else
        cat > "$settings_file" <<SETTINGS
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$hook_cmd"
          }
        ]
      }
    ]
  }
}
SETTINGS
    fi

    echo ""
    echo "=== Dependency check ==="
    for dep in claude curl jq; do
        if command -v "$dep" &>/dev/null; then
            echo "  [ok] $dep"
        else
            echo "  [!!] $dep NOT FOUND"
        fi
    done

    echo ""
    echo "=== Setup complete! ==="
    echo ""
    echo "Quick start:"
    [[ -n "$TG_BOT_TOKEN" ]] && echo "  $SCRIPT_NAME bot start     # start Telegram bot in background"
    [[ -n "$NTFY_TOPIC" ]]   && echo "  $SCRIPT_NAME ntfy-listen   # listen for ntfy prompts (run in tmux)"
    echo "  $SCRIPT_NAME run \"prompt\"  # run a one-off task"
    echo "  $SCRIPT_NAME bg \"prompt\"   # run in background"
    echo "  $SCRIPT_NAME schedule \"prompt\" -s daily  # schedule recurring"
}

# Hook entry point (called by Claude Code's Stop hook)
cmd__notify_hook() {
    notify "Claude Code" "Task completed"
}

# ══════════════════════════════════════════════════════════════
#  HELP
# ══════════════════════════════════════════════════════════════

cmd_help() {
    cat <<'HELP'
claude-agent.sh — Claude Code + Telegram/ntfy for server automation

TELEGRAM BOT (two-way chat):
  bot start               Start the Telegram bot (run in tmux)
  bot stop                Stop the bot
  bot status              Check if bot is running

PLAN MODE (review before execute):
  plan "task"             Create a plan, send to Telegram for review
  plan-approve <id>       Approve and execute a plan
  plan-revise <id> "fb"   Revise a plan with feedback
  plan-cancel <id>        Cancel a plan
  plan-list               List all plans and their status

  Via Telegram:
    /plan <task>          Create a plan
    go / approve          Execute the pending plan
    revise: <feedback>    Ask for changes
    cancel                Discard the plan
    /plans                List all plans

NTFY (two-way notifications):
  ntfy-listen             Listen for prompts via ntfy.sh (run in tmux)

TASKS:
  run "prompt" [opts]     Run headlessly, notify when done
  bg "prompt" [opts]      Run in background
  continue "prompt"       Continue last conversation
  resume <id> "prompt"    Resume specific session

SCHEDULING:
  schedule "prompt" -s <schedule>   Add cron job
  unschedule <name|num>             Remove cron job
  Presets: hourly, daily, weekly, every5m, every30m

MANAGEMENT:
  jobs                    List bot, cron, background, recent logs
  log [name|latest]       View a task log
  setup                   Interactive setup wizard
  clean [days]            Delete old logs (default 7 days)

RUN OPTIONS:
  -t, --tools "..."       Allowed tools (default: Bash,Read,Edit,Write,Glob,Grep)
  -m, --model opus        Model to use
  -e, --effort high       Thinking effort
  -n, --name "name"       Name the session
  -q, --quiet             Suppress output
  --max-turns 5           Limit turns
  --max-budget 2.00       Limit spend (USD)
  --yolo                  Skip all permission prompts
  --append-prompt "..."   Extra system instructions
  -c, --continue          Continue last session
  -r, --resume <id>       Resume specific session

EXAMPLES:
  # First time
  claude-agent.sh setup

  # Start Telegram bot (in tmux)
  claude-agent.sh bot start

  # === PLAN MODE (the good stuff) ===

  # From Telegram:
  #   You: /plan refactor the auth module to use JWT
  #   Bot: [sends detailed plan]
  #   You: revise: also add refresh token support
  #   Bot: [sends revised plan]
  #   You: go
  #   Bot: [executes, sends result]

  # From CLI:
  claude-agent.sh plan "refactor auth to use JWT"
  claude-agent.sh plan-approve plan-20260321-143022
  # or revise:
  claude-agent.sh plan-revise plan-20260321-143022 "add refresh tokens"

  # === DIRECT MODE ===

  # One-off task from SSH
  claude-agent.sh run "fix failing tests" -t "Bash,Read,Edit"

  # Background task
  claude-agent.sh bg "refactor auth" --max-turns 10

  # Schedule daily
  claude-agent.sh schedule "run tests" -s daily -n daily-tests

  # Check everything
  claude-agent.sh jobs
HELP
}

# ══════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════

case "${1:-help}" in
    run)              shift; cmd_run "$@" ;;
    bg)               shift; cmd_bg "$@" ;;
    continue)         shift; cmd_continue "$@" ;;
    resume)           shift; cmd_resume "$@" ;;
    plan)             shift; cmd_plan "$@" ;;
    plan-approve)     shift; cmd_plan_approve "$@" ;;
    plan-revise)      shift; cmd_plan_revise "$@" ;;
    plan-cancel)      shift; cmd_plan_cancel "$@" ;;
    plan-list)        shift; cmd_plan_list "$@" ;;
    schedule)         shift; cmd_schedule "$@" ;;
    unschedule)       shift; cmd_unschedule "$@" ;;
    jobs)             shift; cmd_jobs "$@" ;;
    log)              shift; cmd_log "$@" ;;
    setup)            shift; cmd_setup "$@" ;;
    clean)            shift; cmd_clean "$@" ;;
    bot)              shift; cmd_bot "$@" ;;
    ntfy-listen)      shift; cmd_ntfy_listen "$@" ;;
    _bot_loop)        shift; cmd__bot_loop "$@" ;;
    _notify_hook)     shift; cmd__notify_hook "$@" ;;
    _get_pending_plan) _get_pending_plan ;;
    help|--help|-h)   cmd_help ;;
    *)                echo "Unknown command: $1. Run '$SCRIPT_NAME help' for usage." >&2; exit 1 ;;
esac
