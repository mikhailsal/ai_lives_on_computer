# Debian Server Setup - Complete Guide

> **⚠️ DEPRECATED (March 2026):** The Qwen OAuth API approach described in this document **no longer works** for third-party tools. Qwen has restricted `portal.qwen.ai` to only accept requests from their official `qwen-cli` client. See [issue #1742](https://github.com/QwenLM/qwen-code/issues/1742). For future autonomous AI experiments, use **OpenRouter** with free models instead. The `qwen-cli` itself still works fine for interactive use.

## Overview
This server has been configured with:
- SSH key-based authentication (passwordless login)
- qwen-cli (Qwen Code CLI) with OAuth authentication
- live-SWE-agent (self-evolving SWE-bench agent) — **Qwen integration deprecated, use OpenRouter**
- Python virtual environments and necessary dependencies

---

## Server Details

| Property | Value |
|----------|-------|
| **IP Address** | 192.168.1.205 |
| **SSH Alias** | `debian` |
| **Username** | `user` |
| **Hostname** | `vmdebian` |

---

## Quick Start

### 1. Connect to Server
```bash
ssh debian
```

### 2. Use qwen-cli
```bash
# Interactive mode
qwen

# Non-interactive with prompt
qwen -p "Write a Python function to calculate factorial"

# JSON output
qwen -p "Hello" --output-format json
```

### 3. Use live-SWE-agent (IMPORTANT: use the config!)
```bash
cd ~/live-swe-agent
source venv/bin/activate
mini --config config/livesweagent.yaml --model openai/coder-model --task "your task here" --yolo
```

**Note:** The `--config config/livesweagent.yaml` flag is REQUIRED to enable live-swe-agent's self-evolving capabilities!

---

## Understanding live-swe-agent vs mini-swe-agent

| Component | Description |
|-----------|-------------|
| **mini-swe-agent** | The core framework/engine (pip package, command: `mini`) |
| **live-swe-agent** | A special configuration that enables self-evolving capabilities |

**Key insight:** `live-swe-agent` IS `mini-swe-agent` + the `livesweagent.yaml` config file!

### What makes live-swe-agent special?
The `livesweagent.yaml` config adds:
1. **Self-tool-creation** - Agent can create custom Python tools on the fly
2. **Reflection prompts** - Agent reflects on trajectories to improve
3. **Self-modification** - Agent can extend its own capabilities at runtime

### Correct usage:
```bash
# live-swe-agent (with self-evolving features)
mini --config config/livesweagent.yaml --task "..." --yolo

# plain mini-swe-agent (without self-evolution)
mini --task "..." --yolo
```

---

## Configuration Details

### SSH Setup
**Local SSH config** (`~/.ssh/config` on your local machine):
```
Host debian
    HostName 192.168.1.205
    User user
```

**Server features**:
- Passwordless SSH (key-based auth)
- Passwordless sudo configured

### qwen-cli Configuration
**Config location**: `~/.qwen/`
- `oauth_creds.json` - OAuth credentials (access token)
- `settings.json` - Auth type configuration

**Auth type**: `qwen-oauth` (FREE tier)

### live-SWE-agent Configuration
**Config location**: `~/.config/mini-swe-agent/.env`

```bash
OPENAI_API_KEY=<access_token from oauth_creds.json>
OPENAI_BASE_URL=https://portal.qwen.ai/v1
MSWEA_MODEL_NAME=openai/coder-model
MSWEA_CONFIGURED=true
MSWEA_COST_TRACKING=ignore_errors
```

**Agent config**: `~/live-swe-agent/config/livesweagent.yaml`

---

## API Details (Qwen OAuth - OpenAI Compatible)

| Setting | Value |
|---------|-------|
| **Protocol** | OpenAI-compatible |
| **Base URL** | `https://portal.qwen.ai/v1` |
| **Auth** | Bearer token from `~/.qwen/oauth_creds.json` |
| **Models** | `coder-model` (recommended, maps to qwen3.5-plus), `qwen3-coder-plus` (older) |
|| **Limits** | Per-model daily quotas (vary by model, see QWEN-TOKEN-DEBUG-GUIDE.md) |
|| **Cost** | FREE (OAuth tier) |

### Test API directly:
```bash
ACCESS_TOKEN=$(cat ~/.qwen/oauth_creds.json | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -X POST "https://portal.qwen.ai/v1/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model": "coder-model", "messages": [{"role": "user", "content": "Hello"}]}'
```

---

## Usage Examples

### qwen-cli Examples
```bash
# Simple question
qwen -p "What is Python?"

# Code generation
qwen -p "Write a function to sort a list"

# Interactive mode (full agent)
qwen
```

### live-SWE-agent Examples
```bash
cd ~/live-swe-agent
source venv/bin/activate

# Create a file
mini --config config/livesweagent.yaml --model openai/coder-model \
  --task "Create a hello.py that prints Hello World" --yolo

# Fix a bug (in a repo)
mini --config config/livesweagent.yaml --model openai/coder-model \
  --task "Fix the bug in main.py where division by zero occurs" --yolo

# Run with step limit
mini --config config/livesweagent.yaml --model openai/coder-model \
  --task "Refactor the code" --yolo --step-limit 10
```

### Useful Flags
| Flag | Description |
|------|-------------|
| `--config` | Path to config file (use `config/livesweagent.yaml` for live-swe-agent) |
| `--model` | Model name (e.g., `openai/qwen3-coder-plus`) |
| `--task` | Task description |
| `--yolo` | Auto-confirm actions (non-interactive) |
| `--exit-immediately` | Exit after completion |
| `--step-limit N` | Limit number of steps |

---

## Token Management

### Important: qwen-cli Auto-Refreshes Tokens WITHOUT Browser

**Key discovery (verified January 2026):** The `qwen-cli` tool can refresh OAuth tokens automatically on a headless server WITHOUT needing a browser! Simply running `qwen` with any request (e.g., `echo "test" | qwen`) will trigger an automatic token refresh if the token is close to expiring.

This means:
- You do NOT need to re-authenticate via browser when tokens expire
- Just run any qwen-cli command and it will auto-refresh
- The updated token is saved to `~/.qwen/oauth_creds.json`

### Sync Token to live-SWE-agent
The qwen-cli token auto-refreshes, but live-SWE-agent needs manual sync. Use the sync script:

```bash
# From local machine (via SSH)
ssh debian "~/sync-qwen-token.sh"

# Or directly on the server
~/sync-qwen-token.sh

# Force token validity test even if token unchanged
~/sync-qwen-token.sh --force
```

The script will:
1. Extract the current token from `~/.qwen/oauth_creds.json`
2. Update `~/.config/mini-swe-agent/.env`
3. **Verify the token works by testing the API**
4. **If token is expired, automatically call `qwen-cli` to refresh it**
5. **Re-sync the refreshed token to live-SWE-agent config**

**Key Features:**
- **Auto-refresh**: If the token is expired, the script calls `qwen-cli` (with a minimal "hi" prompt) to trigger OAuth token refresh
- **Validation**: Always tests token validity after sync
- **Force test**: Use `--force` to skip early exit and always validate token

**Run this script whenever you get authentication errors with live-SWE-agent!**

---

## Troubleshooting

### OAuth Token Expired / Authentication Errors
**Quick fix:** Run the sync script (it will auto-refresh if needed):
```bash
ssh debian "~/sync-qwen-token.sh"
```

**Note:** The sync script now automatically detects expired tokens and refreshes them via `qwen-cli` (no browser needed). The script will call `qwen-cli` with a minimal prompt to trigger OAuth refresh, then update live-SWE-agent.

If for some reason the auto-refresh doesn't work:
1. Run `qwen` on a machine with a browser
2. Complete OAuth flow
3. Copy `~/.qwen/oauth_creds.json` to the server
4. Run `~/sync-qwen-token.sh` to update live-SWE-agent

### Check Token Validity
```bash
ACCESS_TOKEN=$(cat ~/.qwen/oauth_creds.json | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -s -X POST "https://portal.qwen.ai/v1/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model": "coder-model", "messages": [{"role": "user", "content": "hi"}], "max_tokens": 5}'
```

### live-SWE-agent Not Using Correct Config
Make sure you're in the right directory and using the config flag:
```bash
cd ~/live-swe-agent
source venv/bin/activate
mini --config config/livesweagent.yaml ...
```

### View Current Configuration
```bash
cat ~/.config/mini-swe-agent/.env
```

---

## File Locations Summary

| File | Purpose |
|------|---------|
| `~/.qwen/oauth_creds.json` | OAuth access token |
| `~/.qwen/settings.json` | qwen-cli auth settings |
| `~/.config/mini-swe-agent/.env` | live-SWE-agent config |
| `~/live-swe-agent/` | live-SWE-agent repository |
| `~/live-swe-agent/config/livesweagent.yaml` | Agent behavior config |
| `~/live-swe-agent/venv/` | Python virtual environment |
| `~/sync-qwen-token.sh` | **Token sync script** (auto-refreshes expired tokens, use `--force` to test validity) |

---

## Version Info
- **qwen-cli**: v0.11.0
- **mini-swe-agent**: v1.17.1
- **Node.js**: v22.16.0
- **Python**: 3.10.12

---

## How We Made Qwen OAuth Work with live-SWE-agent

### The Discovery
We found that `qwen-cli` uses an **OpenAI-compatible protocol** to talk to `portal.qwen.ai`. This was discovered by:
1. Analyzing RooCode/KiloCode source code (they also use qwen OAuth)
2. Finding the endpoint: `https://portal.qwen.ai/v1/chat/completions`
3. Testing with the access token from `oauth_creds.json`

### The Solution
Instead of using a separate Dashscope API key (which has limited free tokens), we configured `live-SWE-agent` (via `litellm`) to use the same OAuth token that `qwen-cli` uses:

```bash
OPENAI_API_KEY=<access_token from oauth_creds.json>
OPENAI_BASE_URL=https://portal.qwen.ai/v1
MSWEA_MODEL_NAME=openai/coder-model
```

This gives us **FREE access** via Qwen OAuth tier. See `QWEN-TOKEN-DEBUG-GUIDE.md` for detailed model names, quotas, and troubleshooting.

---

*Last updated: March 2026*
