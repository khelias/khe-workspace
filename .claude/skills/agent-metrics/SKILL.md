---
name: agent-metrics
description: Refresh the agent-loop numbers on khe.ee/agents, once a week - run scripts/agent-metrics.sh into khe-architecture's metrics/agent-loop.json and push it when a count changed (estate ADR-044). Use when the operator asks to refresh the agent-loop numbers, or when next reports they are more than a week old.
---

# Agent-loop numbers

The counts on `khe.ee/agents/` come from `metrics/agent-loop.json` in
khe-architecture, which this refreshes once a week (estate ADR-044). The
script reads the plans' `**Caught:**` lines that `retro` writes, so a retro
does not run it. In the work account's instance, where `git push` is
refused, stop with one line saying the numbers wait for a session that can
push.

1. In `repos/khe-architecture` on a clean `main`, `git pull --ff-only`.
   Not on `main`, dirty, or the pull fails: stop with one line naming why.
2. From the root, run `bash scripts/agent-metrics.sh --since 2026-10-22
   --json > repos/khe-architecture/metrics/agent-loop.json`: unsandboxed on
   the laptop (it calls gh and reads remote refs), inside the sandbox on
   agent-vm. It takes about five minutes, so run it in the background and
   wait for it to finish.
3. Compare it with the committed file without its date:
   `diff <(git -C repos/khe-architecture show HEAD:metrics/agent-loop.json | jq 'del(.until)') <(jq 'del(.until)' repos/khe-architecture/metrics/agent-loop.json)`.
   No difference: `git -C repos/khe-architecture checkout -- metrics/agent-loop.json`
   and say in one line that no count changed.
4. Otherwise run `bash scripts/check.sh` in `repos/khe-architecture`. When
   it passes, `git -C repos/khe-architecture add metrics/agent-loop.json`,
   then `KHE_REVIEW_SKIP="generated agent-loop snapshot" git -C
   repos/khe-architecture commit -m "agent-loop numbers"` as a command of
   its own, and push after the `@{u}..` check in the root `AGENTS.md`. When
   it fails, restore the file as in step 3 and report the check's line.

The closing message says whether a count changed and what was pushed, and
names the review skip and its reason, as `AGENTS.md` "Workspace hooks" asks.
