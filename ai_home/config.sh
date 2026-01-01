#!/bin/bash
#
# AI Agent Configuration
# Edit these values to customize the agent's behavior
#

# How often cron runs the agent (in minutes)
# This should match your crontab entry!
SESSION_INTERVAL_MINUTES=15

# Maximum session duration in seconds
# Default: 2x the interval (so if interval=15min, timeout=30min)
# Sessions running longer than this will be killed
SESSION_TIMEOUT_SECONDS=$((SESSION_INTERVAL_MINUTES * 2 * 60))

# For testing, you might want shorter values:
# SESSION_INTERVAL_MINUTES=2
# SESSION_TIMEOUT_SECONDS=240  # 4 minutes

# Consolidation frequency (every N sessions)
# Default: 5 (consolidation happens at sessions 5, 10, 15, etc.)
# CONSOLIDATION_INTERVAL=5  # Not yet implemented, change in run_ai.sh if needed
