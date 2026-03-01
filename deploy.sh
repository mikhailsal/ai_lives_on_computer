#!/bin/bash
#
# Deploy AI Agent to server
# This script deploys configuration files to the remote server
#
# IMPORTANT: This script respects files the agent may have modified!
# Files in ~/ai_home/ that the agent can edit are NEVER overwritten.
#
# Usage:
#   ./deploy.sh                    # Deploy new/safe files only (respects agent edits)
#   ./deploy.sh --openrouter       # Deploy OpenRouter support files only
#   ./deploy.sh --force            # Force overwrite ALL files (DANGER: destroys agent edits!)
#   ./deploy.sh --reset            # Full reset (fresh session 1, destroys everything)
#   ./deploy.sh --sync-token       # Just sync OAuth token to agent config
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

log_info() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }
log_step() { echo -e "\n${GREEN}==>${NC} $1"; }
log_skip() { echo -e "${BLUE}→${NC} $1 (skipped - agent may have modified)"; }

# Parse arguments
FORCE_MODE=false
RESET_STATE=false
SYNC_TOKEN_ONLY=false
STATUS_ONLY=false
OPENROUTER_ONLY=false

for arg in "$@"; do
    case $arg in
        --force)
            FORCE_MODE=true
            ;;
        --reset)
            RESET_STATE=true
            FORCE_MODE=true  # Reset implies force
            ;;
        --sync-token)
            SYNC_TOKEN_ONLY=true
            ;;
        --status)
            STATUS_ONLY=true
            ;;
        --openrouter)
            OPENROUTER_ONLY=true
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (none)          Safe deploy - only new files, respects agent modifications"
            echo "  --openrouter    Deploy only OpenRouter support files (safe)"
            echo "  --status        Show server status without deploying anything"
            echo "  --sync-token    Just sync OAuth token to agent config"
            echo "  --force         Force overwrite ALL files (DANGER: destroys agent edits!)"
            echo "  --reset         Full reset - fresh start from session 1 (DANGER!)"
            echo "  --help          Show this help"
            echo ""
            echo "Files the agent can modify (protected by default):"
            echo "  ~/ai_home/SYSTEM_PROMPT.md  - Agent's self-modifiable instructions"
            echo "  ~/ai_home/config.sh         - Agent's configuration"
            echo "  ~/run_ai.sh                 - Runner script (agent could modify)"
            echo ""
            echo "Files always safe to update:"
            echo "  ~/live-swe-agent/config/*.yaml  - mini-swe-agent configs"
            echo "  ~/setup-openrouter.sh           - Setup scripts"
            echo "  ~/sync-qwen-token.sh            - Token sync script"
            exit 0
            ;;
    esac
done

echo "========================================"
echo "   AI Agent Deployment Script"
echo "========================================"

# Check SSH connectivity first
log_step "Checking server connectivity..."
if ! ssh -o ConnectTimeout=5 "$SERVER" "echo 'OK'" > /dev/null 2>&1; then
    log_error "Cannot connect to server '$SERVER'"
    exit 1
fi
log_info "Connected to $SERVER"

#############################################
# STATUS ONLY MODE
#############################################

show_status() {
    log_step "Server Status"
    
    SESSION_COUNTER=$(ssh "$SERVER" "cat ~/ai_home/state/session_counter.txt 2>/dev/null || echo 'N/A'")
    CRON=$(ssh "$SERVER" "crontab -l 2>/dev/null | grep run_ai | head -1 || echo 'not set'")
    TOKEN=$(ssh "$SERVER" "[ -f ~/.qwen/oauth_creds.json ] && echo 'present' || echo 'missing'")
    AGENT_CONFIG=$(ssh "$SERVER" "[ -f ~/.config/mini-swe-agent/.env ] && echo 'present' || echo 'missing'")
    OPENROUTER_CONFIG=$(ssh "$SERVER" "[ -f ~/.config/mini-swe-agent/.env.openrouter ] && echo 'present' || echo 'not configured'")
    PROMPT_MODIFIED=$(ssh "$SERVER" "grep -q 'modified by' ~/ai_home/SYSTEM_PROMPT.md 2>/dev/null && echo 'YES (agent modified)' || echo 'no'")
    
    echo ""
    echo "========================================"
    echo "   Server Status"
    echo "========================================"
    echo ""
    echo "  Session counter:      $SESSION_COUNTER"
    echo "  Cron job:             $CRON"
    echo "  Qwen token:           $TOKEN"
    echo "  Qwen agent config:    $AGENT_CONFIG"
    echo "  OpenRouter config:    $OPENROUTER_CONFIG"
    echo "  SYSTEM_PROMPT edited: $PROMPT_MODIFIED"
    echo ""
}

if [ "$STATUS_ONLY" = true ]; then
    show_status
    exit 0
fi

# Sync token only mode
if [ "$SYNC_TOKEN_ONLY" = true ]; then
    log_step "Syncing OAuth token..."
    ssh "$SERVER" "~/sync-qwen-token.sh --force" && log_info "Token synced" || log_error "Token sync failed"
    exit $?
fi

#############################################
# OPENROUTER ONLY MODE - Safe deployment
#############################################

if [ "$OPENROUTER_ONLY" = true ]; then
    log_step "Deploying OpenRouter support files only..."
    
    # These files are NEW and don't exist on the agent's system
    # or are in locations the agent doesn't typically modify
    
    # OpenRouter agent config (new file, safe location)
    scp -q "$SCRIPT_DIR/config/ai_agent_openrouter.yaml" "$SERVER:~/live-swe-agent/config/ai_agent_openrouter.yaml"
    log_info "ai_agent_openrouter.yaml (new file)"
    
    # OpenRouter setup script (new file)
    scp -q "$SCRIPT_DIR/setup-openrouter.sh" "$SERVER:~/setup-openrouter.sh"
    ssh "$SERVER" "chmod +x ~/setup-openrouter.sh"
    log_info "setup-openrouter.sh (new file)"
    
    # Update run_ai.sh ONLY if agent hasn't modified it
    # Check by comparing a key function that wouldn't be there in old versions
    HAS_OPENROUTER=$(ssh "$SERVER" "grep -q 'run_with_openrouter' ~/run_ai.sh 2>/dev/null && echo 'yes' || echo 'no'")
    
    if [ "$HAS_OPENROUTER" = "no" ]; then
        # Backup the current version first
        ssh "$SERVER" "cp ~/run_ai.sh ~/run_ai.sh.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true"
        scp -q "$SCRIPT_DIR/run_ai.sh" "$SERVER:~/run_ai.sh"
        ssh "$SERVER" "chmod +x ~/run_ai.sh"
        log_info "run_ai.sh (updated with OpenRouter support, backup created)"
    else
        log_info "run_ai.sh already has OpenRouter support"
    fi
    
    echo ""
    log_info "OpenRouter deployment complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Get API key from: https://openrouter.ai/keys"
    echo "  2. Run: ssh $SERVER '~/setup-openrouter.sh YOUR_API_KEY'"
    echo "  3. Add to ~/ai_home/config.sh: OPENROUTER_MODEL=\"meta-llama/llama-3.3-70b-instruct:free\""
    echo "  4. Update cron: ~/run_ai.sh openrouter"
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
ssh "$SERVER" "mkdir -p ~/ai_home/{state,logs,knowledge,projects,tools}"
ssh "$SERVER" "mkdir -p ~/live-swe-agent/config"
log_info "Directories created"

# Step 2: Deploy files
log_step "Deploying files..."

# === SAFE FILES (always deploy - agent doesn't modify these) ===

# mini-swe-agent configs (in live-swe-agent directory, not ai_home)
scp -q "$SCRIPT_DIR/config/ai_agent.yaml" "$SERVER:~/live-swe-agent/config/ai_agent.yaml"
log_info "ai_agent.yaml"

scp -q "$SCRIPT_DIR/config/ai_agent_openrouter.yaml" "$SERVER:~/live-swe-agent/config/ai_agent_openrouter.yaml"
log_info "ai_agent_openrouter.yaml"

# Setup/utility scripts (agent typically doesn't modify these)
scp -q "$SCRIPT_DIR/setup-openrouter.sh" "$SERVER:~/setup-openrouter.sh"
ssh "$SERVER" "chmod +x ~/setup-openrouter.sh"
log_info "setup-openrouter.sh"

scp -q "$SCRIPT_DIR/sync-qwen-token.sh" "$SERVER:~/sync-qwen-token.sh"
ssh "$SERVER" "chmod +x ~/sync-qwen-token.sh"
log_info "sync-qwen-token.sh"

# === AGENT-MODIFIABLE FILES (only deploy if --force or file doesn't exist) ===

if [ "$FORCE_MODE" = true ]; then
    # Force mode - overwrite everything (with backups)
    log_step "Force deploying agent-modifiable files (creating backups)..."
    
    BACKUP_SUFFIX=$(date +%Y%m%d_%H%M%S)
    
    # Backup and overwrite SYSTEM_PROMPT.md
    ssh "$SERVER" "[ -f ~/ai_home/SYSTEM_PROMPT.md ] && cp ~/ai_home/SYSTEM_PROMPT.md ~/ai_home/SYSTEM_PROMPT.md.backup.$BACKUP_SUFFIX || true"
    scp -q "$SCRIPT_DIR/SYSTEM_PROMPT.md" "$SERVER:~/ai_home/SYSTEM_PROMPT.md"
    log_info "SYSTEM_PROMPT.md (backup created)"
    
    # Backup and overwrite run_ai.sh
    ssh "$SERVER" "[ -f ~/run_ai.sh ] && cp ~/run_ai.sh ~/run_ai.sh.backup.$BACKUP_SUFFIX || true"
    scp -q "$SCRIPT_DIR/run_ai.sh" "$SERVER:~/run_ai.sh"
    ssh "$SERVER" "chmod +x ~/run_ai.sh"
    log_info "run_ai.sh (backup created)"
    
    # Backup and overwrite config.sh
    ssh "$SERVER" "[ -f ~/ai_home/config.sh ] && cp ~/ai_home/config.sh ~/ai_home/config.sh.backup.$BACKUP_SUFFIX || true"
    scp -q "$SCRIPT_DIR/ai_home/config.sh" "$SERVER:~/ai_home/config.sh"
    log_info "config.sh (backup created)"
else
    # Safe mode - only deploy if files don't exist
    log_step "Checking agent-modifiable files..."
    
    # SYSTEM_PROMPT.md - only if doesn't exist
    if ssh "$SERVER" "[ ! -f ~/ai_home/SYSTEM_PROMPT.md ]" 2>/dev/null; then
        scp -q "$SCRIPT_DIR/SYSTEM_PROMPT.md" "$SERVER:~/ai_home/SYSTEM_PROMPT.md"
        log_info "SYSTEM_PROMPT.md (new file)"
    else
        log_skip "SYSTEM_PROMPT.md"
    fi
    
    # run_ai.sh - only if doesn't exist
    if ssh "$SERVER" "[ ! -f ~/run_ai.sh ]" 2>/dev/null; then
        scp -q "$SCRIPT_DIR/run_ai.sh" "$SERVER:~/run_ai.sh"
        ssh "$SERVER" "chmod +x ~/run_ai.sh"
        log_info "run_ai.sh (new file)"
    else
        # Check if it needs OpenRouter update
        HAS_OPENROUTER=$(ssh "$SERVER" "grep -q 'run_with_openrouter' ~/run_ai.sh 2>/dev/null && echo 'yes' || echo 'no'")
        if [ "$HAS_OPENROUTER" = "no" ]; then
            log_warn "run_ai.sh exists but lacks OpenRouter support. Use --openrouter to update safely."
        else
            log_skip "run_ai.sh"
        fi
    fi
    
    # config.sh - only if doesn't exist
    if ssh "$SERVER" "[ ! -f ~/ai_home/config.sh ]" 2>/dev/null; then
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
    ssh "$SERVER" "pkill -f 'mini --config' 2>/dev/null || true; rm -f ~/ai_home/state/session.lock"
    log_info "Stopped running sessions"
    
    # Reset all state
    ssh "$SERVER" "
        echo '0' > ~/ai_home/state/session_counter.txt
        echo '(no previous session)' > ~/ai_home/state/last_session.md
        echo '(no plan yet)' > ~/ai_home/state/current_plan.md
        echo '# AI History Log' > ~/ai_home/logs/history.md
        echo '# Consolidated History' > ~/ai_home/logs/consolidated_history.md
        rm -f ~/ai_home/state/external_messages.md
        rm -f ~/ai_home/state/last_sessions_hash.txt
    "
    log_info "State reset to session 0"
else
    # Just ensure state files exist (don't overwrite)
    log_step "Ensuring state files exist..."
    ssh "$SERVER" "
        [ -f ~/ai_home/state/session_counter.txt ] || echo '0' > ~/ai_home/state/session_counter.txt
        [ -f ~/ai_home/state/last_session.md ] || echo '(no previous session)' > ~/ai_home/state/last_session.md
        [ -f ~/ai_home/state/current_plan.md ] || echo '(no plan yet)' > ~/ai_home/state/current_plan.md
        [ -f ~/ai_home/logs/history.md ] || echo '# AI History Log' > ~/ai_home/logs/history.md
        [ -f ~/ai_home/logs/consolidated_history.md ] || echo '# Consolidated History' > ~/ai_home/logs/consolidated_history.md
    "
    log_info "State files ready"
fi

# Step 4: Show status
show_status

# Warnings and tips
if [ "$FORCE_MODE" = false ]; then
    echo ""
    echo "Note: Agent-modifiable files were preserved. Use --force to overwrite them."
fi

echo ""
log_info "Deployment complete!"
