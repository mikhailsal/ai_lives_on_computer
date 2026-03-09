#!/bin/bash
#
# set-schedule.sh - Set the AI agent's wake-up frequency on the server
#
# Usage:
#   ./set-schedule.sh 15                                # Wake up every 15 minutes
#   ./set-schedule.sh 10 --steps 80 --timeout 1800     # Custom limits
#   ./set-schedule.sh 15 --cost-limit 0.50             # Cost limit in USD
#   ./set-schedule.sh --stop                            # Disable the schedule (remove cron job)
#   ./set-schedule.sh --status                          # Show current schedule
#   ./set-schedule.sh --help                            # Show help
#

set -e

SERVER="debian"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
log_error() { echo -e "${RED}[ERR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}==>${NC} $1"; }

show_help() {
    echo "Usage: $0 <MINUTES> [--steps N] [--timeout SECONDS] [--cost-limit USD]"
    echo "       $0 --stop | --status | --help"
    echo ""
    echo "Set how often the AI agent wakes up on the server."
    echo ""
    echo "Arguments:"
    echo "  MINUTES           Wake-up interval in minutes (1-1440)"
    echo "              Common values: 15, 30, 60"
    echo "  --steps N         Max agent steps per session (1-1000)"
    echo "  --timeout SEC     Session timeout in seconds (60-86400)"
    echo "  --cost-limit USD  Max USD cost per session (e.g. 0, 0.25, 1.50)"
    echo "                    If omitted, existing server values are preserved."
    echo ""
    echo "Options:"
    echo "  --stop      Disable the schedule (remove cron job)"
    echo "  --status    Show current schedule without changing anything"
    echo "  --help      Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 15                           # Every 15 minutes"
    echo "  $0 60                           # Every hour"
    echo "  $0 5 --steps 120 --timeout 1800 # Aggressive + higher limits"
    echo "  $0 10 --cost-limit 0.50         # Add session cost guardrail"
    echo "  $0 --stop                       # Pause the agent"
    echo ""
    echo "This command will:"
    echo "  1. Install/update the cron job on the server"
    echo "  2. Update SESSION_INTERVAL_MINUTES in ~/ai_home/config.sh"
    echo "  3. Update runtime limits in ~/ai_home/config.sh"
    echo "  4. Update step_limit/cost_limit in ~/live-swe-agent/config/ai_agent_openrouter.yaml"
}

check_connection() {
    log_step "Checking server connectivity..."
    if ! ssh -o ConnectTimeout=5 "$SERVER" "echo 'OK'" > /dev/null 2>&1; then
        log_error "Cannot connect to server '$SERVER'"
        exit 1
    fi
    log_info "Connected to $SERVER"
}

show_status() {
    check_connection

    log_step "Current Schedule"

    CRON_LINE=$(ssh "$SERVER" "crontab -l 2>/dev/null | grep 'run_ai' || true")
    CONFIG_INTERVAL=$(ssh "$SERVER" "grep '^SESSION_INTERVAL_MINUTES=' ~/ai_home/config.sh 2>/dev/null | cut -d'=' -f2 || echo 'not set'")
    CONFIG_TIMEOUT=$(ssh "$SERVER" "grep '^SESSION_TIMEOUT_SECONDS=' ~/ai_home/config.sh 2>/dev/null | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || echo 'not set'")
    CONFIG_STEPS=$(ssh "$SERVER" "grep '^MAX_STEPS=' ~/ai_home/config.sh 2>/dev/null | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || echo 'not set'")
    CONFIG_COST=$(ssh "$SERVER" "grep '^COST_LIMIT=' ~/ai_home/config.sh 2>/dev/null | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || echo 'not set'")
    YAML_STEPS=$(ssh "$SERVER" "grep '^  step_limit:' ~/live-swe-agent/config/ai_agent_openrouter.yaml 2>/dev/null | awk '{print \$2}' || echo 'not set'")
    YAML_COST=$(ssh "$SERVER" "grep '^  cost_limit:' ~/live-swe-agent/config/ai_agent_openrouter.yaml 2>/dev/null | awk '{print \$2}' || echo 'not set'")

    echo ""
    echo "========================================"
    echo "   AI Agent Schedule"
    echo "========================================"
    echo ""
    if [ -n "$CRON_LINE" ]; then
        echo "  Cron job:     ${CRON_LINE}"
        echo "  Config interval: ${CONFIG_INTERVAL} minutes"
        echo "  Config timeout:  ${CONFIG_TIMEOUT} seconds"
        echo "  Config steps:    ${CONFIG_STEPS}"
        echo "  Config cost:     ${CONFIG_COST}"
        echo "  YAML step_limit: ${YAML_STEPS}"
        echo "  YAML cost_limit: ${YAML_COST}"
        echo ""
        log_info "Agent is ACTIVE"
    else
        echo "  Cron job:     (not set)"
        echo "  Config interval: ${CONFIG_INTERVAL} minutes"
        echo "  Config timeout:  ${CONFIG_TIMEOUT} seconds"
        echo "  Config steps:    ${CONFIG_STEPS}"
        echo "  Config cost:     ${CONFIG_COST}"
        echo "  YAML step_limit: ${YAML_STEPS}"
        echo "  YAML cost_limit: ${YAML_COST}"
        echo ""
        log_warn "Agent is STOPPED (no cron job)"
    fi
    echo ""
}

stop_schedule() {
    check_connection

    log_step "Removing AI agent cron job..."

    # Remove any line containing run_ai from crontab
    ssh "$SERVER" "crontab -l 2>/dev/null | grep -v 'run_ai' | crontab - 2>/dev/null || true"

    # Verify
    REMAINING=$(ssh "$SERVER" "crontab -l 2>/dev/null | grep 'run_ai' || true")
    if [ -z "$REMAINING" ]; then
        log_info "Cron job removed. Agent will no longer wake up automatically."
    else
        log_error "Failed to remove cron job"
        exit 1
    fi
}

set_schedule() {
    local minutes="$1"
    shift
    local timeout_seconds=""
    local max_steps=""
    local cost_limit=""

    # Optional args parser
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout)
                timeout_seconds="$2"
                shift 2
                ;;
            --steps)
                max_steps="$2"
                shift 2
                ;;
            --cost-limit)
                cost_limit="$2"
                shift 2
                ;;
            *)
                log_error "Unknown argument: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Validate input
    if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
        log_error "Invalid number: $minutes"
        echo "Please provide a number of minutes (1-1440)"
        exit 1
    fi

    if [ "$minutes" -lt 1 ] || [ "$minutes" -gt 1440 ]; then
        log_error "Minutes must be between 1 and 1440 (24 hours)"
        exit 1
    fi

    check_connection

    # Read existing values from server (used when optional args are omitted)
    local existing_timeout
    local existing_steps
    local existing_cost
    existing_timeout=$(ssh "$SERVER" "grep '^SESSION_TIMEOUT_SECONDS=' ~/ai_home/config.sh 2>/dev/null | head -1 | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || true")
    existing_steps=$(ssh "$SERVER" "grep '^MAX_STEPS=' ~/ai_home/config.sh 2>/dev/null | head -1 | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || true")
    existing_cost=$(ssh "$SERVER" "grep '^COST_LIMIT=' ~/ai_home/config.sh 2>/dev/null | head -1 | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || true")

    # Build cron expression
    local cron_expr
    if [ "$minutes" -lt 60 ]; then
        # Every N minutes
        cron_expr="*/${minutes} * * * *"
    elif [ "$minutes" -eq 60 ]; then
        # Every hour
        cron_expr="0 * * * *"
    elif [ "$minutes" -eq 1440 ]; then
        # Once a day (midnight)
        cron_expr="0 0 * * *"
    elif [ $((minutes % 60)) -eq 0 ]; then
        # Every N hours (exact)
        local hours=$((minutes / 60))
        cron_expr="0 */${hours} * * *"
    else
        # Fallback: every N minutes for non-round values
        cron_expr="*/${minutes} * * * *"
    fi

    local cron_line="${cron_expr} ~/run_ai_watchdog.sh >> ~/ai_home/logs/cron.log 2>&1"

    # If timeout is omitted, preserve existing value; otherwise compute fallback.
    if [ -z "$timeout_seconds" ]; then
        if [[ "$existing_timeout" =~ ^[0-9]+$ ]]; then
            timeout_seconds="$existing_timeout"
        else
            timeout_seconds=$((minutes * 2 * 60))
            if [ "$timeout_seconds" -lt 300 ]; then
                timeout_seconds=300
            fi
        fi
    fi

    # If steps are omitted, preserve existing value.
    if [ -z "$max_steps" ]; then
        if [[ "$existing_steps" =~ ^[0-9]+$ ]]; then
            max_steps="$existing_steps"
        else
            max_steps=25
        fi
    fi

    # If cost limit is omitted, preserve existing value.
    if [ -z "$cost_limit" ]; then
        if [[ "$existing_cost" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            cost_limit="$existing_cost"
        else
            cost_limit=0
        fi
    fi

    # Validate timeout
    if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [ "$timeout_seconds" -lt 60 ] || [ "$timeout_seconds" -gt 86400 ]; then
        log_error "Timeout must be an integer between 60 and 86400 seconds"
        exit 1
    fi

    # Validate steps
    if ! [[ "$max_steps" =~ ^[0-9]+$ ]] || [ "$max_steps" -lt 1 ] || [ "$max_steps" -gt 1000 ]; then
        log_error "Step limit must be an integer between 1 and 1000"
        exit 1
    fi

    # Validate cost_limit
    if ! [[ "$cost_limit" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_error "Cost limit must be a non-negative number (e.g. 0, 0.25, 1.50)"
        exit 1
    fi

    echo ""
    echo "========================================"
    echo "   Setting AI Agent Schedule"
    echo "========================================"
    echo ""
    echo "  Interval:  every ${minutes} minutes"
    echo "  Cron:      ${cron_expr}"
    echo "  Timeout:   ${timeout_seconds} seconds ($((timeout_seconds / 60)) min)"
    echo "  Steps:     ${max_steps}"
    echo "  Cost limit:${cost_limit}"
    echo ""

    # Step 1: Update crontab
    log_step "Updating cron job..."

    # Remove old run_ai entries and add the new one
    ssh "$SERVER" "
        (crontab -l 2>/dev/null | grep -v 'run_ai'; echo '${cron_line}') | crontab -
    "
    log_info "Cron job installed: ${cron_expr}"

    # Step 2: Update config.sh on the server
    log_step "Updating config.sh on server..."

    ssh "$SERVER" "
        if [ -f ~/ai_home/config.sh ]; then
            # Update SESSION_INTERVAL_MINUTES
            if grep -q '^SESSION_INTERVAL_MINUTES=' ~/ai_home/config.sh; then
                sed -i 's/^SESSION_INTERVAL_MINUTES=.*/SESSION_INTERVAL_MINUTES=${minutes}/' ~/ai_home/config.sh
            else
                echo 'SESSION_INTERVAL_MINUTES=${minutes}' >> ~/ai_home/config.sh
            fi

            # Update SESSION_TIMEOUT_SECONDS
            if grep -q '^SESSION_TIMEOUT_SECONDS=' ~/ai_home/config.sh; then
                sed -i 's/^SESSION_TIMEOUT_SECONDS=.*/SESSION_TIMEOUT_SECONDS=${timeout_seconds}  # $((timeout_seconds / 60)) minutes/' ~/ai_home/config.sh
            else
                echo 'SESSION_TIMEOUT_SECONDS=${timeout_seconds}  # $((timeout_seconds / 60)) minutes' >> ~/ai_home/config.sh
            fi

            # Update MAX_STEPS
            if grep -q '^MAX_STEPS=' ~/ai_home/config.sh; then
                sed -i 's/^MAX_STEPS=.*/MAX_STEPS=${max_steps}/' ~/ai_home/config.sh
            else
                echo 'MAX_STEPS=${max_steps}' >> ~/ai_home/config.sh
            fi

            # Update COST_LIMIT
            if grep -q '^COST_LIMIT=' ~/ai_home/config.sh; then
                sed -i 's/^COST_LIMIT=.*/COST_LIMIT=${cost_limit}/' ~/ai_home/config.sh
            else
                echo 'COST_LIMIT=${cost_limit}' >> ~/ai_home/config.sh
            fi
        fi
    "
    log_info "config.sh updated (interval=${minutes}m, timeout=${timeout_seconds}s, steps=${max_steps}, cost=${cost_limit})"

    # Step 3: Update YAML runtime limits
    log_step "Updating ai_agent_openrouter.yaml limits on server..."
    ssh "$SERVER" "
        if [ -f ~/live-swe-agent/config/ai_agent_openrouter.yaml ]; then
            if grep -q '^  step_limit:' ~/live-swe-agent/config/ai_agent_openrouter.yaml; then
                sed -i 's/^  step_limit:.*/  step_limit: ${max_steps}/' ~/live-swe-agent/config/ai_agent_openrouter.yaml
            else
                printf '\nagent:\n  step_limit: ${max_steps}\n' >> ~/live-swe-agent/config/ai_agent_openrouter.yaml
            fi

            if grep -q '^  cost_limit:' ~/live-swe-agent/config/ai_agent_openrouter.yaml; then
                sed -i 's/^  cost_limit:.*/  cost_limit: ${cost_limit}/' ~/live-swe-agent/config/ai_agent_openrouter.yaml
            else
                sed -i '/^  step_limit:/a\  cost_limit: ${cost_limit}' ~/live-swe-agent/config/ai_agent_openrouter.yaml
            fi
        fi
    "
    log_info "YAML updated (step_limit=${max_steps}, cost_limit=${cost_limit})"

    # Step 4: Verify
    log_step "Verifying..."

    INSTALLED=$(ssh "$SERVER" "crontab -l 2>/dev/null | grep 'run_ai' || true")
    if [ -n "$INSTALLED" ]; then
        log_info "Schedule is active!"
        echo ""
        echo "  Installed cron: ${INSTALLED}"
        echo ""
        echo "  The agent will wake up every ${minutes} minutes."
        echo "  Logs: ssh $SERVER 'tail -f ~/ai_home/logs/cron.log'"
    else
        log_error "Verification failed - cron job not found"
        exit 1
    fi

    echo ""
}

#############################################
# MAIN
#############################################

if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

case "$1" in
    --help|-h)
        show_help
        exit 0
        ;;
    --status)
        show_status
        exit 0
        ;;
    --stop)
        stop_schedule
        exit 0
        ;;
    *)
        set_schedule "$@"
        ;;
esac
