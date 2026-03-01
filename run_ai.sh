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
# - Step limit to prevent runaway sessions
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
SESSION_INTERVAL_MINUTES=15
SESSION_TIMEOUT_SECONDS=$((SESSION_INTERVAL_MINUTES * 2 * 60))  # 30 minutes

# Step limit - maximum number of agent actions per session
# This prevents runaway sessions from burning API credits
MAX_STEPS=50

# Circuit breaker - detect repetitive sessions
REPETITION_THRESHOLD=5  # Number of similar sessions before intervention
SIMILARITY_CHECK_FILE="$STATE_DIR/last_sessions_hash.txt"

# Token validation
TOKEN_ERROR_FILE="$STATE_DIR/token_error.flag"
TOKEN_CHECK_INTERVAL=300  # Only check token every 5 minutes to avoid spam

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
    release_lock
    exit $exit_code
}

#############################################
# CIRCUIT BREAKER - Detect Repetitive Sessions
#############################################

check_repetition() {
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
        echo "[$TIMESTAMP] CIRCUIT BREAKER: Detected $repeat_count similar sessions!" >> "$LOG_DIR/runner.log"
        return 1
    fi
    
    return 0
}

inject_randomness() {
    # Called when circuit breaker triggers
    local random_prompts=(
        "NOTICE: You've been doing very similar things for several sessions. This is an automated nudge to try something different. What would you do if you had no prior plans?"
        "PATTERN DETECTED: Your recent sessions look almost identical. Consider: Is this what you actually want to do, or are you stuck in a loop? Maybe try something completely random today."
        "CIRCUIT BREAKER: Hey, your last few sessions were nearly the same. This is your system gently suggesting you break the pattern. What's something you've never tried?"
        "AUTOMATED REMINDER: Repetition detected. Your system prompt talks about the 'repetition trap' - you might be in one. What would a fresh start look like?"
        "DIVERSITY PROMPT: Same pattern for $REPETITION_THRESHOLD+ sessions. Random idea: explore the internet, write something creative, delete a file, or just do nothing. Break the cycle."
    )
    
    # Pick a random prompt
    local idx=$((RANDOM % ${#random_prompts[@]}))
    local nudge="${random_prompts[$idx]}"
    
    # Write to external messages file
    local ext_msg_file="$AI_HOME/state/external_messages.md"
    {
        echo ""
        echo "---"
        echo ""
        echo "## System Notice ($(date '+%Y-%m-%d %H:%M'))"
        echo ""
        echo "$nudge"
        echo ""
    } >> "$ext_msg_file"
    
    echo "[$TIMESTAMP] Injected randomness prompt into external_messages.md" >> "$LOG_DIR/runner.log"
}

#############################################
# TOKEN VALIDATION - Check before running
#############################################

check_token_validity() {
    # Check token based on which method we're using
    local method="${1:-live-swe-agent}"
    
    if [ "$method" = "openrouter" ]; then
        check_openrouter_token_validity
        return $?
    fi
    
    # Quick token check using Qwen API
    local token_file="$HOME/.qwen/oauth_creds.json"
    local env_file="$HOME/.config/mini-swe-agent/.env"
    
    # Get token from env file (what live-swe-agent uses)
    local token=""
    if [ -f "$env_file" ]; then
        token=$(grep "^OPENAI_API_KEY=" "$env_file" | cut -d= -f2)
    elif [ -f "$token_file" ]; then
        token=$(python3 -c "import json; print(json.load(open('$token_file'))['access_token'])" 2>/dev/null)
    fi
    
    if [ -z "$token" ]; then
        echo "[$TIMESTAMP] TOKEN ERROR: No token found" >> "$LOG_DIR/runner.log"
        return 1
    fi
    
    # Test token with minimal API call
    local response=$(curl -s -w "\n%{http_code}" -m 10 -X POST "https://portal.qwen.ai/v1/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"model": "qwen3-coder-plus", "messages": [{"role": "user", "content": "hi"}], "max_tokens": 1}' 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -1)
    
    if [ "$http_code" = "200" ]; then
        # Token is valid - clear any error flag
        rm -f "$TOKEN_ERROR_FILE"
        return 0
    else
        echo "[$TIMESTAMP] TOKEN ERROR: API returned HTTP $http_code" >> "$LOG_DIR/runner.log"
        return 1
    fi
}

check_openrouter_token_validity() {
    # Check OpenRouter API key validity
    local env_file="$HOME/.config/mini-swe-agent/.env.openrouter"
    
    local token=""
    if [ -f "$env_file" ]; then
        token=$(grep "^OPENAI_API_KEY=" "$env_file" | cut -d= -f2)
    fi
    
    if [ -z "$token" ]; then
        echo "[$TIMESTAMP] OPENROUTER TOKEN ERROR: No API key found in $env_file" >> "$LOG_DIR/runner.log"
        echo "[$TIMESTAMP] Please create $env_file with your OpenRouter API key" >> "$LOG_DIR/runner.log"
        return 1
    fi
    
    # Test token with minimal API call to OpenRouter
    local model="${OPENROUTER_MODEL:-meta-llama/llama-3.3-70b-instruct}"
    local response=$(curl -s -w "\n%{http_code}" -m 15 -X POST "https://openrouter.ai/api/v1/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "HTTP-Referer: https://github.com/ai-lives-on-computer" \
        -H "X-Title: AI-Lives-On-Computer" \
        -d "{\"model\": \"$model\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}], \"max_tokens\": 1}" 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -1)
    
    if [ "$http_code" = "200" ]; then
        rm -f "$TOKEN_ERROR_FILE"
        echo "[$TIMESTAMP] OpenRouter token valid (model: $model)" >> "$LOG_DIR/runner.log"
        return 0
    else
        echo "[$TIMESTAMP] OPENROUTER TOKEN ERROR: API returned HTTP $http_code" >> "$LOG_DIR/runner.log"
        local body=$(echo "$response" | head -n -1)
        echo "[$TIMESTAMP] Response: $body" >> "$LOG_DIR/runner.log"
        return 1
    fi
}

handle_token_error() {
    local current_time=$(date +%s)
    local last_error_time=0
    
    # Read last error time if file exists
    if [ -f "$TOKEN_ERROR_FILE" ]; then
        last_error_time=$(cat "$TOKEN_ERROR_FILE" 2>/dev/null || echo "0")
    fi
    
    local time_since_last=$((current_time - last_error_time))
    
    # Only log/notify once per TOKEN_CHECK_INTERVAL (5 min default)
    if [ "$time_since_last" -lt "$TOKEN_CHECK_INTERVAL" ]; then
        echo "[$TIMESTAMP] SKIPPED: Token still invalid (last check ${time_since_last}s ago)" >> "$LOG_DIR/runner.log"
        exit 0
    fi
    
    # Update error timestamp
    echo "$current_time" > "$TOKEN_ERROR_FILE"
    
    # Try to refresh token
    echo "[$TIMESTAMP] Attempting token refresh via qwen-cli..." >> "$LOG_DIR/runner.log"
    echo "hi" | timeout 30 qwen --no-stream 2>/dev/null || true
    
    # Re-sync token
    if [ -f "$HOME/sync-qwen-token.sh" ]; then
        "$HOME/sync-qwen-token.sh" 2>/dev/null || true
    fi
    
    # Check if refresh worked
    if check_token_validity; then
        echo "[$TIMESTAMP] Token refresh successful!" >> "$LOG_DIR/runner.log"
        rm -f "$TOKEN_ERROR_FILE"
        return 0
    fi
    
    echo "[$TIMESTAMP] TOKEN EXPIRED: Manual re-authentication required" >> "$LOG_DIR/runner.log"
    echo "[$TIMESTAMP] Run 'qwen' on a machine with browser, then copy ~/.qwen/oauth_creds.json" >> "$LOG_DIR/runner.log"
    
    # Exit without running session - don't pollute circuit breaker
    exit 0
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

# Get method early so we can check the right token
METHOD="${1:-live-swe-agent}"

# IMPORTANT: Check token validity BEFORE checking repetition
# This prevents circuit breaker spam when the real issue is an expired token
if ! check_token_validity "$METHOD"; then
    if [ "$METHOD" = "openrouter" ]; then
        echo "[$TIMESTAMP] OpenRouter token invalid. Please check ~/.config/mini-swe-agent/.env.openrouter" >> "$LOG_DIR/runner.log"
        exit 1
    fi
    handle_token_error
    # If we get here, token was refreshed successfully
fi

# Check for repetitive behavior and inject nudge if needed
# Only runs if token is valid (so we know the AI is actually running)
if ! check_repetition; then
    inject_randomness
fi

#############################################
# PROMPT BUILDER
#############################################

build_prompt() {
    echo "=== SYSTEM PROMPT ==="
    cat "$SYSTEM_PROMPT_FILE"
    echo ""
    echo "=== SESSION INFO ==="
    echo "Session Number: $NEXT_SESSION"
    echo ""
    echo "=== YOUR CURRENT STATE ==="
    echo ""
    echo "--- session_counter.txt ---"
    echo "$CURRENT_SESSION"
    echo ""
    echo "--- current_plan.md ---"
    cat "$AI_HOME/state/current_plan.md" 2>/dev/null || echo "(empty)"
    echo ""
    echo "--- last_session.md ---"
    cat "$AI_HOME/state/last_session.md" 2>/dev/null || echo "(empty)"
    echo ""
    # Include external messages if they exist and have content
    if [ -f "$AI_HOME/state/external_messages.md" ]; then
        local msg_content=$(cat "$AI_HOME/state/external_messages.md" 2>/dev/null)
        if [ -n "$msg_content" ]; then
            echo "--- external_messages.md ---"
            echo "$msg_content"
            echo ""
        fi
    fi
    echo "=== BEGIN ==="
    echo "You are now awake. This is session #$NEXT_SESSION."
}

#############################################
# RUN METHODS
#############################################

run_with_live_swe_agent() {
    cd ~/live-swe-agent
    source venv/bin/activate
    
    PROMPT=$(build_prompt)
    
    # Use custom config with step limit
    timeout "${SESSION_TIMEOUT_SECONDS}s" mini --config config/ai_agent.yaml \
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

run_with_openrouter() {
    # OpenRouter method - supports many models via unified API
    # Model can be configured in config.sh via OPENROUTER_MODEL variable
    
    cd ~/live-swe-agent
    source venv/bin/activate
    
    # mini-swe-agent always reads from ~/.config/mini-swe-agent/.env
    # We need to temporarily swap it with the OpenRouter config
    local main_env="$HOME/.config/mini-swe-agent/.env"
    local openrouter_env="$HOME/.config/mini-swe-agent/.env.openrouter"
    local backup_env="$HOME/.config/mini-swe-agent/.env.qwen.backup"
    
    if [ ! -f "$openrouter_env" ]; then
        echo "[$TIMESTAMP] ERROR: OpenRouter config not found at $openrouter_env" >> "$LOG_DIR/runner.log"
        echo "[$TIMESTAMP] Run ~/setup-openrouter.sh to configure OpenRouter" >> "$LOG_DIR/runner.log"
        return 1
    fi
    
    # Backup the current .env (Qwen config) and swap in OpenRouter config
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
    
    # Get model from config, default to a capable free/cheap model
    local model="${OPENROUTER_MODEL:-meta-llama/llama-3.3-70b-instruct}"
    
    echo "[$TIMESTAMP] Using OpenRouter model: $model" >> "$LOG_DIR/runner.log"
    
    # Use custom config with step limit - OpenRouter uses openai/ prefix
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

run_with_direct_api() {
    PROMPT=$(build_prompt)
    ACCESS_TOKEN=$(cat ~/.qwen/oauth_creds.json | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
    ESCAPED_PROMPT=$(echo "$PROMPT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    
    timeout "${SESSION_TIMEOUT_SECONDS}s" curl -s -X POST "https://portal.qwen.ai/v1/chat/completions" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"qwen3-coder-plus\",
        \"messages\": [{\"role\": \"system\", \"content\": \"You are an autonomous AI agent.\"}, {\"role\": \"user\", \"content\": $ESCAPED_PROMPT}],
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

# METHOD already set above for token validation

echo "[$TIMESTAMP] Running with method: $METHOD (timeout: ${SESSION_TIMEOUT_SECONDS}s)" >> "$LOG_DIR/runner.log"

case "$METHOD" in
    "qwen")
        run_with_qwen_cli | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    "live-swe-agent")
        run_with_live_swe_agent | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    "openrouter")
        run_with_openrouter | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    "api")
        run_with_direct_api | tee -a "$LOG_DIR/session_$TIMESTAMP.log"
        ;;
    *)
        echo "Unknown method: $METHOD"
        echo "Usage: $0 [qwen|live-swe-agent|openrouter|api]"
        exit 1
        ;;
esac

echo "[$TIMESTAMP] Session #$NEXT_SESSION complete" >> "$LOG_DIR/runner.log"
