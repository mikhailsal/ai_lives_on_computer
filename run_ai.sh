#!/bin/bash
#
# AI Autonomous Agent Runner - V2
# This script runs the AI agent with the system prompt via OpenRouter
# Designed to be called by cron at regular intervals
#
# Features:
# - Lock file prevents concurrent sessions
# - Stale lock detection (kills hung sessions after timeout)
# - Configurable session interval and timeout
# - Step limit to prevent runaway sessions
# - Circuit breaker with false-positive protection
# - Truncated file inclusion for cost control
#

# Pipefail to catch errors in piped commands
# Note: We do NOT use set -e because we handle errors manually
set -o pipefail

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
SESSION_INTERVAL_MINUTES=15
SESSION_TIMEOUT_SECONDS=$((SESSION_INTERVAL_MINUTES * 2 * 60))  # 30 minutes

# Step limit - maximum number of agent actions per session
# This prevents runaway sessions from burning API credits
MAX_STEPS=25

# Circuit breaker - detect repetitive sessions
REPETITION_THRESHOLD=5  # Number of similar sessions before intervention
SIMILARITY_CHECK_FILE="$STATE_DIR/last_sessions_hash.txt"
LAST_EXIT_CODE_FILE="$STATE_DIR/last_exit_code.txt"
CB_INJECTED_FLAG="$STATE_DIR/cb_injected.flag"

# File truncation limit for prompt building (lines)
FILE_TRUNCATE_LINES=200

# Load custom config if exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    SESSION_TIMEOUT_SECONDS=${SESSION_TIMEOUT_SECONDS:-$((SESSION_INTERVAL_MINUTES * 2 * 60))}
fi

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
SESSION_COUNTER_FILE="$STATE_DIR/session_counter.txt"

#############################################
# LOCK MANAGEMENT FUNCTIONS
#############################################

acquire_lock() {
    local current_time=$(date +%s)
    
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(head -1 "$LOCK_FILE" 2>/dev/null || echo "")
        local lock_time=$(tail -1 "$LOCK_FILE" 2>/dev/null || echo "0")
        local lock_age=$((current_time - lock_time))
        
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            if [ "$lock_age" -gt "$SESSION_TIMEOUT_SECONDS" ]; then
                echo "[$TIMESTAMP] WARNING: Stale lock detected! Session $lock_pid running for ${lock_age}s (max: ${SESSION_TIMEOUT_SECONDS}s)" >> "$LOG_DIR/runner.log"
                echo "[$TIMESTAMP] Killing stale session (PID: $lock_pid)..." >> "$LOG_DIR/runner.log"
                
                kill -TERM "$lock_pid" 2>/dev/null || true
                sleep 2
                kill -KILL "$lock_pid" 2>/dev/null || true
                
                rm -f "$LOCK_FILE"
                echo "[$TIMESTAMP] Stale session terminated." >> "$LOG_DIR/runner.log"
            else
                echo "[$TIMESTAMP] SKIPPED: Previous session still running (PID: $lock_pid, age: ${lock_age}s)" >> "$LOG_DIR/runner.log"
                exit 0
            fi
        else
            echo "[$TIMESTAMP] Removing orphaned lock (PID $lock_pid not found)" >> "$LOG_DIR/runner.log"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo "$$" > "$LOCK_FILE"
    echo "$current_time" >> "$LOCK_FILE"
    
    echo "[$TIMESTAMP] Lock acquired (PID: $$, timeout: ${SESSION_TIMEOUT_SECONDS}s, max_steps: ${MAX_STEPS})" >> "$LOG_DIR/runner.log"
}

release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(head -1 "$LOCK_FILE" 2>/dev/null || echo "")
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$LOCK_FILE"
            echo "[$(date +"%Y-%m-%d_%H-%M-%S")] Lock released (PID: $$)" >> "$LOG_DIR/runner.log"
        fi
    fi
}

cleanup() {
    local exit_code=$?
    # Save exit code for circuit breaker false-positive protection
    # Only write if not already saved by the main execution block
    if [ -z "$SESSION_EXIT_SAVED" ]; then
        echo "$exit_code" > "$LAST_EXIT_CODE_FILE"
    fi
    release_lock
    exit $exit_code
}

#############################################
# CIRCUIT BREAKER - Detect Repetitive Sessions
# Protected against false positives from API errors
#############################################

check_repetition() {
    # If the previous session ended with an error, skip the repetition check.
    # API errors cause last_session.md to stay unchanged, which would
    # falsely trigger the circuit breaker.
    if [ -f "$LAST_EXIT_CODE_FILE" ]; then
        local last_exit=$(cat "$LAST_EXIT_CODE_FILE" 2>/dev/null || echo "0")
        if [ "$last_exit" != "0" ]; then
            echo "[$TIMESTAMP] Circuit breaker: skipping check (previous session exited with code $last_exit)" >> "$LOG_DIR/runner.log"
            return 0
        fi
    fi

    # Get hash of current last_session.md content (ignoring session numbers)
    local current_content=""
    if [ -f "$AI_HOME/state/last_session.md" ]; then
        # Remove session numbers and dates to compare actual content
        current_content=$(cat "$AI_HOME/state/last_session.md" | sed 's/[Ss]ession [0-9]*//g' | sed 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}//g' | tr -s ' ' | md5sum | cut -d' ' -f1)
    fi
    
    # Initialize hash file if it doesn't exist
    if [ ! -f "$SIMILARITY_CHECK_FILE" ]; then
        echo "$current_content" > "$SIMILARITY_CHECK_FILE"
        return 0
    fi
    
    # Count how many recent sessions have same hash
    local repeat_count=$(grep -c "^${current_content}$" "$SIMILARITY_CHECK_FILE" 2>/dev/null || echo "0")
    
    # Add current hash to file (keep last 10)
    echo "$current_content" >> "$SIMILARITY_CHECK_FILE"
    tail -10 "$SIMILARITY_CHECK_FILE" > "$SIMILARITY_CHECK_FILE.tmp"
    mv "$SIMILARITY_CHECK_FILE.tmp" "$SIMILARITY_CHECK_FILE"
    
    if [ "$repeat_count" -ge "$REPETITION_THRESHOLD" ]; then
        echo "[$TIMESTAMP] Circuit breaker: detected $repeat_count similar sessions" >> "$LOG_DIR/runner.log"
        return 1
    fi
    
    return 0
}

inject_nudge() {
    # Only inject once per circuit breaker trigger to avoid confusing the agent
    if [ -f "$CB_INJECTED_FLAG" ]; then
        echo "[$TIMESTAMP] Circuit breaker: nudge already injected, skipping" >> "$LOG_DIR/runner.log"
        return
    fi

    local nudge_messages=(
        "Note: Your recent sessions look similar. Consider trying something different if you feel stuck."
        "Gentle reminder: Your last few sessions followed the same pattern. What would you do with a blank slate?"
        "FYI: Repetition detected in recent sessions. This is just informational -- do what feels right to you."
    )
    
    # Pick a random message
    local idx=$((RANDOM % ${#nudge_messages[@]}))
    local nudge="${nudge_messages[$idx]}"
    
    # Write to external messages file
    local ext_msg_file="$AI_HOME/state/external_messages.md"
    {
        echo ""
        echo "---"
        echo ""
        echo "## System Note ($(date '+%Y-%m-%d %H:%M'))"
        echo ""
        echo "$nudge"
        echo ""
    } >> "$ext_msg_file"
    
    # Mark as injected so we don't repeat
    touch "$CB_INJECTED_FLAG"
    
    echo "[$TIMESTAMP] Injected gentle nudge into external_messages.md" >> "$LOG_DIR/runner.log"
}

#############################################
# PROMPT BUILDER - Cost-optimized
#############################################

# Truncate a file to N lines, adding a note if truncated
truncate_file() {
    local file="$1"
    local max_lines="$2"
    local content=""
    
    if [ ! -f "$file" ]; then
        echo "(empty)"
        return
    fi
    
    local total_lines=$(wc -l < "$file")
    
    if [ "$total_lines" -le "$max_lines" ]; then
        cat "$file"
    else
        head -n "$max_lines" "$file"
        echo ""
        echo "[NOTE: This is the first $max_lines of $total_lines lines. Read the full file with: cat $file]"
    fi
}

build_prompt() {
    echo "=== SYSTEM PROMPT ==="
    cat "$SYSTEM_PROMPT_FILE"
    echo ""
    echo "=== SESSION INFO ==="
    echo "Session Number: $NEXT_SESSION"
    echo ""
    echo "=== YOUR CURRENT STATE ==="
    echo ""
    echo "--- last_session.md ---"
    truncate_file "$AI_HOME/state/last_session.md" "$FILE_TRUNCATE_LINES"
    echo ""
    echo "--- current_plan.md ---"
    truncate_file "$AI_HOME/state/current_plan.md" "$FILE_TRUNCATE_LINES"
    echo ""
    echo "=== OTHER FILES AVAILABLE (read them if you need them) ==="
    echo "- ~/ai_home/logs/history.md"
    echo "- ~/ai_home/logs/consolidated_history.md"
    echo "- ~/ai_home/knowledge/ (directory)"
    echo "- ~/ai_home/projects/ (directory)"
    echo "- ~/ai_home/tools/ (directory)"
    echo "- ~/ai_home/state/external_messages.md"
    echo ""
    echo "=== BEGIN ==="
    echo "You are now awake. This is session #$NEXT_SESSION."
}

#############################################
# RUN METHOD - OpenRouter
#############################################

run_session() {
    cd ~/live-swe-agent
    source venv/bin/activate
    
    # mini-swe-agent always reads from ~/.config/mini-swe-agent/.env
    # We need to temporarily swap it with the OpenRouter config
    local main_env="$HOME/.config/mini-swe-agent/.env"
    local openrouter_env="$HOME/.config/mini-swe-agent/.env.openrouter"
    local backup_env="$HOME/.config/mini-swe-agent/.env.backup"
    
    if [ ! -f "$openrouter_env" ]; then
        echo "[$TIMESTAMP] ERROR: OpenRouter config not found at $openrouter_env" | tee -a "$LOG_DIR/runner.log" >&2
        echo "[$TIMESTAMP] Run ~/setup-openrouter.sh to configure OpenRouter" | tee -a "$LOG_DIR/runner.log" >&2
        return 1
    fi
    
    # Backup the current .env and swap in OpenRouter config
    if [ -f "$main_env" ]; then
        cp "$main_env" "$backup_env"
    fi
    cp "$openrouter_env" "$main_env"
    
    # Ensure cleanup happens even if the command fails
    cleanup_env() {
        if [ -f "$backup_env" ]; then
            cp "$backup_env" "$main_env"
        fi
    }
    trap cleanup_env RETURN
    
    PROMPT=$(build_prompt)
    
    # Get model from config
    local model="${OPENROUTER_MODEL:-x-ai/grok-4.1-fast}"
    
    echo "[$TIMESTAMP] Using OpenRouter model: $model" >> "$LOG_DIR/runner.log"
    
    timeout "${SESSION_TIMEOUT_SECONDS}s" mini --config config/ai_agent_openrouter.yaml \
         --model "openai/${model}" \
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

#############################################
# MAIN SCRIPT
#############################################

mkdir -p "$AI_HOME/state"
mkdir -p "$AI_HOME/logs"
mkdir -p "$AI_HOME/knowledge"
mkdir -p "$AI_HOME/projects"
mkdir -p "$AI_HOME/tools"

trap cleanup EXIT INT TERM

acquire_lock

if [ ! -f "$SESSION_COUNTER_FILE" ]; then
    echo "0" > "$SESSION_COUNTER_FILE"
fi

CURRENT_SESSION=$(cat "$SESSION_COUNTER_FILE")
NEXT_SESSION=$((CURRENT_SESSION + 1))

echo "[$TIMESTAMP] Starting AI session #$NEXT_SESSION..." >> "$LOG_DIR/runner.log"

# Check for repetitive behavior and inject nudge if needed
# Protected: skips check if previous session ended with error
if ! check_repetition; then
    inject_nudge
else
    # If repetition check passed, clear the injection flag
    rm -f "$CB_INJECTED_FLAG"
fi

#############################################
# EXECUTION
#############################################

echo "[$TIMESTAMP] Running session (timeout: ${SESSION_TIMEOUT_SECONDS}s, model: ${OPENROUTER_MODEL:-x-ai/grok-4.1-fast})" >> "$LOG_DIR/runner.log"

SESSION_EXIT=0
run_session 2>&1 | tee -a "$LOG_DIR/session_$TIMESTAMP.log" || SESSION_EXIT=$?

# Save session exit code for circuit breaker false-positive protection
echo "$SESSION_EXIT" > "$LAST_EXIT_CODE_FILE"
SESSION_EXIT_SAVED=true

if [ "$SESSION_EXIT" -ne 0 ]; then
    echo "[$TIMESTAMP] Session #$NEXT_SESSION failed (exit code: $SESSION_EXIT)" >> "$LOG_DIR/runner.log"
else
    echo "[$TIMESTAMP] Session #$NEXT_SESSION complete" >> "$LOG_DIR/runner.log"
fi
