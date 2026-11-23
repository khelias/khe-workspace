# GEMINI.md

Antigravity is configured here as a full coding agent for the KHE estate alongside
Claude Code. Workspace-wide preferences, repo index pointers (`ESTATE.md`,
`repos/repos.yaml`), push rules and boundaries come from `AGENTS.md`, which loads
alongside this file.

## Additional pointers

- `repos/khe-meta/ROADMAP.md` and `repos/khe-meta/plans/` - current cross-repo work and active plans.
- `CLAUDE.md` - reference for the Claude Code workflow (`/goal`, `/code-review`, `agent-vm`); Antigravity does not run Claude's built-in skills.

## Harness facts here

- **Commits and pushes go through the same gate.** `.agents/hooks/commit-gate-adapter.sh`
  wraps `.claude/hooks/commit-gate.sh` on `run_command`, so every rule of the gate in
  `CLAUDE.md` "Harness facts" applies here too, the hook-bypass check included.
- **Code review before a code commit.** Before committing code, invoke the
  `code-reviewer` subagent (`.agents/agents/code-reviewer.md`) over the diff, verify and
  fix confirmed findings, then commit. The gate reads that `invoke_subagent` call from
  the session transcript as the review. `KHE_REVIEW_SKIP="<reason>"` stays a rare,
  deliberate exception, reported to the operator with its reason.
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
