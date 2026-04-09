#!/bin/bash
# opencode-agent.sh — OpenCode Telegram bot (mirrors claude-agent.sh)
# Swaps Claude Code for OpenCode so you can use any model provider
# Dependencies: opencode, curl, jq

set -euo pipefail

LOG_DIR="$HOME/claude-logs/opencode"
PIDFILE="$HOME/.opencode-telegram-bot.pid"

# ── Load secrets from .env (gitignored) ──────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

# ── Config ───────────────────────────────────────────────────
# Use a DIFFERENT bot token than your Claude bot (create a second bot via @BotFather)
TG_BOT_TOKEN="${OC_TG_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
ALLOWED_CHAT_IDS="${ALLOWED_CHAT_IDS:-}"

# OpenCode settings
OPENCODE_BIN="$HOME/.opencode/bin/opencode"
OPENCODE_MODEL="ollama/llama3.2:latest"
OPENCODE_DIR="$HOME" # working directory for opencode

mkdir -p "$LOG_DIR"

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

# ── Bot loop ─────────────────────────────────────────────────

cmd_start() {
	if [[ -z "$TG_BOT_TOKEN" ]]; then
		echo "Error: TG_BOT_TOKEN not set. Edit this script first." >&2
		return 1
	fi

	if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
		echo "Bot already running (PID $(cat "$PIDFILE"))"
		return 0
	fi

	echo "Starting OpenCode Telegram bot..."
	nohup "$0" _loop >"$LOG_DIR/bot.log" 2>&1 &
	local pid=$!
	echo "$pid" >"$PIDFILE"
	echo "Bot started (PID $pid)"
	echo "Log: $LOG_DIR/bot.log"
	_tg_send "$TG_CHAT_ID" "OpenCode bot is online. Send me a message!"
}

cmd_stop() {
	if [[ -f "$PIDFILE" ]]; then
		local pid
		pid=$(cat "$PIDFILE")
		if kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null
			pkill -P "$pid" 2>/dev/null || true
			echo "Bot stopped (PID $pid)"
		else
			echo "Bot was not running"
		fi
		rm -f "$PIDFILE"
	else
		echo "Bot is not running"
	fi
}

cmd_status() {
	if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
		echo "Bot is running (PID $(cat "$PIDFILE"))"
		tail -5 "$LOG_DIR/bot.log" 2>/dev/null || true
	else
		echo "Bot is not running"
	fi
}

cmd__loop() {
	set +u # Relax unbound variable check inside loop
	local offset=0

	# Skip old messages
	local init
	init=$(curl -sf "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=-1" 2>/dev/null || echo '{}')
	offset=$(echo "$init" | jq -r '.result[-1].update_id // 0')
	[[ "$offset" != "0" ]] && offset=$((offset + 1))

	echo "[$(date)] OpenCode bot started. Offset: $offset"

	while true; do
		local updates
		updates=$(curl -sf --max-time 35 \
			"https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=${offset}&timeout=30" \
			2>/dev/null) || {
			sleep 2
			continue
		}

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
			/start | /help)
				_tg_send "$chat_id" "OpenCode Bot (open-source AI coding agent)

Send me any message and I'll run it through OpenCode.

Commands:
/new — fresh conversation
/model — show current model
/status — check status
/help — this message"
				continue
				;;
			/new)
				rm -f "$LOG_DIR/session-${chat_id}.id"
				_tg_send "$chat_id" "Fresh conversation started."
				continue
				;;
			/model)
				_tg_send "$chat_id" "Model: ${OPENCODE_MODEL:-default}"
				continue
				;;
			/status)
				local uptime_info
				uptime_info=$(uptime 2>/dev/null || echo "unknown")
				_tg_send "$chat_id" "OpenCode Bot
Server: $(hostname)
Uptime: $uptime_info
PID: $$
Model: ${OPENCODE_MODEL:-default}"
				continue
				;;
			esac

			# Run through OpenCode
			_tg_send "$chat_id" "Working on it..."

			local logfile="$LOG_DIR/oc-$(date +%Y%m%d-%H%M%S).json"
			local session_file="$LOG_DIR/session-${chat_id}.id"

			# Build command
			local cmd=("$OPENCODE_BIN" run --format json --dir "$OPENCODE_DIR")
			[[ -n "$OPENCODE_MODEL" ]] && cmd+=(--model "$OPENCODE_MODEL")

			# Resume session if exists
			if [[ -f "$session_file" ]]; then
				local prev_session
				prev_session=$(cat "$session_file")
				[[ -n "$prev_session" ]] && cmd+=(--session "$prev_session")
			fi

			echo "[$(date)] Running OpenCode..."
			local result exit_code=0
			result=$(timeout 600 "${cmd[@]}" "$text" 2>&1) || exit_code=$?
			echo "$result" >"$logfile"
			echo "[$(date)] Exit: $exit_code"

			# Try to extract session ID from JSON output
			local new_session
			new_session=$(echo "$result" | jq -r '.session_id // .sessionId // empty' 2>/dev/null)
			[[ -n "$new_session" ]] && echo "$new_session" >"$session_file"

			if [[ $exit_code -eq 0 ]]; then
				local response
				# OpenCode JSON output format — try common fields
				response=$(echo "$result" | jq -r '.result // .message // .content // .output // empty' 2>/dev/null)
				# If JSON parsing fails, use the last chunk of raw output
				if [[ -z "$response" ]]; then
					response=$(echo "$result" | grep -v '^{' | tail -50 | head -c 3500)
				fi
				[[ -z "$response" ]] && response="Done (no text output)"
				_tg_send "$chat_id" "$response"
			elif [[ $exit_code -eq 124 ]]; then
				_tg_send "$chat_id" "Task timed out after 10 minutes."
			else
				# Retry without session
				echo "[$(date)] Retrying fresh..."
				rm -f "$session_file"
				local cmd2=("$OPENCODE_BIN" run --format json --dir "$OPENCODE_DIR")
				[[ -n "$OPENCODE_MODEL" ]] && cmd2+=(--model "$OPENCODE_MODEL")

				result=$(timeout 600 "${cmd2[@]}" "$text" 2>&1) || exit_code=$?
				echo "$result" >"$logfile"

				new_session=$(echo "$result" | jq -r '.session_id // .sessionId // empty' 2>/dev/null)
				[[ -n "$new_session" ]] && echo "$new_session" >"$session_file"

				local response
				response=$(echo "$result" | jq -r '.result // .message // .content // .output // empty' 2>/dev/null)
				[[ -z "$response" ]] && response=$(echo "$result" | grep -v '^{' | tail -50 | head -c 3500)
				[[ -z "$response" ]] && response="Error (exit $exit_code)"
				_tg_send "$chat_id" "$response"
			fi

			echo "[$(date)] Done"
		done
	done
}

# ── Entry point ──────────────────────────────────────────────

case "${1:-help}" in
start) cmd_start ;;
stop) cmd_stop ;;
status) cmd_status ;;
_loop) cmd__loop ;;
help | --help | -h)
	echo "opencode-agent.sh — OpenCode Telegram bot"
	echo ""
	echo "  start   Start the bot"
	echo "  stop    Stop the bot"
	echo "  status  Check bot status"
	echo ""
	echo "Setup:"
	echo "  1. Create a new bot via @BotFather on Telegram"
	echo "  2. Set TG_BOT_TOKEN in this script"
	echo "  3. Run: opencode providers  (to configure a model provider)"
	echo "  4. Run: ./opencode-agent.sh start"
	echo ""
	echo "As systemd service:"
	echo "  systemctl --user start opencode-bot"
	echo "  systemctl --user status opencode-bot"
	echo "  journalctl --user -u opencode-bot -f"
	;;
*)
	echo "Unknown: $1" >&2
	exit 1
	;;
esac
