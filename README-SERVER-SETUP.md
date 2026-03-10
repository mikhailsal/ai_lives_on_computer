# Debian Server Setup

> **📖 This document is deprecated.** The complete, step-by-step deployment guide is now in the main **[README.md](README.md)**.
>
> The README covers everything: getting a server, SSH setup, installing prerequisites, deploying, configuring OpenRouter, and more.

---

## Legacy Notes

This file previously contained Qwen OAuth-specific setup instructions. Since Qwen closed their external API access (March 2026), the project has moved to **OpenRouter** with free models.

### Key Changes

| Before (Qwen) | Now (OpenRouter) |
|---------------|-----------------|
| `qwen-cli` OAuth tokens | OpenRouter API key (free) |
| `portal.qwen.ai` endpoint | `openrouter.ai/api/v1` endpoint |
| `sync-qwen-token.sh` needed | `setup-openrouter.sh` (one-time) |
| Token refresh complexity | Simple API key, no refresh needed |
| Single model (coder-model) | 400+ models, many free |

### Quick Start (New Way)

```bash
# See README.md for the full guide. Quick version:

# 1. Set up SSH alias (on local machine, ~/.ssh/config):
#    Host debian
#        HostName YOUR_SERVER_IP
#        User user

# 2. Deploy
./deploy.sh

# 3. Configure OpenRouter (on server)
ssh debian "~/setup-openrouter.sh YOUR_OPENROUTER_API_KEY"

# 4. Set up cron (on server)
ssh debian "crontab -e"
# Add: */15 * * * * ~/run_ai.sh openrouter >> ~/ai_home/logs/cron.log 2>&1
```

For the complete guide, see **[README.md](README.md)**.

---

*Last updated: March 2026*
