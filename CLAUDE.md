# CLAUDE.md

@AGENTS.md

## Workflow

Built-ins, plus the custom skills in `.claude/skills/`: the UI ones, scoped
to the web apps' source, `plan-file` for planning and `/goal` runs, `retro`,
`next`, which reads what `retro` records when the operator asks what to
do next, `agent-metrics`, the weekly refresh of the numbers on
khe.ee/agents, `print-toy`, the loop from a wish to a printed toy, and
`tellimus`, a makett order's next stage, scoped to khe-makett. Run these without being asked, at
default effort; no `/effort ultracode` or workflows unless the operator asks.
The review roles are agents in `.claude/agents/`, each on opus and without
the Edit and Write tools: `plan-reviewer`, `plan-checker`, `security-reviewer` and
`code-reviewer`. Call them without a `model` parameter, which would
override the file's.

- **Plan** a non-trivial change in plan mode yourself (`EnterPlanMode`)
  and load the `plan-file` skill as you enter it; the `plan-reviewer` agent
  reviews the plan with that skill preloaded.
- **Execute** a written plan through the `/goal` line the `plan-file` skill
  describes.
- **Check against the plan** at the end of a `/goal` run, before the
  review, with the `plan-checker` agent the `plan-file` skill describes.
- **Review** every code change (not docs-only) before committing:
  `/simplify` first, which applies its own fixes for reuse and duplication
  (copied helpers drift apart across repos), then `/code-review` (medium; `high` for risky or public-facing
  changes) over the result. Add `/security-review` when the change touches
  an internet-facing surface (the adventure proxy, nginx, Cloudflare or
  tunnel config, GitHub Actions workflows) or the commit gate. Run it
  through the `security-reviewer` agent: the skill ends its reply with the
  report alone, which in the main loop ends the turn and stalls a `/goal`
  run. On a session that is not opus, run `/code-review` through the
  `code-reviewer` agent.
  Verify each finding against the code, fix the confirmed ones, and say
  which were dropped. The review check and the deliberate skip are in
  `AGENTS.md` "Workspace hooks".
- **See it working** for UI changes: `/run` in the browser pane.
- **Close out** a task after its last commit with the `retro` skill:
  the plan file's Status and Outcome, the roadmap entry it moves, a
  Judgement line when a correction repeats, and the removal of the task's
  own worktrees. A small fix with no plan and no roadmap entry does only
  the removal.
- **Refresh the agent-loop numbers** on khe.ee/agents once a week with the
  `agent-metrics` skill (estate ADR-044), when the operator asks or `next`
  finds them more than a week old; a retro does not.
- **Ask with the question card.** When a turn would end on a choice that
  is the operator's (two to four options, which variant, may I push), ask
  it with `AskUserQuestion`, the recommended option first, not as a prose
  list; likewise before work whose direction is still open. Not for what
  the code or a sensible default answers, and not mid-`/goal` unless the
  run is blocked. A `Stop` prompt hook in `.claude/settings.json` sends a
  turn back when it ends on such a choice in prose; it lets a turn through
  that a hook already sent back, which should let a `/goal` run's turns
  pass.

## Harness facts

The rules every harness's hooks enforce are in `AGENTS.md` "Workspace
hooks"; below is what is Claude Code's own.

- **The gate runs as a `PreToolUse` hook on every Bash call** with
  `"onFailure": "block"`, so a crash, a timeout, a missing script or a missing jq blocks
  every Bash call in every root session, not just commits. It runs under
  macOS `/bin/bash` 3.2. If it breaks, revert `.claude/settings.json` or the
  script by edit, not Bash. A `/code-review` the operator types is not
  recognised as the review, so have Claude run it. `KHE_PR_SKIP`'s reason
  shows as a message to the operator.
- **The laptop's PATH.** The gate runs `check:` on nvm's default Node and
  Homebrew's tools, and the `node-path.sh` `SessionStart` hook puts the same
  two first in the Bash tool's PATH, because the desktop app hands both a
  PATH with every nvm version, oldest first, and `/usr/bin` (macOS's python3
  3.9) before Homebrew (`.claude/hooks/nvm-default.sh`; agent-vm has no
  Homebrew).
- **Parallel sessions' worktree** is one of `repos/<name>`, not a desktop
  worktree of the workspace root, which has no `repos/`.
- **Skills in `repos/<name>/.claude/skills/` do not load from here**
  (gitignored directories are skipped). A needed skill goes in this repo's
  `.claude/skills/`, scoped with `paths:` when it belongs to one area.
  `.agents/skills` is a link to that directory, where Codex reads skills.
  Agent files load the same way, only from this root's `.claude/agents/`
  (discovery stops at the repository root), so a session started inside
  `repos/<name>` has neither.
- **Grep reaches `repos/` only through `.rgignore`**, which negates the
  `.gitignore` entry.
- **The browser pane reads only this root's `.claude/launch.json`**
  (gitignored, per machine), not a repo's own. Commands run from the root,
  so paths start with `repos/<name>/`. Serve a static build with
  `python3 -m http.server <port> --directory <path>`.
- **The Bash sandbox blocks raw TCP and the network tools.** WebSocket
  scripts, `git push`, `gh` and `ssh` need `dangerouslyDisableSandbox:
  true`; `curl` and REST do not. `docker-vm` resolves only with Tailscale up.
- **Sandboxed git may not see every ref.** Branches and worktrees made in
  the main checkout, and remote refs such as `origin/main`, can be missing,
  so `@{u}..` prints nothing and ahead reads 0. Run checks of unpushed
  commits, branches or worktrees with `dangerouslyDisableSandbox: true`.
- **What else blocks commands depends on the Claude instance.** In the work
  account's instance, `~/.claude/guardrails/pretooluse-guard.sh` fails the
  whole Bash command on a recursive `rm`, `git checkout --`, `git reset
  --hard` and other destructive git, kubectl, helm and docker patterns;
  user-settings deny rules refuse any `rm`; managed settings deny reading
  `.env` and `.env.*` (`.example` included), `ssh` and `git push`, so there
  the operator pushes from a handover. The personal instance
  (`CLAUDE_CONFIG_DIR=~/.claude-isiklik`) has none of these: the commit gate
  is the net, and Boundaries still apply. Revert with an edit instead of a
  destructive command, and ask the operator to run anything refused.
  Deleting config entries and bulk enable/disable scripts are stopped by the
  auto mode classifier, not a rule, so the outcome varies; inline Python on
  named entities passes.
- **The personal instance also runs on agent-vm**, a Debian VM with the
  workspace cloned to `~/khe` ([khe-homelab
  `infrastructure/agent-vm.md`](https://github.com/khelias/khe-homelab/blob/main/infrastructure/agent-vm.md)).
  There the config dir is the default `~/.claude`, bash is 5 with gawk and
  upstream gitleaks, the gate runs unchanged and Bash runs in a strict
  sandbox: no `dangerouslyDisableSandbox` retry, outbound to GitHub, npm,
  PyPI, Anthropic, Debian and Hinnavaatlus only, `~/.ssh` and `~/.config/khe`
  unreadable; git, `git push` and `gh` work inside it. Sessions start in auto
  mode; `ssh`, `scp` and the HA scripts run outside the sandbox only when the
  call holds that one command (no `cd`, pipe or redirect), and each asks the
  operator,. The K2 printer is the `k2` MCP server: its `print` asks on every
  call and no other tool of that server does; `openscad`, and `orca-slicer`
  through khe-meta's `k2_slice.py` run in the sandbox without asking. There is
  no browser pane and no Claude in Chrome: Playwright's Chromium is in
  `~/.cache/ms-playwright`, with the static server in the same call because a
  sandboxed command's localhost is its own (runbook "Sandbox"). Jobs that run
  without the operator are GitHub-hosted Actions, never agent-vm. Its memory
  folder is keyed by the VM's workspace path, not the laptop's, and parallel
  sessions use `repos/<name>` worktrees (`AGENTS.md` "Workspace hooks"). A
  claude.ai Projects task (project "KHE") runs there only as a local thread,
  in `~/khe`: a cloud thread reads just `CLAUDE.md`, so it has no gate and no
  skills, and the project's instructions (`projects/khe-instructions.md`)
  forbid it. The laptop's personal instance is the fallback when the VM is
  down.
- **Session start in Claude Code.** The `SessionStart` hook
  `.claude/hooks/session-start.sh` runs the sync in `AGENTS.md` "Workspace
  hooks" and, from the laptop's personal instance, syncs this workspace's
  memory with agent-vm (`scripts/memory-sync.py`); a `memory sync:` line
  names the notes that came from agent-vm, a note that differed on both
  machines or a sync that stopped.
