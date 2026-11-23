# GEMINI.md

Antigravity is configured here as a full coding agent for the KHE estate alongside
Claude Code. Workspace-wide preferences, repo index pointers (`ESTATE.md`,
`repos/repos.yaml`), push rules and boundaries come from `AGENTS.md`, which loads
alongside this file.

## Additional pointers

- `repos/khe-meta/ROADMAP.md` and `repos/khe-meta/plans/` - current cross-repo work and active plans.
- `CLAUDE.md` - its "Workflow" applies here through the tool mapping below; its "Harness facts" are Claude Code's own (`agent-vm` among them). Antigravity does not run Claude's built-in skills.

## Antigravity's own

- **Commits and pushes go through the same gate.** `.agents/hooks/commit-gate-adapter.sh`
  wraps `.claude/hooks/commit-gate.sh` on `run_command`, so every rule in `AGENTS.md`
  "Workspace hooks" applies here too. Two differences from Claude Code: the adapter denies
  when `jq`, the payload or the gate is missing and on any non-zero gate exit, but
  `.agents/hooks.json` has no `onFailure`, so what an adapter crash or its timeout does is
  Antigravity's default, unverified; and the gate's `KHE_PR_SKIP` message becomes a
  `force_ask`, so the skip asks for your approval.
- **Code review before a code commit.** Before committing code, invoke the
  `code-reviewer` subagent (`.agents/agents/code-reviewer.md`) over the diff, verify and
  fix confirmed findings, then commit. The gate reads that `invoke_subagent` call from
  the session transcript as the review. The skip stays a rare, deliberate exception (`AGENTS.md` "Workspace hooks").
- **Session start sync.** `.agents/hooks/session-start-adapter.sh` runs
  `scripts/workspace.sh sync` and `running` on `SessionStart` (without Claude's
  `memory-sync.py`). Ask the operator before editing any repo listed under a
  `**Running:**` plan.
- **Shared skills.** `.agents/skills.json` loads `.claude/skills/` directly without copying.
  Where they name Claude tools: the question card is `ask_question`, a subagent is
  `invoke_subagent`, and `/goal` is user-triggered in the Antigravity chat UI (using
  `code-reviewer` rather than a Claude-only `opus` subagent clause).
- **UI verification.** Start local dev servers via `run_command` (`IsDaemon: true`) and
  inspect mobile and desktop widths with the `browser` subagent.
