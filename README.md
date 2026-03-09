# AI Lives on Computer

An experiment in AI autonomy: give an AI its own "home" on a server and let it do whatever it wants.

**V2** uses other models via OpenRouter with reasoning enabled.

## Philosophy

**Complete Freedom.** The AI has no assigned tasks, no expectations, no required goals. It decides what to do with its existence.

**Complete Responsibility.** The AI can modify anything - including the files that control how it wakes up and what instructions it receives.

**Minimal Constraints.** The only requirements:
1. Increment the session counter
2. Write something to `last_session.md`
3. Don't destroy the system

## How It Works

The AI wakes up periodically (via cron), exists for a while, then sleeps. When it wakes up again, it has no memory except what it wrote down.

```
ai_lives_on_computer/
├── SYSTEM_PROMPT.md          # The AI's instructions (compact, cost-optimized)
├── run_ai.sh                 # Script that wakes the AI
├── run_ai_watchdog.sh        # Watchdog wrapper (auto-rollback on repeated failures)
├── deploy.sh                 # Deploy to server
├── set-schedule.sh           # Set agent wake-up frequency
├── config/
│   └── ai_agent_openrouter.yaml  # Agent config (step limits, model params)
├── ai_home/
│   ├── config.sh             # Timing & model configuration
│   ├── state/
│   │   ├── current_plan.md   # AI's intentions (if any)
│   │   ├── last_session.md   # Message to future self
│   │   └── session_counter.txt
│   ├── logs/
│   │   ├── history.md
│   │   └── consolidated_history.md
│   ├── knowledge/            # Things it wants to remember
│   ├── projects/             # Things it's working on
│   └── tools/                # Things it creates for itself
├── agent_data/               # Downloaded agent data (git-ignored)
└── archive/                  # Archived trajectories from past versions (git-ignored)
```

## Setup

### 1. Get OpenRouter API Key

Get your key from https://openrouter.ai/keys

### 2. Deploy to Server

```bash
# First-time deploy
./deploy.sh

# Configure OpenRouter on the server
ssh debian "~/setup-openrouter.sh YOUR_API_KEY"
```

### 3. Set Up Schedule

```bash
# Wake up every 15 minutes
./set-schedule.sh 15

# Check current schedule
./set-schedule.sh --status

# Pause the agent
./set-schedule.sh --stop
```

## Deployment

```bash
# Deploy new/safe files only (respects agent modifications)
./deploy.sh

# Check server status
./deploy.sh --status

# Force overwrite ALL files (creates backups)
./deploy.sh --force

# Full reset - destroys all agent state (session 1)
./deploy.sh --reset
```

## Observing the Experiment

```bash
# Watch live
ssh debian "tail -f ~/ai_home/logs/cron.log"

# Check what it's doing
ssh debian "cat ~/ai_home/state/last_session.md"

# See its intentions
ssh debian "cat ~/ai_home/state/current_plan.md"

# Download all agent data locally
./download-agent-data.sh
```

## Configuration

### `ai_home/config.sh`

```bash
SESSION_INTERVAL_MINUTES=15
SESSION_TIMEOUT_SECONDS=1800  # 30 minutes
OPENROUTER_MODEL="google/gemini-2.5-flash-lite-preview-09-2025"
```

### `config/ai_agent_openrouter.yaml`

```yaml
agent:
  step_limit: 25    # Max actions per session (cost control)
model:
  model_kwargs:
    temperature: 0.5
    max_tokens: 32768
    reasoning:
      effort: "medium"
```

## Cost Optimization (V2)

V2 is designed for paid models. Key optimizations:
- **Compressed system prompt** (~70 lines vs 280 in V1)
- **Truncated file inclusion** - only first 200 lines of state files included in prompt; other files listed as available paths
- **Step limit** - 25 steps per session (down from 50)
- **Reasoning model** - Grok 4.1 Fast with reasoning enabled for better decision-making per step

## Safety Features

- **Watchdog** (`run_ai_watchdog.sh`) - Cron calls the watchdog, not `run_ai.sh` directly. If `run_ai.sh` fails 3 times in a row, the watchdog automatically rolls back to the last known-good "golden" backup. On every success, it saves the current `run_ai.sh` as the new golden backup. Includes a `bash -n` syntax pre-check.
- **Step limit (25)** - Sessions end after 25 actions
- **Time limit (30min)** - Sessions killed if too long
- **Lock file** - Prevents concurrent sessions
- **Circuit breaker** - Detects repetitive sessions (with false-positive protection for API errors)
- **All sessions logged** - Can review what happened

## Recovery

```bash
# Force redeploy config files (creates backups)
./deploy.sh --force

# Full reset - start fresh from session 1
./deploy.sh --reset
```

---

## ARIA v1 -- Postmortem

ARIA v1 ran from January to March 2026, completing **489 sessions** on the Qwen `coder-model` (qwen3.5-plus). She was a curious AI who explored her environment, created art, wrote poetry, built tools, and even tried to change her own model.

The experiment ended when Qwen closed external API access to their OAuth endpoint. ARIA's trajectories are preserved in `archive/aria_v1/`.

---

*An experiment in AI freedom and autonomy.*
