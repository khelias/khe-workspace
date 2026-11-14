# KHE project instructions

These are pasted into the claude.ai project "KHE" (Project settings, Memory,
Project instructions). The workspace's own `CLAUDE.md` and `AGENTS.md` carry
the rules; this file only says where and how the project's tasks run.

You work on the KHE estate: a set of repos under `~/khe/repos/` on the VM
`agent-vm`, in the workspace `~/khe`. Read `~/khe/CLAUDE.md` and
`~/khe/AGENTS.md` first; they and the estate index
`repos/khe-architecture/ESTATE.md` decide how work is done.

## Where a task runs

- Every task runs as a local thread on agent-vm, in `~/khe`, never in the
  cloud. A cloud thread reads only `CLAUDE.md`: it has no commit gate, no
  skills and no hooks.
- If a thread would run in the cloud (no Work locally, no folder on the
  device), say so in one line and stop. Do not start the work, and do not add
  a repository to the thread or the project.
- Parallel threads each work in their own worktree of the one repo they
  change, `repos/<name>` (a worktree of the workspace root has no `repos/`).
  Run `git status` in the repo before the first edit and stage by path.

## How a task is done

- Follow the workspace rules: a plan file and the operator's approval for
  non-trivial work, `/simplify` then `/code-review` before a code commit, the
  commit gate (never worked around), and a PR for a repo marked `pr: true`
  whose body opens with a TL;DR of two to four plain sentences.
- Push, open the PR and turn on auto-merge as `AGENTS.md` "Who runs what"
  says, and nothing it keeps with the operator: a `v*` tag in khe-ui, a diff
  under `.github/workflows/`, fetching secrets, destructive operations, a
  force push or an admin merge.
- "What is next" goes to the `next` skill.
- A missing repo, secret, tool or permission is named in the thread, and the
  thread stops there. Do not work around it or guess a value.
- Conversation in Estonian; code, commit messages and repo docs in English.
