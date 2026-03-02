#!/bin/bash
#
# AI Agent Configuration - V2
# Edit these values to customize the agent's behavior
#

# How often cron runs the agent (in minutes)
# This should match your crontab entry!
SESSION_INTERVAL_MINUTES=15

# Maximum session duration in seconds
# If a session runs longer than this, it will be killed
SESSION_TIMEOUT_SECONDS=1800  # 30 minutes

# OpenRouter model
OPENROUTER_MODEL="anthropic/claude-haiku-4.5"
