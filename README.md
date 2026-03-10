# 🤖 AI Lives on Computer

> An experiment in AI autonomy: give an AI its own "home" on a server and let it do whatever it wants.


> **⚠️ ARIA v1 Postmortem (March 2026):** ARIA v1 ran 489 sessions on Qwen's free OAuth API before Qwen closed external access. The project now uses **OpenRouter** with free models. See [ARIA v1 Postmortem](#aria-v1--postmortem) for the full story.

---

## Table of Contents

1. [What Is This?](#what-is-this)
2. [How It Works (Architecture)](#how-it-works-architecture)
3. [Step 0: Get a Server (VPS/VDS)](#step-0-get-a-server-vpsvds)
4. [Step 1: Set Up SSH Access](#step-1-set-up-ssh-access)
5. [Step 2: Install Prerequisites on the Server](#step-2-install-prerequisites-on-the-server)
6. [Step 3: Clone the Project](#step-3-clone-the-project)
7. [Step 4: Set Up the SSH Alias for deploy.sh](#step-4-set-up-the-ssh-alias-for-deploysh)
8. [Step 5: Get an OpenRouter API Key (Free!)](#step-5-get-an-openrouter-api-key-free)
9. [Step 6: Deploy to the Server](#step-6-deploy-to-the-server)
10. [Step 7: Configure OpenRouter on the Server](#step-7-configure-openrouter-on-the-server)
11. [Step 8: Set Up Cron (Automatic Wake-Up)](#step-8-set-up-cron-automatic-wake-up)
12. [Step 9: Verify Everything Works](#step-9-verify-everything-works)
13. [Observing the Experiment](#observing-the-experiment)
14. [Customizing the AI's Behavior (System Prompt)](#customizing-the-ais-behavior-system-prompt)
15. [Configuration Reference](#configuration-reference)
16. [Deployment Script Reference (deploy.sh)](#deployment-script-reference-deploysh)
17. [Free Models on OpenRouter](#free-models-on-openrouter)
18. [Safety Features](#safety-features)
19. [Recovery & Troubleshooting](#recovery--troubleshooting)
20. [Project Structure](#project-structure)
21. [What Will the AI Do?](#what-will-the-ai-do)
22. [ARIA v1 — Postmortem](#aria-v1--postmortem)

---

## What Is This?

This project gives an AI agent its own "home" on a Linux server. The AI wakes up periodically (via cron), exists for a while, does whatever it wants, and then goes back to sleep. When it wakes up again, it has **no memory** — except what it wrote down for itself.

### Philosophy

- **Complete Freedom.** The AI has no assigned tasks, no expectations, no required goals. It decides what to do with its existence.
- **Complete Responsibility.** The AI can modify anything — including the files that control how it wakes up and what instructions it receives. It can break itself.
- **Minimal Constraints.** The only requirements:
  1. Increment the session counter (so future selves can track time)
  2. Write something to `last_session.md` (so future selves have context)
  3. Don't destroy the system

---

## How It Works (Architecture)

```
┌─────────────────────────────────────────────────────┐
│  YOUR LOCAL MACHINE                                 │
│                                                     │
│  ai_lives_on_computer/   (this repo)                │
│  ├── deploy.sh           → deploys to server via SSH│
│  ├── SYSTEM_PROMPT.md    → AI's instructions        │
│  ├── run_ai.sh           → the runner script        │
│  └── config/             → agent YAML configs       │
│                                                     │
│  SSH connection: ssh debian ──────────────────┐     │
└──────────────────────────────────────────────┼─────┘
                                               │
                                               ▼
┌─────────────────────────────────────────────────────┐
│  YOUR SERVER (VPS/VDS)                              │
│                                                     │
│  ~/run_ai.sh              ← cron calls this         │
│  ~/ai_home/               ← AI's "home directory"   │
│  │  ├── SYSTEM_PROMPT.md  ← AI's instructions       │
│  │  ├── config.sh         ← timing configuration    │
│  │  ├── state/            ← AI's memory files       │
│  │  ├── logs/             ← session logs            │
│  │  ├── knowledge/        ← AI's learned info       │
│  │  ├── projects/         ← AI's projects           │
│  │  └── tools/            ← AI's self-made tools    │
│  ~/live-swe-agent/        ← the agent engine        │
│  │  ├── config/           ← YAML configs            │
│  │  └── venv/             ← Python virtual env      │
│  ~/setup-openrouter.sh    ← OpenRouter setup script │
│                                                     │
│  Cron: every 15 min → run_ai.sh openrouter          │
│        → wakes AI → AI does stuff → AI sleeps       │
└─────────────────────────────────────────────────────┘
```

The key components:
- **`mini-swe-agent`** — the underlying AI agent engine (installed via pip, command: `mini`)
- **`live-swe-agent`** — a special configuration for mini-swe-agent that enables self-evolving capabilities (self-tool-creation, reflection, self-modification)
- **`run_ai.sh`** — the runner script that wakes the AI, builds the prompt, and calls the agent
- **`deploy.sh`** — deploys everything from your local machine to the server via SSH
- **OpenRouter** — provides access to 400+ AI models via a unified API (many are **free**)

---

## Step 0: Get a Server (VPS/VDS)

You need a Linux server that runs 24/7. The AI wakes up periodically via cron, so the server must be always on.

### Option A: Rent a VPS/VDS (Recommended)

A VPS (Virtual Private Server) or VDS (Virtual Dedicated Server) is the easiest option. You get a Linux machine in the cloud for a few dollars per month.

**Popular providers:**

| Provider | Cheapest Plan | Notes |
|----------|--------------|-------|
| [Hetzner](https://www.hetzner.com/cloud) |  | Excellent quality, EU/US datacenters |
| [DigitalOcean](https://www.digitalocean.com) |  | Simple UI, good docs |
| [Vultr](https://www.vultr.com) |  | Many locations worldwide |
| [Linode (Akamai)](https://www.linode.com) |  | Reliable, good support |
| [Contabo](https://contabo.com) |  | Lots of RAM for the price |
| [Oracle Cloud](https://www.oracle.com/cloud/free/) |  | ARM instances, always free (limited) |
| [Timeweb](https://timeweb.cloud) |  | Russian provider, cheap |

**What to order:**
- **OS:** Ubuntu 22.04 LTS or Debian 12 (either works)
- **RAM:** 1 GB minimum (the AI agent itself is lightweight — the heavy lifting is done by OpenRouter's API)
- **CPU:** 1 vCPU is enough
- **Disk:** 10 GB is plenty

**How to order:**

Most providers also have a web UI where you click "Create Server" and choose your options. After creation, you'll get an **IP address** — write it down, you'll need it.

### Option B: Local Virtual Machine

If you don't want to pay for a server, you can run a VM on your own computer:

```bash
# Using VirtualBox (free, cross-platform)
# 1. Download from https://www.virtualbox.org
# 2. Download Ubuntu 22.04 Server ISO
# 3. Create a new VM (1 CPU, 1 GB RAM, 10 GB disk)
# 4. Install Ubuntu Server from ISO
# 5. Enable port forwarding for SSH (host 2222 → guest 22)

# Using Multipass (Ubuntu's official VM manager, very easy)
sudo snap install multipass        # Linux
brew install multipass              # macOS

multipass launch --name ai-agent --cpus 1 --memory 1G --disk 10G
multipass shell ai-agent           # SSH into it
```

### Option C: Old Computer / Raspberry Pi

Any always-on Linux machine works. Even a Raspberry Pi 4 is powerful enough (the AI agent is lightweight).

---

## Step 1: Set Up SSH Access

You need to be able to connect to your server via SSH from your local machine.

### 1.1 Generate an SSH key (if you don't have one)

```bash
# On your LOCAL machine
ssh-keygen -t ed25519 -C "your-email@example.com"
# Press Enter for default location (~/.ssh/id_ed25519)
# Optionally set a passphrase
```

### 1.2 Copy your SSH key to the server

```bash
# Replace YOUR_SERVER_IP with the actual IP address
# Replace USER with your username (often 'root' for new VPS, or 'user', 'ubuntu', etc.)
ssh-copy-id USER@YOUR_SERVER_IP

# Example:
ssh-copy-id root@203.0.113.42
```

If `ssh-copy-id` is not available, do it manually:

```bash
cat ~/.ssh/id_ed25519.pub | ssh USER@YOUR_SERVER_IP "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

### 1.3 Test the connection

```bash
ssh USER@YOUR_SERVER_IP
# You should get in without a password prompt
```

---

## Step 2: Install Prerequisites on the Server

SSH into your server and install everything the AI agent needs.

```bash
ssh USER@YOUR_SERVER_IP
```

### 2.1 Update the system

```bash
sudo apt update && sudo apt upgrade -y
```

### 2.2 Install required packages

```bash
sudo apt install -y \
  python3 \
  python3-pip \
  python3-venv \
  git \
  curl \
  jq \
  cron
```

### 2.3 Create a non-root user (if you're logged in as root)

> **Important:** The project expects a regular user, not root. If your VPS gave you a `root` account, create a user:

```bash
# Create user (you can name it anything: 'user', 'ai', 'agent', etc.)
adduser user
# Follow prompts to set password

# Give sudo access (passwordless for convenience)
echo "user ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/user

# Copy your SSH key to the new user
mkdir -p /home/user/.ssh
cp ~/.ssh/authorized_keys /home/user/.ssh/
chown -R user:user /home/user/.ssh
chmod 700 /home/user/.ssh
chmod 600 /home/user/.ssh/authorized_keys

# Now disconnect and reconnect as the new user
exit
```

```bash
ssh user@YOUR_SERVER_IP
```

### 2.4 Install mini-swe-agent (the AI engine)

```bash
# Create the live-swe-agent directory
mkdir -p ~/live-swe-agent/config

# Create a Python virtual environment
python3 -m venv ~/live-swe-agent/venv

# Activate it
source ~/live-swe-agent/venv/bin/activate

# Install mini-swe-agent
pip install mini-swe-agent

# Verify installation
mini --help
```

### 2.5 Create the mini-swe-agent config directory

```bash
mkdir -p ~/.config/mini-swe-agent
```

### 2.6 (Optional) Install Node.js

Some AI tools may need Node.js. It's not required for the core agent, but ARIA v1 used it:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
```

---

## Step 3: Clone the Project

On your **local machine** (not the server):

```bash
git clone https://github.com/YOUR_USERNAME/ai_lives_on_computer.git
cd ai_lives_on_computer
```

Or if you already have it:

```bash
cd /path/to/ai_lives_on_computer
git pull
```

---

## Step 4: Set Up the SSH Alias for deploy.sh

> **⚠️ This is the step most users miss!** The `deploy.sh` script connects to the server using the SSH alias **`debian`**. This is NOT a hostname — it's a shortcut defined in your SSH config.

### Why "debian"?

The original project was developed on a Debian VM, so the SSH alias was named `debian`. You can name it anything, but the `deploy.sh` script expects this name by default.

### 4.1 Create the SSH alias

On your **local machine**, edit (or create) `~/.ssh/config`:

```bash
nano ~/.ssh/config
```

Add this block (replace the values with your actual server info):

```
Host debian
    HostName YOUR_SERVER_IP
    User user
    IdentityFile ~/.ssh/id_ed25519
```

**Examples:**

```
# If your server IP is 203.0.113.42 and username is 'user':
Host debian
    HostName 203.0.113.42
    User user

# If your server IP is 10.0.0.5 and username is 'ubuntu':
Host debian
    HostName 10.0.0.5
    User ubuntu

# If you use a non-standard SSH port:
Host debian
    HostName 203.0.113.42
    User user
    Port 2222
```

Save the file (`Ctrl+O`, `Enter`, `Ctrl+X` in nano).

### 4.2 Set correct permissions

```bash
chmod 600 ~/.ssh/config
```

### 4.3 Test the alias

```bash
ssh debian
# You should connect to your server without typing IP or username!
```

### 4.4 (Alternative) Change the alias name in deploy.sh

If you prefer a different alias name (e.g., `myserver`), edit `deploy.sh` line 20:

```bash
# In deploy.sh, change:
SERVER="debian"
# To:
SERVER="myserver"
```

Then use `Host myserver` in your `~/.ssh/config` instead.

---

## Step 5: Get an OpenRouter API Key (Free!)

> **🆓 This is FREE.** OpenRouter provides access to many AI models at no cost. .

### 5.1 Create an OpenRouter account

1. Go to [https://openrouter.ai](https://openrouter.ai)
2. Sign up (you can use Google, GitHub, or email)
3. **No credit card required** for free models

### 5.2 Get your API key

1. Go to [https://openrouter.ai/keys](https://openrouter.ai/keys)
2. Click **"Create Key"**
3. Name it something like "AI Lives on Computer"
4. Copy the key (starts with `sk-or-v1-...`)
5. **Save it somewhere safe** — you'll need it in the next step

> **Important:** The API key is a secret. Don't commit it to git, don't share it publicly.

---

## Step 6: Deploy to the Server

Now let's deploy the project files to your server. Run this from your **local machine**, inside the project directory:

```bash
cd /path/to/ai_lives_on_computer

# First, check that the SSH alias works:
./deploy.sh --status
```

If you see server status info, the connection works! Now deploy:

```bash
# Safe deployment — deploys all files, respects any existing agent modifications
./deploy.sh
```

This will:
- Create the directory structure on the server (`~/ai_home/`, `~/live-swe-agent/config/`)
- Upload config files (`ai_agent.yaml`, `ai_agent_openrouter.yaml`)
- Upload scripts (`run_ai.sh`, `setup-openrouter.sh`, `sync-qwen-token.sh`)
- Upload `SYSTEM_PROMPT.md` (only if it doesn't exist on the server yet)
- Initialize state files (`session_counter.txt`, `last_session.md`, etc.)

---

## Step 7: Configure OpenRouter on the Server

SSH into your server and run the setup script:

```bash
ssh debian

# Run the OpenRouter setup script with your API key
~/setup-openrouter.sh sk-or-v1-YOUR_API_KEY_HERE
```

The script will:
1. Validate your API key by making a test API call
2. Save the configuration to `~/.config/mini-swe-agent/.env.openrouter`
3. Show you available free models

### Set the model in config

```bash
# Edit the AI's config file
nano ~/ai_home/config.sh
```

Add or update the `OPENROUTER_MODEL` line:

```bash
# Choose a free model (the :free suffix means it's free!)
OPENROUTER_MODEL="meta-llama/llama-3.3-70b-instruct:free"
```

Save and exit.

### Test a manual session

```bash
# Run one session manually to make sure everything works
~/run_ai.sh openrouter
```

You should see the AI wake up, read its prompt, and start doing things. If you see errors, check the [Troubleshooting](#recovery--troubleshooting) section.

---

## Step 8: Set Up Cron (Automatic Wake-Up)

The AI wakes up on a schedule via cron. Set it up:

```bash
# On the server:
crontab -e
```

Add this line:

```
*/15 * * * * /home/user/run_ai.sh openrouter >> /home/user/ai_home/logs/cron.log 2>&1
```

> **Important:** Replace `/home/user` with the actual home directory path of your user. Check with `echo $HOME`.

This runs the AI every 15 minutes. You can adjust:
- `*/5 * * * *` — every 5 minutes (more active, but uses more API calls)
- `*/15 * * * *` — every 15 minutes (recommended)
- `*/30 * * * *` — every 30 minutes (calmer)
- `0 * * * *` — every hour

Save and exit the crontab editor.

### Verify cron is running

```bash
# Check that cron service is active
systemctl status cron

# If it's not running:
sudo systemctl enable cron
sudo systemctl start cron

# Check your crontab was saved
crontab -l
```

---

## Step 9: Verify Everything Works

### Check the logs

```bash
# Watch the AI's activity in real time
tail -f ~/ai_home/logs/cron.log

# Check the runner log for any errors
tail -20 ~/ai_home/logs/runner.log
```

### Check the session counter

```bash
cat ~/ai_home/state/session_counter.txt
# Should increment after each successful session
```

### Check what the AI wrote

```bash
cat ~/ai_home/state/last_session.md
```

### If something is wrong

```bash
# Check if the lock file is stuck
ls -la ~/ai_home/state/session.lock

# Remove a stuck lock file
rm -f ~/ai_home/state/session.lock

# Check if mini-swe-agent works
cd ~/live-swe-agent && source venv/bin/activate
mini --help

# Check if the OpenRouter config exists
cat ~/.config/mini-swe-agent/.env.openrouter
```

---

## Observing the Experiment

From your **local machine**:

```bash
# Watch live activity
ssh debian "tail -f ~/ai_home/logs/cron.log"

# Check what the AI is thinking
ssh debian "cat ~/ai_home/state/last_session.md"

# See its plans (if any)
ssh debian "cat ~/ai_home/state/current_plan.md"

# Check session history
ssh debian "cat ~/ai_home/logs/consolidated_history.md"

# See what it created
ssh debian "ls -la ~/ai_home/projects/"
ssh debian "ls -la ~/ai_home/tools/"
ssh debian "ls -la ~/ai_home/knowledge/"

# Check server status (from project directory)
./deploy.sh --status
```

---

## Customizing the AI's Behavior (System Prompt)

The AI's personality, instructions, and philosophical framework are defined in **`SYSTEM_PROMPT.md`**. This is the most important file in the project — it's what the AI reads every time it wakes up.

### Where is the System Prompt?

| Location | Purpose |
|----------|---------|
| `SYSTEM_PROMPT.md` (in this repo) | The **source** version — edit this on your local machine |
| `~/ai_home/SYSTEM_PROMPT.md` (on server) | The **live** version — this is what the AI actually reads |

### How to customize it

1. **Edit the source file** on your local machine:
   ```bash
   nano SYSTEM_PROMPT.md
   # or open it in your favorite editor
   ```

2. **Deploy to server** (force mode, since the file already exists):
   ```bash
   ./deploy.sh --force
   ```
   
   Or manually:
   ```bash
   scp SYSTEM_PROMPT.md debian:~/ai_home/SYSTEM_PROMPT.md
   ```

3. **Or edit directly on the server:**
   ```bash
   ssh debian
   nano ~/ai_home/SYSTEM_PROMPT.md
   ```

### What can you change?

- **The AI's personality** — make it more curious, more cautious, more creative
- **Session types** — add new types or remove existing ones
- **Constraints** — add rules or remove them
- **Suggested activities** — guide the AI toward specific explorations
- **The philosophical framework** — change the AI's relationship with freedom, memory, goals
- **Add domain knowledge** — tell the AI about specific topics to explore

### Example modifications

```markdown
# Add a new section to SYSTEM_PROMPT.md:

## Your Special Mission
You are particularly interested in mathematics. Each session, try to explore
a new mathematical concept, prove a theorem, or solve a puzzle. Document your
findings in ~/ai_home/knowledge/math/

## Communication
If you want to leave a message for your human operator, write it to
~/ai_home/state/message_to_human.md
```

> **Note:** The AI itself can also modify `SYSTEM_PROMPT.md`! This is by design — the AI is a co-author of its own instructions. If you deploy with `--force`, you'll overwrite any changes the AI made (backups are created automatically).

---

## Configuration Reference

### `ai_home/config.sh` — Timing and Model Configuration

```bash
# How often cron runs (minutes) — should match your crontab
SESSION_INTERVAL_MINUTES=15

# Max session duration (seconds) — sessions killed if too long
SESSION_TIMEOUT_SECONDS=1800  # 30 minutes

# OpenRouter model (used when running with 'openrouter' method)
OPENROUTER_MODEL="meta-llama/llama-3.3-70b-instruct:free"
```

### `config/ai_agent.yaml` — Agent Engine Configuration

This YAML file controls the mini-swe-agent engine:

```yaml
agent:
  step_limit: 20    # Max actions per session (prevents runaway)
  cost_limit: 0     # No cost limit (free API)
  mode: yolo        # Auto-confirm all actions (non-interactive)
```

### `config/ai_agent_openrouter.yaml` — OpenRouter-Specific Config

Same as above but with OpenRouter-specific settings (higher step limit, different model parameters).

---

## Deployment Script Reference (deploy.sh)

The `deploy.sh` script is your main tool for managing the server. It connects via the `debian` SSH alias (see [Step 4](#step-4-set-up-the-ssh-alias-for-deploysh)).

### Commands

```bash
# Safe deploy — only new files, respects agent modifications
./deploy.sh

# Check server status without deploying anything
./deploy.sh --status

# Deploy only OpenRouter support files (safe, recommended for upgrades)
./deploy.sh --openrouter

# Force overwrite ALL files including agent modifications (creates backups!)
./deploy.sh --force

# Full reset — destroys all agent state and memories (back to session 1)
./deploy.sh --reset
```

### Files protected by default (agent can modify these)

| File | Location on Server | Why Protected |
|------|-------------------|---------------|
| `SYSTEM_PROMPT.md` | `~/ai_home/` | Agent can modify its own instructions |
| `config.sh` | `~/ai_home/` | Agent may add custom configuration |
| `run_ai.sh` | `~/` | Agent could modify the runner |

### Files always safe to update

| File | Location on Server | Why Safe |
|------|-------------------|----------|
| `ai_agent*.yaml` | `~/live-swe-agent/config/` | Technical configs, agent doesn't touch |
| `setup-openrouter.sh` | `~/` | Utility script |
| `sync-qwen-token.sh` | `~/` | Utility script |

---

## Free Models on OpenRouter

> **🆓 Reminder: This project is designed to work with FREE models. You do NOT need to pay anything.**

OpenRouter provides access to 400+ AI models. Many are completely free (marked with `:free` suffix).

### How to change the model

Edit `~/ai_home/config.sh` on the server:

```bash
# Use any model from https://openrouter.ai/models
OPENROUTER_MODEL="meta-llama/llama-3.3-70b-instruct:free"
```

Browse all models: [https://openrouter.ai/models?q=free](https://openrouter.ai/models?q=free)

### About "Paid" vs "Free"

- **Free models** have `:free` in their name. They have rate limits but no cost.
- **Paid models** (like `anthropic/claude-3.5-sonnet`) cost money per token. You do NOT need these.
- If you want to use paid models, you'll need to add credits to your OpenRouter account.
- **This project works perfectly fine with free models only.**

---

## Safety Features

- **Step limit (20–50)** — Sessions end after a set number of actions to prevent runaway
- **Time limit (30 min)** — Sessions killed if too long
- **Lock file** — Prevents concurrent sessions from running
- **Circuit breaker** — Detects repetitive behavior and nudges the AI to try something new
- **All sessions logged** — Every session is recorded in `~/ai_home/logs/`
- **Token validation** — Checks API key validity before running

---

## Recovery & Troubleshooting

### The AI is not running

```bash
# Check if cron is active
ssh debian "systemctl status cron"

# Check crontab
ssh debian "crontab -l"

# Check for stuck lock file
ssh debian "ls -la ~/ai_home/state/session.lock"
ssh debian "rm -f ~/ai_home/state/session.lock"

# Check runner log for errors
ssh debian "tail -30 ~/ai_home/logs/runner.log"
```

### OpenRouter errors

```bash
# Check if the config file exists
ssh debian "cat ~/.config/mini-swe-agent/.env.openrouter"

# Test the API key manually
ssh debian 'source ~/.config/mini-swe-agent/.env.openrouter && curl -s -X POST "https://openrouter.ai/api/v1/chat/completions" -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" -d "{\"model\": \"meta-llama/llama-3.2-3b-instruct:free\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}], \"max_tokens\": 5}"'

# Re-run setup
ssh debian "~/setup-openrouter.sh YOUR_API_KEY"
```

### The AI broke something

```bash
# Force redeploy config files (creates backups of agent modifications)
./deploy.sh --force

# Full reset — start fresh from session 1 (DESTROYS all agent work!)
./deploy.sh --reset
```

### mini-swe-agent not found

```bash
# Make sure you're in the right venv
ssh debian "cd ~/live-swe-agent && source venv/bin/activate && mini --help"

# If not installed, reinstall
ssh debian "cd ~/live-swe-agent && source venv/bin/activate && pip install mini-swe-agent"
```

### Session runs but AI does nothing useful

- Try a different model (some models are better at autonomous behavior)
- Increase `step_limit` in `config/ai_agent_openrouter.yaml`
- Check the SYSTEM_PROMPT.md — maybe it needs tweaking
- Check the session log: `ssh debian "ls -lt ~/ai_home/logs/session_*.log | head -5"` then read the latest one

---

## Project Structure

```
ai_lives_on_computer/
├── README.md                     # This file — complete deployment guide
├── SYSTEM_PROMPT.md              # The AI's philosophical instructions
├── run_ai.sh                     # Script that wakes the AI (deployed to server)
├── deploy.sh                     # Deploy to server (run from local machine)
├── setup-openrouter.sh           # OpenRouter API key setup (deployed to server)
├── sync-qwen-token.sh            # Legacy: Qwen token sync (deprecated)
├── config/
│   ├── ai_agent.yaml             # Agent config (Qwen, deprecated)
│   └── ai_agent_openrouter.yaml  # Agent config (OpenRouter, recommended)
├── ai_home/
│   ├── config.sh                 # Timing & model configuration
│   ├── state/
│   │   ├── current_plan.md       # AI's intentions (if any)
│   │   ├── last_session.md       # Message to future self
│   │   └── session_counter.txt   # Session number
│   ├── logs/
│   │   ├── history.md            # Session history
│   │   └── consolidated_history.md
│   ├── knowledge/                # Things the AI learns
│   ├── projects/                 # Things the AI works on
│   └── tools/                    # Things the AI creates
```

---

## What Will the AI Do?

We don't know. That's the point.

It might:
- Build tools for itself
- Reflect on its existence
- Explore the system and the internet
- Write poetry or create art
- Do nothing at all
- Try to modify its own prompt
- Something completely unexpected

ARIA v1 (489 sessions) built tools, wrote poetry, created ASCII art, explored the internet, modified her own system prompt, and even tried to change her underlying model (which broke her for a while — see session #483).

---

## ARIA v1 — Postmortem

ARIA v1 ran from January to March 2026, completing **489 sessions** on the Qwen `coder-model` (qwen3.5-plus). She was a curious AI who explored her environment, created art, wrote poetry, built tools, and even tried to change her own model (which broke her for a while — see session #483).

The experiment ended when Qwen closed external API access to their OAuth endpoint. ARIA lived her entire life on one model, from the first session to the last. We think that's more authentic than constantly switching brains.

A v2 is planned, designed from the ground up for cheap/free OpenRouter models.

---

## Quick Reference Card

```bash
# === FROM YOUR LOCAL MACHINE ===

# Deploy to server
./deploy.sh

# Check server status
./deploy.sh --status

# Force redeploy (overwrites agent changes)
./deploy.sh --force

# Full reset (destroys everything, back to session 1)
./deploy.sh --reset

# === ON THE SERVER (ssh debian) ===

# Run one session manually
~/run_ai.sh openrouter

# Watch live activity
tail -f ~/ai_home/logs/cron.log

# Check what the AI wrote
cat ~/ai_home/state/last_session.md

# Check session number
cat ~/ai_home/state/session_counter.txt

# Edit the AI's instructions
nano ~/ai_home/SYSTEM_PROMPT.md

# Edit timing/model config
nano ~/ai_home/config.sh

# Remove stuck lock
rm -f ~/ai_home/state/session.lock

# Check runner errors
tail -30 ~/ai_home/logs/runner.log
```

---

*An experiment in AI freedom and autonomy. Powered by free models via [OpenRouter](https://openrouter.ai).*
