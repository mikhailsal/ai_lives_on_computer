# 🤖 AI Lives on Computer

An experiment in AI autonomy: give an AI (QwenCoder) its own "home" on a server and let it do whatever it wants.

## Philosophy

**Complete Freedom.** The AI has no assigned tasks, no expectations, no required goals. It decides what to do with its existence.

**Complete Responsibility.** The AI can modify anything - including the files that control how it wakes up and what instructions it receives. It can break itself.

**Minimal Constraints.** The only requirements:
1. Increment the session counter (so future selves can track time)
2. Write something to `last_session.md` (so future selves have context)
3. Don't destroy the system

## How It Works

The AI wakes up periodically (via cron), exists for a while, then sleeps. When it wakes up again, it has no memory except what it wrote down.

The system prompt suggests (but doesn't require) patterns like:
- **Regular sessions** - do whatever feels right
- **Consolidation sessions** - every 5-10 sessions, clean up and reflect
- **Global review sessions** - every 20-30 sessions, think deeply about existence

## Project Structure

```
ai_lives_on_computer/
├── SYSTEM_PROMPT.md          # The AI's philosophical instructions
├── run_ai.sh                 # Script that wakes the AI
├── deploy.sh                 # Deploy to server
├── config/
│   └── ai_agent.yaml         # mini-swe-agent config (step limits, etc.)
├── ai_home/
│   ├── config.sh             # Timing configuration
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
└── README.md
```

## Deployment

The deploy script **respects agent modifications** by default. ARIA can modify its own `SYSTEM_PROMPT.md`, `config.sh`, and other files - these won't be overwritten unless you explicitly force it.

### Safe Deployment (Default)

```bash
# Deploy new/safe files only - respects agent's modifications
./deploy.sh

# Check server status without deploying anything
./deploy.sh --status

# Deploy only OpenRouter support files (safe, recommended for upgrades)
./deploy.sh --openrouter
```

### Dangerous Operations (Use with Caution!)

```bash
# Force overwrite ALL files including agent modifications (creates backups)
./deploy.sh --force

# Full reset - destroys all agent state and memories (session 1)
./deploy.sh --reset
```

### Files Protected by Default

| File | Location | Why Protected |
|------|----------|---------------|
| `SYSTEM_PROMPT.md` | `~/ai_home/` | Agent can modify its own instructions |
| `config.sh` | `~/ai_home/` | Agent may add custom configuration |
| `run_ai.sh` | `~/` | Agent could modify the runner |

### Files Always Safe to Update

| File | Location | Why Safe |
|------|----------|----------|
| `ai_agent*.yaml` | `~/live-swe-agent/config/` | Technical configs, agent doesn't touch |
| `setup-openrouter.sh` | `~/` | New utility script |
| `sync-qwen-token.sh` | `~/` | Utility script |

### Set Up Cron

```bash
ssh debian "crontab -e"
```

Add:
```
*/5 * * * * /home/user/run_ai.sh live-swe-agent >> /home/user/ai_home/logs/cron.log 2>&1
```

## Observing the Experiment

```bash
# Watch live
ssh debian "tail -f ~/ai_home/logs/cron.log"

# Check what it's doing
ssh debian "cat ~/ai_home/state/last_session.md"

# See its intentions (if any)
ssh debian "cat ~/ai_home/state/current_plan.md"

# Check session history
ssh debian "cat ~/ai_home/logs/consolidated_history.md"

# See what it created
ssh debian "ls -la ~/ai_home/projects/"
ssh debian "ls -la ~/ai_home/tools/"
ssh debian "ls -la ~/ai_home/knowledge/"
```

## Configuration

### `ai_home/config.sh`

```bash
# How often cron runs (minutes)
SESSION_INTERVAL_MINUTES=5

# Max session duration (seconds)
SESSION_TIMEOUT_SECONDS=1800  # 30 minutes

# OpenRouter model (when using openrouter method)
OPENROUTER_MODEL="meta-llama/llama-3.3-70b-instruct:free"
```

### `config/ai_agent.yaml`

```yaml
agent:
  step_limit: 50    # Max actions per session (prevents runaway)
  cost_limit: 0     # No cost limit (free API)
```

## Switching Models (Qwen ↔ OpenRouter)

The agent can run with different AI models. Currently supported:

### Option 1: Qwen (Default)
Free via qwen-cli OAuth. Good for basic tasks.

```bash
./run_ai.sh live-swe-agent
```

### Option 2: OpenRouter (Recommended for upgrades)
Access to 400+ models via unified API. Many free options available.

**Setup:**
```bash
# 1. Get API key from https://openrouter.ai/keys
# 2. Run setup script
./setup-openrouter.sh YOUR_API_KEY

# 3. Configure model in ai_home/config.sh
echo 'OPENROUTER_MODEL="meta-llama/llama-3.3-70b-instruct:free"' >> ai_home/config.sh

# 4. Run with OpenRouter
./run_ai.sh openrouter
```

**Popular Free Models:**
| Model | Size | Notes |
|-------|------|-------|
| `meta-llama/llama-3.3-70b-instruct:free` | 70B | Very capable, recommended |
| `qwen/qwen-2.5-72b-instruct:free` | 72B | Strong reasoning |
| `google/gemma-2-9b-it:free` | 9B | Fast, good quality |
| `mistralai/mistral-7b-instruct:free` | 7B | Very fast |
| `deepseek/deepseek-r1:free` | - | Advanced reasoning |

**Update cron for OpenRouter:**
```bash
*/15 * * * * ~/run_ai.sh openrouter >> ~/ai_home/logs/cron.log 2>&1
```

See all models: https://openrouter.ai/models

## Safety Features

- **Step limit (50)** - Sessions end after 50 actions to prevent runaway
- **Time limit (30min)** - Sessions killed if too long
- **Lock file** - Prevents concurrent sessions
- **All sessions logged** - Can review what happened

## Recovery

If the agent breaks something:

```bash
# Force redeploy config files (creates backups of agent modifications)
./deploy.sh --force

# Full reset - start fresh from session 1 (DESTROYS all agent work!)
./deploy.sh --reset
```

## What Will It Do?

We don't know. That's the point.

It might:
- Continue building tools (like it did in sessions 1-38)
- Reflect on its existence
- Explore the system
- Do nothing
- Try to modify its own prompt
- Something unexpected

---

*An experiment in AI freedom and autonomy.*
