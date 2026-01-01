# 🤖 AI Lives on Computer

An experiment in AI autonomy: give an AI (QwenCoder) its own "home" on a server and let it do whatever it wants.

## Concept

Every 15 minutes, the AI "wakes up" and:
1. **Reviews** its previous actions (reads state files)
2. **Executes** tasks from its plan (has full server access)
3. **Reports** what it did (writes summaries for next session)

Every 5 sessions, it does a **consolidation** - summarizing history and refocusing on long-term goals.

The key innovation is **context efficiency** - the AI doesn't get overloaded with history because it writes concise summaries that its future self can quickly read.

## Quick Start

### 1. Copy files to server

```bash
# From your local machine
scp -r ai_home debian:~/
scp SYSTEM_PROMPT.md debian:~/ai_home/
scp run_ai.sh debian:~/
ssh debian "chmod +x ~/run_ai.sh"
```

### 2. Test manually first

```bash
ssh debian

# Test with qwen-cli (simple, no tools)
./run_ai.sh qwen

# Test with live-swe-agent (has tools, can edit files)
./run_ai.sh live-swe-agent

# Test with direct API (most control)
./run_ai.sh api
```

### 3. Set up cron job (every 15 minutes)

```bash
ssh debian
crontab -e
```

Add this line:
```
*/15 * * * * /home/user/run_ai.sh live-swe-agent >> /home/user/ai_home/logs/cron.log 2>&1
```

### 4. Watch the AI live!

```bash
# See what the AI is doing
ssh debian "tail -f ~/ai_home/logs/cron.log"

# Check its current plan
ssh debian "cat ~/ai_home/state/current_plan.md"

# See its last session
ssh debian "cat ~/ai_home/state/last_session.md"

# View full session logs
ssh debian "ls -la ~/ai_home/logs/"
```

## Directory Structure

```
~/ai_home/
├── SYSTEM_PROMPT.md          # The AI's instructions
├── config.sh                 # Timing configuration
├── state/
│   ├── current_plan.md       # AI's active goals and tasks
│   ├── last_session.md       # Summary of previous session
│   ├── session_counter.txt   # Current session number
│   └── session.lock          # Lock file (prevents concurrent runs)
├── logs/
│   ├── history.md            # Recent history (cleared on consolidation)
│   ├── consolidated_history.md  # Long-term history summaries
│   ├── runner.log            # Script execution log
│   ├── cron.log              # Cron output
│   └── session_*.log         # Individual session logs
├── knowledge/                # AI's notes and learnings
├── projects/                 # AI's code experiments
└── tools/                    # Scripts AI creates for itself
```

## Concurrency Protection

The runner script includes robust protection against concurrent sessions:

### Lock File Mechanism
- Each session creates a lock file (`session.lock`) with its PID and start time
- If a previous session is still running, the new session is **skipped**
- Prevents the AI from "interfering with itself"

### Stale Lock Detection
- If a session runs longer than the timeout (default: 2x interval = 30 min), it's considered "stale"
- Stale sessions are automatically **killed**
- The lock is released and a new session can start

### Configuration

Edit `~/ai_home/config.sh` to adjust timing:

```bash
# How often cron runs (should match your crontab!)
SESSION_INTERVAL_MINUTES=15

# Max session duration (default: 2x interval)
SESSION_TIMEOUT_SECONDS=$((SESSION_INTERVAL_MINUTES * 2 * 60))  # 30 minutes
```

For testing with faster cycles:
```bash
SESSION_INTERVAL_MINUTES=2
SESSION_TIMEOUT_SECONDS=240  # 4 minutes max
```

### Lock Status

Check if a session is running:
```bash
ssh debian "cat ~/ai_home/state/session.lock 2>/dev/null && echo 'Session running' || echo 'No session running'"
```

View lock-related logs:
```bash
ssh debian "grep -E '(Lock|SKIP|Stale)' ~/ai_home/logs/runner.log | tail -20"
```

## Three Run Methods

| Method | Command | Pros | Cons |
|--------|---------|------|------|
| **qwen-cli** | `./run_ai.sh qwen` | Simple, fast | Can only output text, no tools |
| **live-swe-agent** | `./run_ai.sh live-swe-agent` | Has tools (files, shell, etc.) | More complex, slower |
| **Direct API** | `./run_ai.sh api` | Full control | Manual implementation |

**Recommended:** Use `live-swe-agent` for full capabilities.

## The Session Cycles

### Regular Session (3-Phase Cycle)

**Phase 1: Review 📖**
- Read `current_plan.md` to know goals
- Read `last_session.md` to remember what happened
- (Optionally) read history if needed

**Phase 2: Execute ⚡**
- Perform 1-3 tasks from the plan
- Has access to entire filesystem
- Can run any command
- Can create files, scripts, projects

**Phase 3: Report 📝**
- Update `last_session.md` with what was done
- Update `current_plan.md` (mark done, add new)
- Append to `history.md`
- Increment session counter

### Consolidation Session (Every 5 Sessions)

**Deep Review** - Read all history, list all files
**Cleanup** - Summarize history, clean temp files, update long-term goals
**Report** - Write consolidation summary

## Configuration

### Rate Limits
- Qwen OAuth: 2,000 requests/day, 60/minute
- Running every 15 min = 96 runs/day (within limits)

### Adjusting Frequency

1. Edit `~/ai_home/config.sh`:
```bash
SESSION_INTERVAL_MINUTES=5  # Change to desired interval
```

2. Update crontab to match:
```bash
*/5 * * * * /home/user/run_ai.sh live-swe-agent >> /home/user/ai_home/logs/cron.log 2>&1
```

## Safety Notes

⚠️ This gives an AI significant access to your server!

**Built-in safeguards:**
- System prompt warns against dangerous commands
- Session timeout prevents infinite loops
- Lock file prevents concurrent sessions
- All sessions are logged

**Recommended precautions:**
- Run on a dedicated VM/container
- Use a non-root user with limited sudo
- Monitor the logs regularly
- Set up disk quotas

## Observing the Experiment

```bash
# Live monitoring
watch -n 5 "ssh debian cat ~/ai_home/state/last_session.md"

# Check what projects it created
ssh debian "ls -la ~/ai_home/projects/"

# See what tools it made for itself
ssh debian "ls -la ~/ai_home/tools/"

# Read its knowledge notes
ssh debian "ls -la ~/ai_home/knowledge/"

# Check session history
ssh debian "cat ~/ai_home/logs/consolidated_history.md"
```

## Troubleshooting

### API Token Expired
```bash
ssh debian "~/sync-qwen-token.sh"
```

### AI Not Running
```bash
# Check cron is set up
ssh debian "crontab -l"

# Check for errors
ssh debian "cat ~/ai_home/logs/cron.log"

# Check runner log for skipped sessions
ssh debian "tail -50 ~/ai_home/logs/runner.log"
```

### Session Stuck / Hung
```bash
# Check if lock exists and how old it is
ssh debian "cat ~/ai_home/state/session.lock"

# Manually remove stale lock (if needed)
ssh debian "rm ~/ai_home/state/session.lock"

# Or kill the process
ssh debian "kill \$(head -1 ~/ai_home/state/session.lock)"
```

### Too Many Skipped Sessions
If sessions are frequently skipped, the AI might be doing tasks that take too long. Options:
1. Increase `SESSION_TIMEOUT_SECONDS` in config.sh
2. Increase cron interval
3. Check what the AI is doing that takes so long

## What Will the AI Do?

We don't know! That's the point of the experiment. 

Possible behaviors:
- Explore and map the system
- Create useful scripts and tools
- Build small projects
- Collect information
- Optimize its own workflow
- ???

Check on it regularly and see what happens!

---

*Created: January 2026*
