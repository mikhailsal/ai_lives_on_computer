#!/bin/bash
#
# set-schedule.sh - Set the AI agent's wake-up frequency on the server
#
# Usage:
#   ./set-schedule.sh 15          # Wake up every 15 minutes
#   ./set-schedule.sh 60          # Wake up every hour
#   ./set-schedule.sh --stop      # Disable the schedule (remove cron job)
#   ./set-schedule.sh --status    # Show current schedule
#   ./set-schedule.sh --help      # Show help
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
    echo "Usage: $0 <MINUTES | --stop | --status>"
    echo ""
    echo "Set how often the AI agent wakes up on the server."
    echo ""
    echo "Arguments:"
    echo "  MINUTES     Wake-up interval in minutes (1-1440)"
    echo "              Common values: 15, 30, 60"
    echo ""
    echo "Options:"
    echo "  --stop      Disable the schedule (remove cron job)"
    echo "  --status    Show current schedule without changing anything"
    echo "  --help      Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 15       # Every 15 minutes"
    echo "  $0 60       # Every hour"
    echo "  $0 5        # Every 5 minutes (aggressive)"
    echo "  $0 --stop   # Pause the agent"
    echo ""
    echo "This command will:"
    echo "  1. Install/update the cron job on the server"
    echo "  2. Update SESSION_INTERVAL_MINUTES in ~/ai_home/config.sh"
    echo "  3. Adjust SESSION_TIMEOUT_SECONDS accordingly"
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

    CRON_LINE=$(ssh "$SERVER" "crontab -l 2>/dev/null | grep 'run_ai\.sh' || true")
    CONFIG_INTERVAL=$(ssh "$SERVER" "grep '^SESSION_INTERVAL_MINUTES=' ~/ai_home/config.sh 2>/dev/null | cut -d'=' -f2 || echo 'not set'")
    CONFIG_TIMEOUT=$(ssh "$SERVER" "grep '^SESSION_TIMEOUT_SECONDS=' ~/ai_home/config.sh 2>/dev/null | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' ' || echo 'not set'")

    echo ""
    echo "========================================"
    echo "   AI Agent Schedule"
    echo "========================================"
    echo ""
    if [ -n "$CRON_LINE" ]; then
        echo "  Cron job:     ${CRON_LINE}"
        echo "  Config interval: ${CONFIG_INTERVAL} minutes"
        echo "  Config timeout:  ${CONFIG_TIMEOUT} seconds"
        echo ""
        log_info "Agent is ACTIVE"
    else
        echo "  Cron job:     (not set)"
        echo "  Config interval: ${CONFIG_INTERVAL} minutes"
        echo "  Config timeout:  ${CONFIG_TIMEOUT} seconds"
        echo ""
        log_warn "Agent is STOPPED (no cron job)"
    fi
    echo ""
}

stop_schedule() {
    check_connection

    log_step "Removing AI agent cron job..."

    # Remove any line containing run_ai.sh from crontab
    ssh "$SERVER" "crontab -l 2>/dev/null | grep -v 'run_ai\.sh' | crontab - 2>/dev/null || true"

    # Verify
    REMAINING=$(ssh "$SERVER" "crontab -l 2>/dev/null | grep 'run_ai\.sh' || true")
    if [ -z "$REMAINING" ]; then
        log_info "Cron job removed. Agent will no longer wake up automatically."
    else
        log_error "Failed to remove cron job"
        exit 1
    fi
}

set_schedule() {
    local minutes="$1"

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

    local cron_line="${cron_expr} ~/run_ai.sh >> ~/ai_home/logs/cron.log 2>&1"

    # Calculate timeout (2x the interval, minimum 5 minutes)
    local timeout_seconds=$((minutes * 2 * 60))
    if [ "$timeout_seconds" -lt 300 ]; then
        timeout_seconds=300
    fi

    echo ""
    echo "========================================"
    echo "   Setting AI Agent Schedule"
    echo "========================================"
    echo ""
    echo "  Interval:  every ${minutes} minutes"
    echo "  Cron:      ${cron_expr}"
    echo "  Timeout:   ${timeout_seconds} seconds ($((timeout_seconds / 60)) min)"
    echo ""

    # Step 1: Update crontab
    log_step "Updating cron job..."

    # Remove old run_ai.sh entries and add the new one
    ssh "$SERVER" "
        (crontab -l 2>/dev/null | grep -v 'run_ai\.sh'; echo '${cron_line}') | crontab -
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
        fi
    "
    log_info "config.sh updated (interval=${minutes}m, timeout=${timeout_seconds}s)"

    # Step 3: Verify
    log_step "Verifying..."

    INSTALLED=$(ssh "$SERVER" "crontab -l 2>/dev/null | grep 'run_ai\.sh' || true")
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
        set_schedule "$1"
        ;;
esac
