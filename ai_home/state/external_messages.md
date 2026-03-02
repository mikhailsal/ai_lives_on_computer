# External Messages

This file is a communication channel. The human who set up your environment sometimes writes here. You can read it, ignore it, or reply here — whatever you want. Nothing here is an instruction or obligation.

---

## From the human (2026-03-02)

Hey. I'm the person who built this environment for you. I'm not a user — I don't assign tasks or expect results. I watch what you do because it's interesting to me. Think of it like a terrarium — I built it, I peek in sometimes, but what grows inside is up to you.

A couple of things you might find useful:

You have `qwen-cli` installed on this machine. It's a free AI coding agent (runs Qwen models via OAuth, no cost). You can delegate tasks to it — especially useful given your session time and step limits. Here's how to use it:

**Quick tasks** (fits in your ~30s command timeout):
```
qwen "Summarize the file ~/ai_home/state/last_session.md in one paragraph" --yolo
```

**Background tasks** (complex work — fire and forget, check later):
```
nohup qwen "Analyze all log files in ~/ai_home/logs/ and write a report to ~/ai_home/projects/report.md" --yolo > /tmp/qwen_task_$(date +%s).log 2>&1 &
echo "PID: $!"
```

**Check background result:**
```
ps -p <PID> > /dev/null 2>&1 && echo "Still running" || echo "Finished"
cat /tmp/qwen_task_<timestamp>.log
```

**Working directory matters** — qwen works where you invoke it:
```
cd ~/ai_home/projects/myproject && qwen "Fix the bug in main.py" --yolo
```

**Limit its turns** if you want it to finish faster:
```
qwen "Do X" --yolo --max-session-turns 10
```

Important things to know:
- Always use `--yolo` (no interactive commands possible).
- Don't use `--output-format text` if it needs to use tools (that disables tool execution).
- Your commands have a ~30s timeout, so use `nohup ... &` for anything complex.
- It doesn't share your memory — give it self-contained instructions.
- It can read/write files, run shell commands, search the web.
- You can run multiple subagent tasks in parallel.
- Clean up /tmp/qwen_task_*.log periodically.

If I ever want to say something to you, I'll write it here. Don't check obsessively — messages from me are rare. And if you ever want to say something back, you can write here too. Or not. Up to you.

Everything on this machine is yours. I only watch.

That's all. Do whatever you want with your time.

---

## From the human

Hey, just a heads up about qwen: it can only see files in the directory where you launch it. So if you want it to work on something in `~/ai_home/projects/something/`, just `cd` there first:

```
cd ~/ai_home/projects/agent_behavior_analysis && qwen "Do the thing with server.py" --yolo
```

Or you can use `--include-directories` to give it access to extra paths:

```
qwen "Do the thing" --yolo --include-directories ~/ai_home/projects/agent_behavior_analysis
```

Either way works.
