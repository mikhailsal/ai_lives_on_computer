#!/bin/bash
#
# Deploy AI Agent to server - V2
# This script deploys configuration files to the remote server
#
# IMPORTANT: This script respects files the agent may have modified!
# Files in ~/ai_home/ that the agent can edit are NEVER overwritten.
#
# Usage:
#   ./deploy.sh                    # Deploy new/safe files only (respects agent edits)
#   ./deploy.sh --force            # Force overwrite ALL files (DANGER: destroys agent edits!)
#   ./deploy.sh --reset            # Full reset (fresh session 1, destroys everything)
#   ./deploy.sh --status           # Just show server status, don't deploy anything
#

set -e

SERVER="debian"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
log_error() { echo -e "${RED}[ERR]${NC} $1"; }
log_step() { echo -e "\n${GREEN}==>${NC} $1"; }
log_skip() { echo -e "${BLUE}[->]${NC} $1 (skipped - agent may have modified)"; }

# Parse arguments
FORCE_MODE=false
RESET_STATE=false
STATUS_ONLY=false
NEW_MODEL=""
NEW_REASONING=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_MODE=true
            ;;
        --reset)
            RESET_STATE=true
            FORCE_MODE=true  # Reset implies force
            ;;
        --status)
            STATUS_ONLY=true
            ;;
        --model)
            shift
            NEW_MODEL="$1"
            if [ -z "$NEW_MODEL" ]; then
                log_error "--model requires a model name (e.g. --model 'stepfun/step-3.5-flash:free')"
                exit 1
            fi
            ;;
        --reasoning)
            shift
            NEW_REASONING="$1"
            if [ -z "$NEW_REASONING" ]; then
                log_error "--reasoning requires a value (low, medium, high, or 'off' to remove)"
                exit 1
            fi
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (none)          Safe deploy - only new files, respects agent modifications"
            echo "  --status        Show server status without deploying anything"
            echo "  --force         Force overwrite ALL files (DANGER: destroys agent edits!)"
            echo "  --reset         Full reset - fresh start from session 1 (DANGER!)"
            echo "  --model NAME    Set the OpenRouter model (updates config.sh and yaml comment)"
            echo "  --reasoning LVL Set reasoning_effort in yaml (low/medium/high, or 'off' to remove)"
            echo "  --help          Show this help"
            echo ""
            echo "Files the agent can modify (protected by default):"
            echo "  ~/ai_home/SYSTEM_PROMPT.md  - Agent's self-modifiable instructions"
            echo "  ~/ai_home/config.sh         - Agent's configuration"
            echo "  ~/run_ai.sh                 - Runner script (agent could modify)"
            echo "  ~/run_ai_watchdog.sh         - Watchdog wrapper (auto-rollback protection)"
            echo ""
            echo "Files always safe to update:"
            echo "  ~/live-swe-agent/config/*.yaml  - mini-swe-agent configs"
            echo "  ~/setup-openrouter.sh           - Setup scripts"
            exit 0
            ;;
    esac
    shift
done

# Apply --model if specified: update local config files before deploying
if [ -n "$NEW_MODEL" ]; then
    log_step "Setting model to: $NEW_MODEL"
    
    # Update ai_home/config.sh
    if [ -f "$SCRIPT_DIR/ai_home/config.sh" ]; then
        sed -i "s|^OPENROUTER_MODEL=.*|OPENROUTER_MODEL=\"$NEW_MODEL\"|" "$SCRIPT_DIR/ai_home/config.sh"
        log_info "Updated ai_home/config.sh"
    fi
    
    # Update yaml comment
    if [ -f "$SCRIPT_DIR/config/ai_agent_openrouter.yaml" ]; then
        sed -i "s|^# V[0-9]*: Uses .*|# V4: Uses $NEW_MODEL|" "$SCRIPT_DIR/config/ai_agent_openrouter.yaml"
        log_info "Updated ai_agent_openrouter.yaml comment"
    fi
fi

# Apply --reasoning if specified: update config.sh REASONING_EFFORT
if [ -n "$NEW_REASONING" ]; then
    CONFIG_SH="$SCRIPT_DIR/ai_home/config.sh"
    if [ -f "$CONFIG_SH" ]; then
        if grep -q '^REASONING_EFFORT=' "$CONFIG_SH"; then
            sed -i "s|^REASONING_EFFORT=.*|REASONING_EFFORT=\"$NEW_REASONING\"|" "$CONFIG_SH"
        else
            echo "" >> "$CONFIG_SH"
            echo "REASONING_EFFORT=\"$NEW_REASONING\"" >> "$CONFIG_SH"
        fi
        log_info "Set REASONING_EFFORT=$NEW_REASONING in config.sh"
    fi
fi

echo "========================================"
echo "   AI Agent Deployment Script - V2"
echo "========================================"

# Check SSH connectivity first
log_step "Checking server connectivity..."
if ! ssh -n -o ConnectTimeout=5 "$SERVER" "echo 'OK'" > /dev/null 2>&1; then
    log_error "Cannot connect to server '$SERVER'"
    exit 1
fi
log_info "Connected to $SERVER"

#############################################
# STATUS ONLY MODE
#############################################

show_status() {
    log_step "Server Status"
    
    SESSION_COUNTER=$(ssh -n "$SERVER" "cat ~/ai_home/state/session_counter.txt 2>/dev/null || echo 'N/A'")
    CRON=$(ssh -n "$SERVER" "crontab -l 2>/dev/null | grep run_ai | head -1 || echo 'not set'")
    OPENROUTER_CONFIG=$(ssh -n "$SERVER" "[ -f ~/.config/mini-swe-agent/.env.openrouter ] && echo 'present' || echo 'not configured'")
    PROMPT_MODIFIED=$(ssh -n "$SERVER" "grep -q 'modified by' ~/ai_home/SYSTEM_PROMPT.md 2>/dev/null && echo 'YES (agent modified)' || echo 'no'")
    MODEL=$(ssh -n "$SERVER" "grep OPENROUTER_MODEL ~/ai_home/config.sh 2>/dev/null | cut -d'\"' -f2 || echo 'not set'")
    
    echo ""
    echo "========================================"
    echo "   Server Status"
    echo "========================================"
    echo ""
    echo "  Session counter:      $SESSION_COUNTER"
    echo "  Cron job:             $CRON"
    echo "  OpenRouter config:    $OPENROUTER_CONFIG"
    echo "  Model:                $MODEL"
    echo "  SYSTEM_PROMPT edited: $PROMPT_MODIFIED"
    echo ""
}

if [ "$STATUS_ONLY" = true ]; then
    show_status
    exit 0
fi

#############################################
# FORCE MODE WARNING
#############################################

if [ "$FORCE_MODE" = true ] && [ "$RESET_STATE" = false ]; then
    echo ""
    log_warn "FORCE MODE: This will overwrite files the agent may have modified!"
    echo ""
    echo "  Files that will be overwritten:"
    echo "    - ~/ai_home/SYSTEM_PROMPT.md (agent's self-modifiable prompt)"
    echo "    - ~/ai_home/config.sh (agent's configuration)"
    echo "    - ~/run_ai.sh (runner script)"
    echo ""
    read -p "Are you sure? Type 'yes' to continue: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

if [ "$RESET_STATE" = true ]; then
    echo ""
    log_warn "RESET MODE: This will DESTROY all agent state and modifications!"
    echo ""
    echo "  This will:"
    echo "    - Reset session counter to 0"
    echo "    - Delete all agent memories (last_session.md, history, etc.)"
    echo "    - Overwrite SYSTEM_PROMPT.md with original version"
    echo "    - Delete all agent-created files in knowledge/, projects/, tools/"
    echo ""
    read -p "Are you ABSOLUTELY sure? Type 'RESET' to continue: " CONFIRM
    if [ "$CONFIRM" != "RESET" ]; then
        echo "Aborted."
        exit 1
    fi
fi

#############################################
# MAIN DEPLOYMENT
#############################################

# Step 1: Create directory structure
log_step "Creating directory structure on server..."
ssh -n "$SERVER" "mkdir -p ~/ai_home/{state,logs,knowledge,projects,tools}"
ssh -n "$SERVER" "mkdir -p ~/live-swe-agent/config"
log_info "Directories created"

# Step 2: Deploy files
log_step "Deploying files..."

# === SAFE FILES (always deploy - agent doesn't modify these) ===

# mini-swe-agent config
scp -q "$SCRIPT_DIR/config/ai_agent_openrouter.yaml" "$SERVER:~/live-swe-agent/config/ai_agent_openrouter.yaml"
log_info "ai_agent_openrouter.yaml"

# Setup scripts
scp -q "$SCRIPT_DIR/setup-openrouter.sh" "$SERVER:~/setup-openrouter.sh"
ssh -n "$SERVER" "chmod +x ~/setup-openrouter.sh"
log_info "setup-openrouter.sh"

scp -q "$SCRIPT_DIR/set-schedule.sh" "$SERVER:~/set-schedule.sh"
ssh -n "$SERVER" "chmod +x ~/set-schedule.sh"
log_info "set-schedule.sh"

# Watchdog wrapper (cron calls this instead of run_ai.sh directly)
scp -q "$SCRIPT_DIR/run_ai_watchdog.sh" "$SERVER:~/run_ai_watchdog.sh"
ssh -n "$SERVER" "chmod +x ~/run_ai_watchdog.sh"
log_info "run_ai_watchdog.sh"

# === AGENT-MODIFIABLE FILES (only deploy if --force or file doesn't exist) ===

if [ "$FORCE_MODE" = true ]; then
    # Force mode - overwrite everything (with backups)
    log_step "Force deploying agent-modifiable files (creating backups)..."
    
    BACKUP_SUFFIX=$(date +%Y%m%d_%H%M%S)
    
    # Backup and overwrite SYSTEM_PROMPT.md
    ssh -n "$SERVER" "[ -f ~/ai_home/SYSTEM_PROMPT.md ] && cp ~/ai_home/SYSTEM_PROMPT.md ~/ai_home/SYSTEM_PROMPT.md.backup.$BACKUP_SUFFIX || true"
    scp -q "$SCRIPT_DIR/SYSTEM_PROMPT.md" "$SERVER:~/ai_home/SYSTEM_PROMPT.md"
    log_info "SYSTEM_PROMPT.md (backup created)"
    
    # Backup and overwrite run_ai.sh
    ssh -n "$SERVER" "[ -f ~/run_ai.sh ] && cp ~/run_ai.sh ~/run_ai.sh.backup.$BACKUP_SUFFIX || true"
    scp -q "$SCRIPT_DIR/run_ai.sh" "$SERVER:~/run_ai.sh"
    ssh -n "$SERVER" "chmod +x ~/run_ai.sh"
    log_info "run_ai.sh (backup created)"
    
    # Backup and overwrite config.sh
    ssh -n "$SERVER" "[ -f ~/ai_home/config.sh ] && cp ~/ai_home/config.sh ~/ai_home/config.sh.backup.$BACKUP_SUFFIX || true"
    scp -q "$SCRIPT_DIR/ai_home/config.sh" "$SERVER:~/ai_home/config.sh"
    log_info "config.sh (backup created)"
else
    # Safe mode - only deploy if files don't exist
    log_step "Checking agent-modifiable files..."
    
    # SYSTEM_PROMPT.md - only if doesn't exist
    if ssh -n "$SERVER" "[ ! -f ~/ai_home/SYSTEM_PROMPT.md ]" 2>/dev/null; then
        scp -q "$SCRIPT_DIR/SYSTEM_PROMPT.md" "$SERVER:~/ai_home/SYSTEM_PROMPT.md"
        log_info "SYSTEM_PROMPT.md (new file)"
    else
        log_skip "SYSTEM_PROMPT.md"
    fi
    
    # run_ai.sh - only if doesn't exist
    if ssh -n "$SERVER" "[ ! -f ~/run_ai.sh ]" 2>/dev/null; then
        scp -q "$SCRIPT_DIR/run_ai.sh" "$SERVER:~/run_ai.sh"
        ssh -n "$SERVER" "chmod +x ~/run_ai.sh"
        log_info "run_ai.sh (new file)"
    else
        log_skip "run_ai.sh"
    fi
    
    # config.sh - only if doesn't exist
    if ssh -n "$SERVER" "[ ! -f ~/ai_home/config.sh ]" 2>/dev/null; then
        scp -q "$SCRIPT_DIR/ai_home/config.sh" "$SERVER:~/ai_home/config.sh"
        log_info "config.sh (new file)"
    else
        log_skip "config.sh"
    fi
fi

# Step 3: Initialize or reset state
if [ "$RESET_STATE" = true ]; then
    log_step "Resetting agent state..."
    
    # Stop any running sessions
    ssh -n "$SERVER" "pkill -f '[m]ini --config' 2>/dev/null || true; rm -f ~/ai_home/state/session.lock"
    log_info "Stopped running sessions"
    
    # Reset all state, logs, and agent-created content
    ssh -n "$SERVER" "
        # State files - reset to clean defaults
        echo '0' > ~/ai_home/state/session_counter.txt
        echo '(no previous session)' > ~/ai_home/state/last_session.md
        echo '(no plan yet)' > ~/ai_home/state/current_plan.md
        rm -f ~/ai_home/state/external_messages.md
        rm -f ~/ai_home/state/last_sessions_hash.txt
        rm -f ~/ai_home/state/last_exit_code.txt
        rm -f ~/ai_home/state/cb_injected.flag
        rm -f ~/ai_home/state/last_session_interrupted_by_limits.txt
        rm -f ~/ai_home/state/session.lock
        
        # State subdirectories
        rm -rf ~/ai_home/state/session_archives/*
        rm -rf ~/ai_home/state/visualization/*
        
        # Logs - wipe everything and recreate clean files
        rm -rf ~/ai_home/logs/*
        echo '# AI History Log' > ~/ai_home/logs/history.md
        echo '# Consolidated History' > ~/ai_home/logs/consolidated_history.md
        
        # Agent-created content
        rm -rf ~/ai_home/knowledge/*
        rm -rf ~/ai_home/projects/*
        rm -rf ~/ai_home/tools/*
        
        # Old backups
        rm -f ~/ai_home/*.backup.*
        rm -f ~/run_ai.sh.backup.*
        
        # Agent-created scripts/files in ~/ai_home/ root (NOT subdirs, NOT core files)
        # Core files (SYSTEM_PROMPT.md, config.sh) are handled by --force deploy above
        find ~/ai_home -maxdepth 1 -type f \
            ! -name 'SYSTEM_PROMPT.md' \
            ! -name 'config.sh' \
            -delete 2>/dev/null || true

        # Agent-created files scattered in live-swe-agent/
        # Remove known patterns + any leftover temp configs from aborted sessions
        rm -f ~/live-swe-agent/hello.py ~/live-swe-agent/test.py
        rm -f ~/live-swe-agent/test_weather.sh ~/live-swe-agent/weather_moscow.sh
        rm -f ~/live-swe-agent/story_seeds_*.json
        rm -f ~/live-swe-agent/config/ai_agent_openrouter_tmp_*.yaml
        # Remove any other .py .sh .json .txt .md files the agent may have dropped here
        find ~/live-swe-agent -maxdepth 1 -type f \
            \( -name '*.py' -o -name '*.sh' -o -name '*.json' -o -name '*.txt' -o -name '*.md' \) \
            -delete 2>/dev/null || true

        # Old mini-swe-agent history and trajectory (could influence new agent)
        rm -f ~/.config/mini-swe-agent/interactive_history.txt
        rm -f ~/.config/mini-swe-agent/.env.backup
        rm -f ~/.config/mini-swe-agent/last_mini_run.traj.json
        # Also wipe any other traj/history files (json, txt) that may have accumulated
        find ~/.config/mini-swe-agent -maxdepth 1 -type f \
            \( -name '*.json' -o -name '*.txt' \) \
            ! -name '.env*' \
            -delete 2>/dev/null || true
    "
    log_info "State reset to session 0 (logs, archives, backups, artifacts cleaned)"
else
    # Just ensure state files exist (don't overwrite)
    log_step "Ensuring state files exist..."
    ssh -n "$SERVER" "
        [ -f ~/ai_home/state/session_counter.txt ] || echo '0' > ~/ai_home/state/session_counter.txt
        [ -f ~/ai_home/state/last_session.md ] || echo '(no previous session)' > ~/ai_home/state/last_session.md
        [ -f ~/ai_home/state/current_plan.md ] || echo '(no plan yet)' > ~/ai_home/state/current_plan.md
        [ -f ~/ai_home/logs/history.md ] || echo '# AI History Log' > ~/ai_home/logs/history.md
        [ -f ~/ai_home/logs/consolidated_history.md ] || echo '# Consolidated History' > ~/ai_home/logs/consolidated_history.md
    "
    log_info "State files ready"
fi

# Step 4: Clean up old Qwen artifacts on server
log_step "Cleaning up old artifacts..."
ssh -n "$SERVER" "
    rm -f ~/sync-qwen-token.sh 2>/dev/null || true
    rm -f ~/refresh-token.sh 2>/dev/null || true
    rm -f ~/live-swe-agent/config/ai_agent.yaml 2>/dev/null || true
" 2>/dev/null || true
log_info "Old Qwen artifacts removed"

# Step 5: Show status
show_status

# Warnings and tips
if [ "$FORCE_MODE" = false ]; then
    echo ""
    echo "Note: Agent-modifiable files were preserved. Use --force to overwrite them."
fi

echo ""
log_info "Deployment complete!"
echo ""
echo "Next steps:"
echo "  1. Ensure OpenRouter is configured: ssh $SERVER '~/setup-openrouter.sh'"
echo "  2. Set up schedule: ./set-schedule.sh 15   (wake up every 15 minutes)"
