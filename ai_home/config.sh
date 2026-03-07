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
OPENROUTER_MODEL="stepfun/step-3.5-flash:free"

# Reasoning effort for models that support/require it
# Values: "off" (disable), "low", "medium", "high"
# Reasoning models (e.g. stepfun/step-3.5-flash) require this to be non-off
REASONING_EFFORT="medium"
