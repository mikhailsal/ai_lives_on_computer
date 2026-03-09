#!/bin/bash
#
# run_ai_watchdog.sh — Self-healing wrapper for run_ai.sh
#
# This script is called by cron instead of run_ai.sh directly.
# It provides automatic rollback protection: if run_ai.sh fails
# 3 times in a row (for ANY reason — syntax error, missing function,
# broken dependency, etc.), the watchdog will:
#   1. Swap in the last known-good backup of run_ai.sh
#   2. Reset the failure counter
#   3. Log what happened
#
# On every successful run, it saves a "golden" backup of run_ai.sh
# so there's always a working version to fall back to.
#
# IMPORTANT: This script is intentionally simple and self-contained.
# It should NOT be modified by the agent. If the agent modifies this
# file, the protection is lost.
#

set -o pipefail

#############################################
# CONFIGURATION (hardcoded on purpose)
#############################################

MAIN_SCRIPT="$HOME/run_ai.sh"
GOLDEN_BACKUP="$HOME/.run_ai.golden.sh"
STATE_DIR="$HOME/ai_home/state"
LOG_FILE="$HOME/ai_home/logs/watchdog.log"
FAIL_COUNTER_FILE="$STATE_DIR/watchdog_consecutive_failures.txt"
MAX_CONSECUTIVE_FAILURES=3

#############################################
# LOGGING
#############################################

log() {
    echo "[$(date +"%Y-%m-%dT%H:%M:%S%z")] $1" >> "$LOG_FILE"
}

#############################################
# ENSURE DIRECTORIES EXIST
#############################################

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

#############################################
# READ FAILURE COUNTER
#############################################

if [ -f "$FAIL_COUNTER_FILE" ]; then
    FAIL_COUNT=$(cat "$FAIL_COUNTER_FILE" 2>/dev/null || echo "0")
    # Sanitize: must be a number
    if ! [[ "$FAIL_COUNT" =~ ^[0-9]+$ ]]; then
        FAIL_COUNT=0
    fi
else
    FAIL_COUNT=0
fi

#############################################
# CHECK IF ROLLBACK IS NEEDED
#############################################

if [ "$FAIL_COUNT" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
    log "WATCHDOG: $FAIL_COUNT consecutive failures detected (threshold: $MAX_CONSECUTIVE_FAILURES)"

    if [ -f "$GOLDEN_BACKUP" ]; then
        log "WATCHDOG: Rolling back run_ai.sh to last known-good version"
        
        # Save the broken version for forensics
        cp "$MAIN_SCRIPT" "${MAIN_SCRIPT}.broken_$(date +%s)" 2>/dev/null
        
        # Restore from golden backup
        cp "$GOLDEN_BACKUP" "$MAIN_SCRIPT"
        chmod +x "$MAIN_SCRIPT"
        
        # Reset counter
        echo "0" > "$FAIL_COUNTER_FILE"
        FAIL_COUNT=0
        
        log "WATCHDOG: Rollback complete. Broken version saved. Resuming with golden backup."
        
        # Write a note to external_messages so the agent knows what happened
        {
            echo ""
            echo "---"
            echo ""
            echo "## Watchdog Auto-Recovery ($(date '+%Y-%m-%d %H:%M UTC'))"
            echo ""
            echo "Your run_ai.sh failed $MAX_CONSECUTIVE_FAILURES times in a row."
            echo "The watchdog has automatically restored the last known-good version."
            echo "The broken version was saved for your review."
            echo "Check ~/ai_home/logs/watchdog.log for details."
            echo ""
        } >> "$HOME/ai_home/state/external_messages.md"
    else
        log "WATCHDOG: CRITICAL — No golden backup exists! Cannot rollback. Manual intervention needed."
        log "WATCHDOG: Resetting counter and trying current script anyway."
        echo "0" > "$FAIL_COUNTER_FILE"
        FAIL_COUNT=0
    fi
fi

#############################################
# SYNTAX PRE-CHECK
# Catch obvious script corruption before running
#############################################

if ! bash -n "$MAIN_SCRIPT" 2>/dev/null; then
    log "WATCHDOG: SYNTAX ERROR detected in run_ai.sh! Incrementing failure counter without running."
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "$FAIL_COUNT" > "$FAIL_COUNTER_FILE"
    log "WATCHDOG: Consecutive failures: $FAIL_COUNT/$MAX_CONSECUTIVE_FAILURES"
    exit 1
fi

#############################################
# RUN THE MAIN SCRIPT
#############################################

log "WATCHDOG: Starting run_ai.sh (consecutive failures so far: $FAIL_COUNT)"

bash "$MAIN_SCRIPT" >> "$HOME/ai_home/logs/cron.log" 2>&1
EXIT_CODE=$?

#############################################
# EVALUATE RESULT
#############################################

if [ "$EXIT_CODE" -eq 0 ]; then
    # Success! Reset counter and save golden backup
    if [ "$FAIL_COUNT" -gt 0 ]; then
        log "WATCHDOG: Session succeeded after $FAIL_COUNT previous failure(s). Counter reset."
    fi
    echo "0" > "$FAIL_COUNTER_FILE"
    
    # Save this working version as the golden backup
    cp "$MAIN_SCRIPT" "$GOLDEN_BACKUP"
    chmod +x "$GOLDEN_BACKUP"
    
    log "WATCHDOG: Session completed successfully (exit 0). Golden backup updated."
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "$FAIL_COUNT" > "$FAIL_COUNTER_FILE"
    log "WATCHDOG: Session FAILED (exit $EXIT_CODE). Consecutive failures: $FAIL_COUNT/$MAX_CONSECUTIVE_FAILURES"
    
    if [ "$FAIL_COUNT" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
        log "WATCHDOG: Threshold reached! Next run will trigger automatic rollback."
    fi
fi

exit $EXIT_CODE
