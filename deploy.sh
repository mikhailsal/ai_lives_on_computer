#!/bin/bash
#
# Deploy AI Lives on Computer to remote server
# Usage: ./deploy.sh [hostname]
#

set -e

HOST="${1:-debian}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 Deploying AI Lives on Computer to $HOST..."

# Copy directory structure
echo "📁 Creating directories..."
ssh "$HOST" "mkdir -p ~/ai_home/{state,logs,knowledge,projects,tools}"

# Copy system prompt
echo "📝 Copying system prompt..."
scp "$SCRIPT_DIR/SYSTEM_PROMPT.md" "$HOST:~/ai_home/"

# Copy initial state files
echo "📋 Copying initial state..."
scp "$SCRIPT_DIR/ai_home/state/current_plan.md" "$HOST:~/ai_home/state/"
scp "$SCRIPT_DIR/ai_home/state/last_session.md" "$HOST:~/ai_home/state/"
scp "$SCRIPT_DIR/ai_home/logs/history.md" "$HOST:~/ai_home/logs/"

# Copy runner script
echo "⚙️ Copying runner script..."
scp "$SCRIPT_DIR/run_ai.sh" "$HOST:~/"
ssh "$HOST" "chmod +x ~/run_ai.sh"

echo ""
echo "✅ Deployment complete!"
echo ""
echo "Next steps:"
echo "  1. Test manually: ssh $HOST './run_ai.sh live-swe-agent'"
echo "  2. Set up cron:   ssh $HOST 'crontab -e'"
echo "     Add: */15 * * * * /home/user/run_ai.sh live-swe-agent >> /home/user/ai_home/logs/cron.log 2>&1"
echo ""
echo "Monitor:"
echo "  ssh $HOST 'cat ~/ai_home/state/last_session.md'"
echo "  ssh $HOST 'tail -f ~/ai_home/logs/cron.log'"
