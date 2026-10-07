# khe-workspace

[![CI](https://github.com/khelias/khe-workspace/actions/workflows/ci.yml/badge.svg)](https://github.com/khelias/khe-workspace/actions/workflows/ci.yml)

Workspace root for the KHE estate. Open this folder in Claude Code, Codex or
any tool that reads [`AGENTS.md`](https://agents.md/): every KHE repo sits
under `repos/`, and the AI-agent configuration sits here, once.

```text
khe-workspace/
  AGENTS.md              personal preferences, tool-agnostic
  CLAUDE.md              imports AGENTS.md and the estate index
  .claude/               settings and the commit-gate hook
  repos/repos.yaml       the repos this workspace clones, with their checks
  repos/<name>/          independent clones, gitignored
  scripts/workspace.sh   clone | pull | status
```

## Setup

```bash
git clone https://github.com/khelias/khe-workspace.git
cd khe-workspace
scripts/workspace.sh clone
```

`scripts/workspace.sh status` shows each repo's branch and dirty state;
`pull` fast-forwards the clean ones. Nothing outside this folder is touched,
so `~/.claude/` and `~/.codex/` keep serving other projects.

## Why this shape

- **Plain nested clones, not submodules.** Every repo is worked on at its
  latest `main` and deploys on its own; submodules would add a pin-bump
  commit here for each change elsewhere.
- **Gitignored `repos/` has two side effects in Claude Code**, both handled:
  Grep skips it (`.rgignore` puts it back), and skills inside a repo load
  only in a session started in that repo.
- **Built-ins over custom skills.** Plan mode, `/goal`, `/code-review` and
  `/run` cover plan, execute, review and verify; `CLAUDE.md` says when to
  use each. A custom skill is added only for knowledge no built-in can have.
- **Small on purpose.** Standards ([agents.md](https://agents.md/)) over
  frameworks, and every file earns its place.

The layout follows the common 2026 multi-repo pattern for coding agents, see
[Repo-of-Repos](https://raffertyuy.com/raztype/repo-of-repos-pattern/) and
[Structuring Claude Code for multi-repo workspaces](https://karun.me/blog/2026/03/26/structuring-claude-code-for-multi-repo-workspaces/).

## License

MIT - see [LICENSE](LICENSE).
