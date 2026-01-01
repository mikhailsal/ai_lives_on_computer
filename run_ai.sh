#!/bin/bash
#
# AI Autonomous Agent Runner
# This script runs the AI agent with the system prompt
# Designed to be called by cron at regular intervals
#
# Features:
# - Lock file prevents concurrent sessions
# - Stale lock detection (kills hung sessions after timeout)
# - Configurable session interval and timeout
#

# Exit on error (but we handle lock cleanup manually)
set -e

#############################################
# CONFIGURATION
#############################################

AI_HOME="$HOME/ai_home"
SYSTEM_PROMPT_FILE="$AI_HOME/SYSTEM_PROMPT.md"
LOG_DIR="$AI_HOME/logs"
STATE_DIR="$AI_HOME/state"
CONFIG_FILE="$AI_HOME/config.sh"

# Lock file location
LOCK_FILE="$STATE_DIR/session.lock"

# Default timing configuration (can be overridden in config.sh)
# SESSION_INTERVAL: how often cron runs (in minutes)
# SESSION_TIMEOUT: max session duration = 2 * SESSION_INTERVAL (in seconds)
SESSION_INTERVAL_MINUTES=15
SESSION_TIMEOUT_SECONDS=$((SESSION_INTERVAL_MINUTES * 2 * 60))  # 30 minutes

# Load custom config if exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    # Recalculate timeout if interval was changed
    SESSION_TIMEOUT_SECONDS=${SESSION_TIMEOUT_SECONDS:-$((SESSION_INTERVAL_MINUTES * 2 * 60))}
fi

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
SESSION_COUNTER_FILE="$STATE_DIR/session_counter.txt"

#############################################
# LOCK MANAGEMENT FUNCTIONS
#############################################

# Create lock file with PID and start time
acquire_lock() {
    local current_time=$(date +%s)
    
    # Check if lock exists
    if [ -f "$LOCK_FILE" ]; then
        # Read lock info
        local lock_pid=$(head -1 "$LOCK_FILE" 2>/dev/null || echo "")
        local lock_time=$(tail -1 "$LOCK_FILE" 2>/dev/null || echo "0")
        local lock_age=$((current_time - lock_time))
        
        # Check if process is still running
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            # Process exists, check if it's too old (stale)
            if [ "$lock_age" -gt "$SESSION_TIMEOUT_SECONDS" ]; then
                echo "[$TIMESTAMP] WARNING: Stale lock detected! Session $lock_pid running for ${lock_age}s (max: ${SESSION_TIMEOUT_SECONDS}s)" >> "$LOG_DIR/runner.log"
                echo "[$TIMESTAMP] Killing stale session (PID: $lock_pid)..." >> "$LOG_DIR/runner.log"
                
                # Kill the stale process and its children
                kill -TERM "$lock_pid" 2>/dev/null || true
                sleep 2
                kill -KILL "$lock_pid" 2>/dev/null || true
                
                # Remove stale lock
                rm -f "$LOCK_FILE"
                
                # Log the forced termination
                echo "[$TIMESTAMP] Stale session terminated. Previous session was hung for ${lock_age}s" >> "$LOG_DIR/runner.log"
            else
                # Lock is valid and process is running - skip this run
                echo "[$TIMESTAMP] SKIPPED: Previous session still running (PID: $lock_pid, age: ${lock_age}s)" >> "$LOG_DIR/runner.log"
                exit 0
            fi
        else
            # Process not running but lock exists - orphaned lock
            echo "[$TIMESTAMP] Removing orphaned lock (PID $lock_pid not found)" >> "$LOG_DIR/runner.log"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Create new lock
    echo "$$" > "$LOCK_FILE"
    echo "$current_time" >> "$LOCK_FILE"
    
    echo "[$TIMESTAMP] Lock acquired (PID: $$, timeout: ${SESSION_TIMEOUT_SECONDS}s)" >> "$LOG_DIR/runner.log"
}

# Remove lock file
release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(head -1 "$LOCK_FILE" 2>/dev/null || echo "")
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$LOCK_FILE"
            echo "[$(date +"%Y-%m-%d_%H-%M-%S")] Lock released (PID: $$)" >> "$LOG_DIR/runner.log"
        fi
    fi
}

# Cleanup on exit (normal or error)
cleanup() {
    local exit_code=$?
    release_lock
    exit $exit_code
}

#############################################
# MAIN SCRIPT
#############################################

# Ensure directories exist
mkdir -p "$AI_HOME/state"
mkdir -p "$AI_HOME/logs"
mkdir -p "$AI_HOME/knowledge"
mkdir -p "$AI_HOME/projects"
mkdir -p "$AI_HOME/tools"

# Set up cleanup trap
trap cleanup EXIT INT TERM

# Try to acquire lock (will exit if another session is running)
acquire_lock

# Initialize session counter if not exists
if [ ! -f "$SESSION_COUNTER_FILE" ]; then
    echo "0" > "$SESSION_COUNTER_FILE"
fi

# Get current session number
CURRENT_SESSION=$(cat "$SESSION_COUNTER_FILE")
NEXT_SESSION=$((CURRENT_SESSION + 1))

# Determine if this is a consolidation session (every 5 sessions)
IS_CONSOLIDATION="no"
if [ $((NEXT_SESSION % 5)) -eq 0 ]; then
    IS_CONSOLIDATION="yes"
fi

# Log start
echo "[$TIMESTAMP] Starting AI session #$NEXT_SESSION (consolidation: $IS_CONSOLIDATION)..." >> "$LOG_DIR/runner.log"

#############################################
# PROMPT BUILDER
#############################################

build_prompt() {
    echo "=== SYSTEM PROMPT ==="
    cat "$SYSTEM_PROMPT_FILE"
    echo ""
    echo "=== CURRENT SESSION INFO ==="
    echo "Timestamp: $(date)"
    echo "Session Number: $NEXT_SESSION"
    echo "Session Type: $([ "$IS_CONSOLIDATION" = "yes" ] && echo "CONSOLIDATION (cleanup & refocus)" || echo "REGULAR")"
    echo "Session Timeout: ${SESSION_TIMEOUT_SECONDS} seconds ($(( SESSION_TIMEOUT_SECONDS / 60 )) minutes)"
    echo ""
    echo "=== YOUR CURRENT STATE ==="
    echo ""
    echo "--- session_counter.txt ---"
    echo "$CURRENT_SESSION"
    echo "(You are now starting session #$NEXT_SESSION)"
    echo ""
    echo "--- current_plan.md ---"
    cat "$AI_HOME/state/current_plan.md" 2>/dev/null || echo "(no plan yet)"
    echo ""
    echo "--- last_session.md ---"
    cat "$AI_HOME/state/last_session.md" 2>/dev/null || echo "(no previous session)"
    echo ""
    
    # For consolidation sessions, also include history
    if [ "$IS_CONSOLIDATION" = "yes" ]; then
        echo "--- history.md (CONSOLIDATION - review this!) ---"
        cat "$AI_HOME/logs/history.md" 2>/dev/null || echo "(no history yet)"
        echo ""
        echo "--- Files in projects/ ---"
        ls -la "$AI_HOME/projects/" 2>/dev/null || echo "(empty)"
        echo ""
        echo "--- Files in knowledge/ ---"
        ls -la "$AI_HOME/knowledge/" 2>/dev/null || echo "(empty)"
        echo ""
    fi
    
    echo "=== BEGIN YOUR SESSION ==="
    if [ "$IS_CONSOLIDATION" = "yes" ]; then
        echo "*** THIS IS A CONSOLIDATION SESSION ***"
        echo "Follow the CONSOLIDATION cycle: DEEP REVIEW -> CLEANUP & REORGANIZE -> REPORT"
        echo "Focus on: summarizing history, cleaning files, refocusing on long-term goals"
    else
        echo "Follow the 3-phase cycle: REVIEW -> EXECUTE -> REPORT"
    fi
    echo ""
    echo "IMPORTANT: Don't forget to increment session_counter.txt to $NEXT_SESSION at the end!"
    echo "NOTE: You have a maximum of ${SESSION_TIMEOUT_SECONDS} seconds ($(( SESSION_TIMEOUT_SECONDS / 60 )) minutes) for this session."
    echo ""
    echo "You are now awake. What will you do?"
}

#############################################
# RUN METHODS
#############################################

# Method 1: Using qwen-cli (simpler, but less capable)
run_with_qwen_cli() {
    PROMPT=$(build_prompt)
    timeout "${SESSION_TIMEOUT_SECONDS}s" qwen -p "$PROMPT" 2>&1 || {
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "[$TIMESTAMP] ERROR: Session timed out after ${SESSION_TIMEOUT_SECONDS}s" >> "$LOG_DIR/runner.log"
        fi
        return $exit_code
    }
}

# Method 2: Using live-swe-agent (more capable, has tools)
run_with_live_swe_agent() {
    cd ~/live-swe-agent
    source venv/bin/activate
    
    PROMPT=$(build_prompt)
    
    # Run with timeout, yolo mode, and exit immediately when done
    # Cost limit 0 = no limit (using free Qwen API)
    timeout "${SESSION_TIMEOUT_SECONDS}s" mini --config config/livesweagent.yaml \
         --model openai/qwen3-coder-plus \
         --task "$PROMPT" \
         --yolo \
         --cost-limit 0 \
         --exit-immediately \
         2>&1 || {
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "[$TIMESTAMP] ERROR: Session timed out after ${SESSION_TIMEOUT_SECONDS}s" >> "$LOG_DIR/runner.log"
        fi
        return $exit_code
    }
}

# Method 3: Direct API call (most control)
run_with_direct_api() {
    PROMPT=$(build_prompt)
    ACCESS_TOKEN=$(cat ~/.qwen/oauth_creds.json | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
    
    # Escape the prompt for JSON
    ESCAPED_PROMPT=$(echo "$PROMPT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    
    timeout "${SESSION_TIMEOUT_SECONDS}s" curl -s -X POST "https://portal.qwen.ai/v1/chat/completions" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"qwen3-coder-plus\",
        \"messages\": [{\"role\": \"system\", \"content\": \"You are an autonomous AI agent. Follow the instructions exactly.\"}, {\"role\": \"user\", \"content\": $ESCAPED_PROMPT}],
        \"max_tokens\": 4096
      }" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content','ERROR: No response'))" || {
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "[$TIMESTAMP] ERROR: Session timed out after ${SESSION_TIMEOUT_SECONDS}s" >> "$LOG_DIR/runner.log"
        fi
        return $exit_code
    }
}

#############################################
# EXECUTION
#############################################

# Choose which method to use (default: live-swe-agent for tool access)
METHOD="${1:-live-swe-agent}"

echo "[$TIMESTAMP] Running with method: $METHOD (timeout: ${SESSION_TIMEOUT_SECONDS}s)" >> "$LOG_DIR/runner.log"

case "$METHOD" in
    "qwen")
        run_with_qwen_cli | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    "live-swe-agent")
        run_with_live_swe_agent | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    "api")
        run_with_direct_api | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    *)
        echo "Unknown method: $METHOD"
        echo "Usage: $0 [qwen|live-swe-agent|api]"
        exit 1
        ;;
esac

echo "[$TIMESTAMP] Session #$NEXT_SESSION complete" >> "$LOG_DIR/runner.log"

# Lock is released automatically by the cleanup trap
