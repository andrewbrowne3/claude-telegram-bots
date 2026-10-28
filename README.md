# claude-telegram-bots

Four bash-based Telegram bots that wrap Claude Code (and OpenCode) so you can drive coding agents and personal APIs from your phone.

## The bots

| Script | What it does |
|---|---|
| `claude-agent.sh` | General-purpose Claude Code bot. Run shell commands, edit files, manage tmux sessions, plan/execute tasks. Supports notifications via Telegram and/or ntfy.sh. |
| `claude-calendar-bot.sh` | Calendar + finance assistant. Talks to a local Django API on `localhost:2011/api`, manages events, transactions, budgets, etc. Includes a background reminder loop that fires Telegram pings before scheduled events. |
| `opencode-agent.sh` | Mirror of `claude-agent.sh` but uses [OpenCode](https://github.com/sst/opencode) instead, so you can plug in any model provider (Ollama, OpenAI, etc.). |
| `ventii-server-bot.sh` | Ops/deploy/data/code bot for the Ventii production server. Runs Claude Code in `~/ventii_react_native`, holds risky actions (deploys, restarts, data writes, merges) with `APPROVAL NEEDED:` until approved, keeps code changes on `bot/*` branches, backs up the SQLite DB before deploys, and alerts on container/site/disk/nginx problems every 5 min. `/status` gives a quick health report. |

## Setup

1. Clone the repo and `cd` into it.
2. Copy `.env.example` to `.env` and fill in your tokens:
   ```bash
   cp .env.example .env
   $EDITOR .env
   ```
3. Make scripts executable:
   ```bash
   chmod +x *.sh
   ```
4. Install dependencies:
   - `claude` (Claude Code CLI) for `claude-agent.sh` and `claude-calendar-bot.sh`
   - `opencode` for `opencode-agent.sh`
   - `curl`, `jq` for all of them
5. Start a bot:
   ```bash
   ./claude-agent.sh start
   ./claude-calendar-bot.sh start
   ./opencode-agent.sh start
   ```

### Get a Telegram bot token
Talk to [@BotFather](https://t.me/BotFather) on Telegram, run `/newbot`, follow the prompts. Each script needs its own token (don't reuse across bots).

### Get your chat ID
Message [@userinfobot](https://t.me/userinfobot) on Telegram. Put the number in `TG_CHAT_ID` and `ALLOWED_CHAT_IDS` in `.env`.

## Running as a service (systemd user)

Each bot is designed to run under `systemctl --user`. Example unit at `~/.config/systemd/user/claude-agent.service`:

```ini
[Unit]
Description=Claude Code Telegram bot
After=network.target

[Service]
Type=simple
ExecStart=%h/claude-telegram-bots/claude-agent.sh start
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

Then:
```bash
systemctl --user daemon-reload
systemctl --user enable --now claude-agent
journalctl --user -u claude-agent -f
```

## Security notes

- `.env` is gitignored — **never commit it**.
- `ALLOWED_CHAT_IDS` is enforced per-message; unauthorized senders get a polite "Unauthorized." reply.
- All three scripts use `--dangerously-skip-permissions` (Claude Code) so the bot can act without human approval. Treat your bot token like a root password.
- The calendar bot's JWT in `CAL_API_TOKEN` grants full read/write to your calendar + finance data. Rotate it if it ever leaks.
