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

# Session cost guardrail (USD). 0 means unlimited.
COST_LIMIT=0

# Circuit breaker - detect repetitive sessions
REPETITION_THRESHOLD=5  # Number of similar sessions before intervention
SIMILARITY_CHECK_FILE="$STATE_DIR/last_sessions_hash.txt"
LAST_EXIT_CODE_FILE="$STATE_DIR/last_exit_code.txt"
CB_INJECTED_FLAG="$STATE_DIR/cb_injected.flag"
LIMIT_INTERRUPTED_FILE="$STATE_DIR/last_session_interrupted_by_limits.txt"

# File truncation limit for prompt building (lines)
FILE_TRUNCATE_LINES=200

# Load custom config if exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    SESSION_TIMEOUT_SECONDS=${SESSION_TIMEOUT_SECONDS:-$((SESSION_INTERVAL_MINUTES * 2 * 60))}
fi

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
SESSION_COUNTER_FILE="$STATE_DIR/session_counter.txt"
SESSION_LOG_FILE="$LOG_DIR/session_$TIMESTAMP.log"

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
    
    echo "[$TIMESTAMP] Lock acquired (PID: $$, timeout: ${SESSION_TIMEOUT_SECONDS}s, max_steps: ${MAX_STEPS}, cost_limit: ${COST_LIMIT})" >> "$LOG_DIR/runner.log"
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
    local prev_limit_status="unknown"
    if [ -f "$LIMIT_INTERRUPTED_FILE" ]; then
        prev_limit_status=$(cat "$LIMIT_INTERRUPTED_FILE" 2>/dev/null || echo "unknown")
    fi

    echo "<prompt>"
    echo "<system-prompt>"
    cat "$SYSTEM_PROMPT_FILE"
    echo "</system-prompt>"
    echo ""
    echo "<session-info>"
    echo "  <session-number>$NEXT_SESSION</session-number>"
    echo "  <session-start-time iso=\"$SESSION_START_ISO\" epoch=\"$SESSION_START_EPOCH\" />"
    echo "  <session-deadline-time iso=\"$SESSION_DEADLINE_ISO\" epoch=\"$SESSION_DEADLINE_EPOCH\" />"
    echo "  <session-limits timeout_seconds=\"$SESSION_TIMEOUT_SECONDS\" max_steps=\"$MAX_STEPS\" cost_limit_usd=\"$COST_LIMIT\" />"
    echo "  <previous-session interrupted_by_limits=\"$prev_limit_status\" />"
    echo "</session-info>"
    echo ""
    echo "<current-state>"
    echo "<last-session-md>"
    truncate_file "$AI_HOME/state/last_session.md" "$FILE_TRUNCATE_LINES"
    echo "</last-session-md>"
    echo ""
    echo "<current-plan-md>"
    truncate_file "$AI_HOME/state/current_plan.md" "$FILE_TRUNCATE_LINES"
    echo "</current-plan-md>"
    echo "</current-state>"
    echo ""
    echo "<available-files>"
    echo "  <file>~/ai_home/logs/history.md</file>"
    echo "  <file>~/ai_home/logs/consolidated_history.md</file>"
    echo "  <dir>~/ai_home/knowledge/</dir>"
    echo "  <dir>~/ai_home/projects/</dir>"
    echo "  <dir>~/ai_home/tools/</dir>"
    echo "  <file>~/ai_home/state/external_messages.md</file>"
    echo "</available-files>"
    echo ""
    echo "<begin>You are now awake. This is session #$NEXT_SESSION.</begin>"
    echo "</prompt>"
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
    local model="${OPENROUTER_MODEL:-anthropic/claude-haiku-4.5}"
    
    # Get provider from config or env file
    local provider="${OPENROUTER_PROVIDER:-}"
    if [ -z "$provider" ] && [ -f "$openrouter_env" ]; then
        # Extract value and strip quotes
        provider=$(grep "^OPENROUTER_PROVIDER=" "$openrouter_env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi
    
    local config_file="config/ai_agent_openrouter.yaml"
    local tmp_config_file=""
    
    # Build extra_body with session tracking, provider, and reasoning settings
    tmp_config_file="config/ai_agent_openrouter_tmp_$$.yaml"
    cp "$config_file" "$tmp_config_file"
    
    # Keep YAML runtime limits synced with config.sh values
    if grep -q '^  step_limit:' "$tmp_config_file"; then
        sed -i "s/^  step_limit:.*/  step_limit: ${MAX_STEPS}/" "$tmp_config_file"
    else
        sed -i "/^agent:/a\\  step_limit: ${MAX_STEPS}" "$tmp_config_file"
    fi
    if grep -q '^  cost_limit:' "$tmp_config_file"; then
        sed -i "s/^  cost_limit:.*/  cost_limit: ${COST_LIMIT}/" "$tmp_config_file"
    else
        sed -i "/^  step_limit:/a\\  cost_limit: ${COST_LIMIT}" "$tmp_config_file"
    fi

    # Start extra_body block
    echo "    extra_body:" >> "$tmp_config_file"
    
    # Session ID for Langfuse grouping via OpenRouter Broadcast
    echo "      session_id: \"session_${NEXT_SESSION}\"" >> "$tmp_config_file"
    
    # Trace metadata for richer Langfuse analytics
    echo "      trace:" >> "$tmp_config_file"
    echo "        trace_name: \"AI Agent Session ${NEXT_SESSION}\"" >> "$tmp_config_file"
    echo "        generation_name: \"step\"" >> "$tmp_config_file"
    
    # Disable reasoning (prevents overthinking and wasted tokens)
    echo "      reasoning:" >> "$tmp_config_file"
    echo "        enabled: false" >> "$tmp_config_file"
    
    # Add provider routing if specified
    if [ -n "$provider" ]; then
        echo "[$TIMESTAMP] Using OpenRouter provider: $provider" >> "$LOG_DIR/runner.log"
        echo "      provider:" >> "$tmp_config_file"
        echo "        order: [\"$provider\"]" >> "$tmp_config_file"
        echo "        allow_fallbacks: false" >> "$tmp_config_file"
    fi
    
    config_file="$tmp_config_file"
    
    echo "[$TIMESTAMP] Using OpenRouter model: $model (session_id: session_${NEXT_SESSION})" >> "$LOG_DIR/runner.log"
    
    timeout "${SESSION_TIMEOUT_SECONDS}s" mini --config "$config_file" \
         --model "openai/${model}" \
         --task "$PROMPT" \
         --yolo \
         --cost-limit "${COST_LIMIT}" \
         --exit-immediately \
         2>&1 || {
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "[$TIMESTAMP] ERROR: Session timed out after ${SESSION_TIMEOUT_SECONDS}s" >> "$LOG_DIR/runner.log"
        fi
        # Cleanup temp config
        [ -n "$tmp_config_file" ] && [ -f "$tmp_config_file" ] && rm "$tmp_config_file"
        return $exit_code
    }
    
    # Cleanup temp config
    [ -n "$tmp_config_file" ] && [ -f "$tmp_config_file" ] && rm "$tmp_config_file"
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
SESSION_START_EPOCH=$(date +%s)
SESSION_START_ISO=$(date -d "@$SESSION_START_EPOCH" +"%Y-%m-%dT%H:%M:%S%z")
SESSION_DEADLINE_EPOCH=$((SESSION_START_EPOCH + SESSION_TIMEOUT_SECONDS))
SESSION_DEADLINE_ISO=$(date -d "@$SESSION_DEADLINE_EPOCH" +"%Y-%m-%dT%H:%M:%S%z")

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

echo "[$TIMESTAMP] Running session (start: ${SESSION_START_ISO}, deadline: ${SESSION_DEADLINE_ISO}, timeout: ${SESSION_TIMEOUT_SECONDS}s, max_steps: ${MAX_STEPS}, cost_limit: ${COST_LIMIT}, model: ${OPENROUTER_MODEL:-anthropic/claude-haiku-4.5})" >> "$LOG_DIR/runner.log"

SESSION_EXIT=0
run_session 2>&1 | tee -a "$SESSION_LOG_FILE" || SESSION_EXIT=$?

# Save session exit code for circuit breaker false-positive protection
echo "$SESSION_EXIT" > "$LAST_EXIT_CODE_FILE"
SESSION_EXIT_SAVED=true

# Persist whether this session was interrupted by limits for the next wake-up prompt.
if [ -f "$SESSION_LOG_FILE" ] && grep -q "Limits exceeded\." "$SESSION_LOG_FILE"; then
    echo "yes" > "$LIMIT_INTERRUPTED_FILE"
    echo "[$TIMESTAMP] Session #$NEXT_SESSION hit limits" >> "$LOG_DIR/runner.log"
else
    echo "no" > "$LIMIT_INTERRUPTED_FILE"
fi

if [ "$SESSION_EXIT" -ne 0 ]; then
    echo "[$TIMESTAMP] Session #$NEXT_SESSION failed (exit code: $SESSION_EXIT)" >> "$LOG_DIR/runner.log"
else
    echo "[$TIMESTAMP] Session #$NEXT_SESSION complete" >> "$LOG_DIR/runner.log"
fi
