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
  wraps `.claude/hooks/commit-gate.sh` on `run_command` (plus blocks `--no-verify`, `-n`
  and `-c core.hooksPath=...`), so `git add -A/./-u`, `git commit -a`, `pr: true` branch
  protection, push restrictions (estate ADR-023), the `gitleaks` personal-data scan and
  each repo's `check:` run before every commit or push.
- **Code review before a code commit.** Because Antigravity has no Claude `/code-review`
  skill in its transcript, `.claude/hooks/commit-gate.sh` blocks code commits unless
  prefixed with `KHE_REVIEW_SKIP="<reason>"`. Before committing code here, have a fresh
  review subagent (`invoke_subagent`) inspect the diff, fix confirmed findings, then commit
  with `KHE_REVIEW_SKIP="antigravity review subagent"` and report the findings and skip in
  the reply.
- **Shared skills.** `.agents/skills.json` loads `.claude/skills/` directly without copying.
- **UI verification.** Start local dev servers via `run_command` (`IsDaemon: true`) and
  inspect mobile and desktop widths with the `browser` subagent.
