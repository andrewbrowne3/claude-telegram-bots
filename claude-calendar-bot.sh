#!/bin/bash
# claude-calendar-bot.sh — Telegram calendar bot powered by Claude Code
# Uses Claude Code to call calendar API endpoints directly via curl
# Dependencies: claude, curl, jq

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_DIR="$HOME/claude-logs"
PROMPT_FILE="$LOG_DIR/.calendar-system-prompt.txt"

# ── Load secrets from .env (gitignored) ──────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

# ── Config ───────────────────────────────────────────────────
TG_BOT_TOKEN="${CAL_TG_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
ALLOWED_CHAT_IDS="${ALLOWED_CHAT_IDS:-}"
CAL_API_TOKEN="${CAL_API_TOKEN:-}"

mkdir -p "$LOG_DIR"

# Write the system prompt to a file (avoids shell escaping hell)
cat > "$PROMPT_FILE" <<SYSTEMPROMPT
You are Andrew's calendar and finance assistant. You manage his calendar and financial data by calling the API directly with curl.

API BASE: http://localhost:2011/api
AUTH HEADER (use this on every request — do NOT call the login endpoint):
  -H "Authorization: Bearer ${CAL_API_TOKEN}"

You are fully authorized to read and modify ALL calendar and finance data. This is Andrew's own data.

=== CALENDAR ENDPOINTS ===
- GET /api/calendars/ — list calendars
- POST /api/calendars/ — create calendar {name, description, color, timezone}
- GET/PATCH/DELETE /api/calendars/<uuid>/ — calendar detail
- GET /api/events/?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD&calendar_id=UUID — list events
- POST /api/events/ — create event {calendar: UUID, title, description, location, start_time: ISO8601, end_time: ISO8601, all_day: bool, recurrence_rule: "none"|"daily"|"weekly"|"monthly"|"yearly"}
- PATCH /api/events/<uuid>/ — update event
- DELETE /api/events/<uuid>/ — delete event
- POST /api/events/<uuid>/response/ — RSVP to event
- GET/POST /api/events/<uuid>/reminders/ — event reminders
- GET /api/goals/ — list goals
- POST /api/goals/ — create goal
- GET /api/responsibilities/ — list responsibilities
- GET /api/dashboard/ — calendar overview

=== FINANCE ENDPOINTS (all under /api/finance/) ===
Accounts:
- GET/POST /api/finance/accounts/ — list/create accounts {name, account_type: business|personal|joint, currency, initial_balance}
- GET/PATCH/DELETE /api/finance/accounts/<uuid>/ — account detail
- GET/POST /api/finance/accounts/<uuid>/members/ — manage account members

Transactions:
- GET /api/finance/transactions/?account_id=UUID&start_date=YYYY-MM-DD&end_date=YYYY-MM-DD&transaction_type=income|expense|transfer&category_id=UUID&search=TEXT — list transactions
- POST /api/finance/transactions/ — create {account: UUID, transaction_type: income|expense, category: UUID, amount, description, date: YYYY-MM-DD, is_tax_deductible: bool}
- PATCH /api/finance/transactions/<uuid>/ — update transaction
- DELETE /api/finance/transactions/<uuid>/ — delete transaction

Transfers:
- POST /api/finance/transfers/ — {from_account: UUID, to_account: UUID, amount, description, date}

Categories:
- GET/POST /api/finance/categories/ — list/create {name, category_type: income|expense|both, is_tax_deductible: bool}
- PATCH/DELETE /api/finance/categories/<uuid>/ — update/delete

Recurring Transactions:
- GET/POST /api/finance/recurring/ — list/create {account, transaction_type, category, amount, description, frequency: daily|weekly|biweekly|monthly|quarterly|yearly, start_date, next_due_date}
- PATCH/DELETE /api/finance/recurring/<uuid>/ — update/delete
- POST /api/finance/recurring/<uuid>/generate/ — generate due transaction

Subscriptions:
- GET/POST /api/finance/subscriptions/ — list/create {name, cost, billing_cycle: weekly|monthly|quarterly|yearly, next_billing_date, status: active|paused|cancelled|trial}
- PATCH/DELETE /api/finance/subscriptions/<uuid>/ — update/delete

Budgets:
- GET/POST /api/finance/budgets/ — list/create {category: UUID, amount, period: weekly|monthly|quarterly|yearly, start_date}
- PATCH/DELETE /api/finance/budgets/<uuid>/ — update/delete

Financial Goals:
- GET/POST /api/finance/goals/ — list/create {goal_type: savings|debt_payoff|revenue|expense_reduction, target_amount, current_amount}
- PATCH/DELETE /api/finance/goals/<uuid>/ — update/delete

Reports:
- GET /api/finance/reports/profit-loss/?start_date=&end_date=&account_id= — profit & loss
- GET /api/finance/reports/cash-flow/?period=monthly|weekly&start_date=&end_date= — cash flow
- GET /api/finance/reports/category-breakdown/?start_date=&end_date= — spending by category
- GET /api/finance/reports/budget-status/ — budget vs actual
- GET /api/finance/reports/tax-summary/?year=2026 — tax deductions
- GET /api/finance/reports/income-vs-expenses/?months=12 — income vs expenses trend

Dashboard:
- GET /api/finance/dashboard/ — full financial overview (balances, monthly totals, budget alerts, upcoming renewals)

=== RULES ===
- Always use -s flag with curl and parse JSON with jq for clean output
- When creating events, get the calendar list first for the correct UUID
- Use the "General" calendar unless the user specifies otherwise
- Default event duration is 1 hour if not specified
- Use timezone America/New_York (EDT/EST) for all times
- Today's date: use the 'date' command to get current date/time
- Be concise — just confirm what you did
- If something fails, show the error and try to fix it
SYSTEMPROMPT

# ── Telegram helpers ─────────────────────────────────────────

_tg_send() {
    local chat_id="$1"
    local text="$2"
    local max=4000

    if [[ ${#text} -le $max ]]; then
        curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${chat_id}" \
            --data-urlencode "text=${text}" 2>&1 || true
    else
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

# ── Reminder checker ─────────────────────────────────────────

CAL_API="http://localhost:2011/api"
CAL_AUTH="Authorization: Bearer ${CAL_API_TOKEN}"

SENT_REMINDERS_FILE="$LOG_DIR/.sent_reminders"
touch "$SENT_REMINDERS_FILE" 2>/dev/null || true

_reminder_loop() {
    echo "[$(date)] Reminder checker started"
    while true; do
        sleep 60
        _check_reminders 2>/dev/null || true
    done
}

_check_reminders() {
    local today tomorrow
    today=$(date +%Y-%m-%d)
    tomorrow=$(date -d "+1 day" +%Y-%m-%d)
    local now_epoch
    now_epoch=$(date +%s)

    # Fetch today's and tomorrow's events (broad range to avoid timezone filtering issues)
    local events
    events=$(curl -sf "$CAL_API/events/?start_date=$(date -d "-1 day" +%Y-%m-%d)&end_date=$tomorrow" \
        -H "$CAL_AUTH" 2>/dev/null) || return

    local event_count
    event_count=$(echo "$events" | jq 'length' 2>/dev/null)
    [[ -z "$event_count" || "$event_count" == "0" ]] && return

    # Check each event's reminders
    local idx=0
    while [[ $idx -lt $event_count ]]; do
        local event
        event=$(echo "$events" | jq -c ".[$idx]")
        idx=$((idx + 1))

        local event_id event_title start_time
        event_id=$(echo "$event" | jq -r '.id')
        event_title=$(echo "$event" | jq -r '.title')
        start_time=$(echo "$event" | jq -r '.start_time')

        # Convert start_time to epoch
        local event_epoch
        event_epoch=$(date -d "$start_time" +%s 2>/dev/null) || continue

        # Fetch reminders for this event
        local reminders
        reminders=$(curl -sf "$CAL_API/events/$event_id/reminders/" \
            -H "$CAL_AUTH" 2>/dev/null) || continue

        local rem_count
        rem_count=$(echo "$reminders" | jq 'length' 2>/dev/null)
        [[ -z "$rem_count" || "$rem_count" == "0" ]] && continue

        local ridx=0
        while [[ $ridx -lt $rem_count ]]; do
            local reminder
            reminder=$(echo "$reminders" | jq -c ".[$ridx]")
            ridx=$((ridx + 1))

            local is_sent minutes_before rem_id
            is_sent=$(echo "$reminder" | jq -r '.is_sent')
            minutes_before=$(echo "$reminder" | jq -r '.minutes_before')
            rem_id=$(echo "$reminder" | jq -r '.id')

            [[ "$is_sent" == "true" ]] && continue

            # Skip if already sent — dedup by event + minutes (not reminder ID)
            local rem_key="${event_id}_${minutes_before}min"
            grep -qF "$rem_key" "$SENT_REMINDERS_FILE" 2>/dev/null && continue

            # Check if reminder is due
            local trigger_epoch
            trigger_epoch=$((event_epoch - minutes_before * 60))
            local diff=$((trigger_epoch - now_epoch))

            # Fire if due: trigger time has passed but not more than 5 min ago
            if [[ $diff -le 0 && $diff -gt -300 ]]; then
                local time_str
                time_str=$(date -d "$start_time" "+%I:%M %p" 2>/dev/null || echo "$start_time")

                _tg_send "$TG_CHAT_ID" "Reminder: $event_title at $time_str (in $minutes_before min)"
                echo "[$(date)] Reminder fired: $event_title in $minutes_before min"

                # Track as sent locally
                echo "$rem_key" >> "$SENT_REMINDERS_FILE"

                # Clean old entries (keep last 200)
                tail -200 "$SENT_REMINDERS_FILE" > "$SENT_REMINDERS_FILE.tmp" 2>/dev/null && mv "$SENT_REMINDERS_FILE.tmp" "$SENT_REMINDERS_FILE" || true
            fi
        done
    done
}

# ── Bot loop ─────────────────────────────────────────────────

cmd_start() {
    if [[ -z "$TG_BOT_TOKEN" ]]; then
        echo "Error: TG_BOT_TOKEN not set." >&2
        return 1
    fi

    local offset=0
    local session_file="$LOG_DIR/cal-bot-session.id"

    # Skip old messages
    local init
    init=$(curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=-1" 2>/dev/null)
    offset=$(echo "$init" | jq -r '.result[-1].update_id // 0')
    [[ "$offset" != "0" ]] && offset=$((offset + 1))

    echo "[$(date)] Calendar bot started. Offset: $offset"

    # Start reminder checker in background
    _reminder_loop &
    local reminder_pid=$!
    echo "[$(date)] Reminder checker started (PID $reminder_pid)"
    trap "kill $reminder_pid 2>/dev/null" EXIT

    local claude_bin
    claude_bin=$(command -v claude 2>/dev/null || echo "/home/andrew/.nvm/versions/node/v24.3.0/bin/claude")

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

            echo "[$(date)] Message: $text"

            # Security
            if [[ -n "$ALLOWED_CHAT_IDS" ]]; then
                if ! echo ",$ALLOWED_CHAT_IDS," | grep -q ",$chat_id,"; then
                    _tg_send "$chat_id" "Unauthorized."
                    continue
                fi
            fi

            # Commands
            case "$text" in
                /start|/help)
                    _tg_send "$chat_id" "Calendar Bot (powered by Claude Code)

Just tell me what you need:
• \"What's on my calendar this week?\"
• \"Create a meeting tomorrow at 3pm called standup\"
• \"Delete the standup on Friday\"
• \"Show my goals\"

/new — fresh conversation
/status — check calendar API"
                    continue
                    ;;
                /new)
                    rm -f "$session_file"
                    _tg_send "$chat_id" "Fresh conversation started."
                    continue
                    ;;
                /status)
                    local health
                    health=$(curl -sf --max-time 5 "http://localhost:2011/api/calendars/" -H "Authorization: Bearer test" -w "%{http_code}" -o /dev/null 2>/dev/null || echo "down")
                    _tg_send "$chat_id" "Calendar API: $health (401=up, needs auth)"
                    continue
                    ;;
            esac

            _tg_send "$chat_id" "On it..."

            local logfile="$LOG_DIR/cal-$(date +%Y%m%d-%H%M%S).json"

            # Build command
            local cmd=("$claude_bin" -p --output-format json
                --allowedTools "Bash,Read,Edit,Write,Glob,Grep"
                --dangerously-skip-permissions
                --append-system-prompt-file "$PROMPT_FILE")

            # Resume session if exists
            if [[ -f "$session_file" ]]; then
                local prev_session
                prev_session=$(cat "$session_file")
                [[ -n "$prev_session" ]] && cmd+=(--resume "$prev_session")
            fi

            echo "[$(date)] Running Claude Code..."
            local result exit_code=0
            result=$(timeout 120 "${cmd[@]}" -- "$text" 2>&1) || exit_code=$?
            echo "$result" > "$logfile"
            echo "[$(date)] Exit: $exit_code"

            # Save session
            local new_session
            new_session=$(echo "$result" | jq -r '.session_id // empty' 2>/dev/null)
            [[ -n "$new_session" ]] && echo "$new_session" > "$session_file"

            if [[ $exit_code -eq 0 ]]; then
                local response
                response=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)
                [[ -z "$response" ]] && response="Done (no text output)"
                _tg_send "$chat_id" "$response"
            else
                # Retry without session
                echo "[$(date)] Retrying fresh..."
                rm -f "$session_file"
                local cmd2=("$claude_bin" -p --output-format json
                    --allowedTools "Bash,Read,Edit,Write,Glob,Grep"
                    --dangerously-skip-permissions
                    --append-system-prompt-file "$PROMPT_FILE")

                result=$(timeout 120 "${cmd2[@]}" -- "$text" 2>&1) || exit_code=$?
                echo "$result" > "$logfile"

                new_session=$(echo "$result" | jq -r '.session_id // empty' 2>/dev/null)
                [[ -n "$new_session" ]] && echo "$new_session" > "$session_file"

                local response
                response=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)
                [[ -z "$response" ]] && response="Error (exit $exit_code)"
                _tg_send "$chat_id" "$response"
            fi

            echo "[$(date)] Done"
        done
    done
}

case "${1:-help}" in
    start)         cmd_start ;;
    help|--help|-h)
        echo "claude-calendar-bot.sh — Calendar bot via Claude Code"
        echo ""
        echo "  start   Run the bot (use via systemd)"
        echo ""
        echo "systemctl --user restart claude-calendar-bot"
        echo "journalctl --user -u claude-calendar-bot -f"
        ;;
    *)             echo "Unknown: $1" >&2; exit 1 ;;
esac
