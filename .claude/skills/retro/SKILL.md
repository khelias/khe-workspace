---
name: retro
description: Close out a finished task by recording what it taught - the plan file's Status and Outcome, the roadmap entry it moves, and a proposed AGENTS.md Judgement line when an operator correction repeats - and by removing the worktrees it made. Use after a task's last commit, at the end of a /goal run, or when the operator asks for a retro or wrap-up.
---

<!-- Modelled on /revise-claude-md in github.com/anthropics/claude-plugins-official (claude-md-management). -->

# Retro

Record only what a future session would get wrong without it. Most tasks
leave zero to two such things. A retro that writes nothing is a normal
result: say so in one line. Run it after the task's last commit, so the
shas it records are final.

## 1. Gather

- The plan file this task executed, in `repos/khe-meta/plans/`, if any.
- The commits this session made, per repo touched (`git -C <repo> log --oneline`).
- The operator's corrections in this conversation.

## 2. Plan file

Skip when the task had no plan.

- Under the title, set `**Status:** done (<repo> \`<sha>\`)`, the form the
  existing plans use, with more than one repo or sha separated by `;`.
  Steps left over: `partly done`, plus what is left.
- Remove the plan's `**Running:**` line (`plan-file` skill, Execute), also
  when the run is only partly done: no session is working on it any more.
- At the end, add `## Outcome`. Its first line is exactly one Caught line,
  which `scripts/agent-metrics.sh` reads:

  `**Caught:** plan review <n> (<d> dropped); plan check <n>; code review <n> (<d> dropped); security review <n|->; operator <n|pending>; push <unchanged|changed|discarded|pending>.`

  Plan review is copied from the plan's `**Plan review:**` line. `<n>`
  counts findings acted on, `<d>` those dropped; `-` marks a check that
  did not run. `operator` (what the operator's look before the push found)
  and `push` (pushed unchanged, changed first, or discarded): when the
  agent pushed itself (estate ADR-023), they are `operator -` and `push
  unchanged`; only a push handed over stays `pending` until the operator
  says, and then the line is updated in its own khe-meta commit.
- After it, at most about ten lines of prose: what differs from the plan
  and why, what was left out and where it went, review findings that were
  dropped, what was verified only partly. A plan that ran as written says
  so in one line.

## 3. Roadmap

- Find the entry the task belongs to: the repo's own `ROADMAP.md`, or
  `repos/khe-meta/ROADMAP.md` for cross-repo and workspace work.
- Mark it done in that file's own style (a dated "Done YYYY-MM-DD" bullet,
  a tick, a removed item). Link the plan only from khe-meta: a public
  repo's roadmap does not link the private khe-meta plans.
- In khe-meta, a finished item also leaves the Backlog at the top of
  `ROADMAP.md`, and a follow-up gets a line there in its place in the order.
- Follow-ups the task found go in as new items there.
- What the task leaves for the operator goes under **Waiting** in that
  Backlog (root `AGENTS.md`, "Who runs what"), and a Waiting line the task
  finished is removed.
- No entry and no follow-up: leave the roadmap alone.

## 4. Repeated corrections

For each operator correction in this session, look for the same one in the
auto memory (`MEMORY.md` and its feedback files) and, when unsure, in past
session transcripts. Seen before: propose a one-line entry for the root
`AGENTS.md` Judgement list, or a hook if it can be checked mechanically, as
a diff with a one-line reason. Apply it only on the operator's yes. Under
`/goal`, with no operator to answer, put the proposal in the Outcome and the
closing message instead. First time: nothing here. Auto memory keeps
one-off corrections.

## 5. Not part of a retro

- New memory files: auto memory saves corrections as they happen.
- `CLAUDE.md` or `AGENTS.md` edits other than an approved Judgement line.
- New doc files.

## 6. Commit

Commit the plan file by its own path in its own khe-meta commit, each
roadmap edit in its own repo, and an approved Judgement line in the root.
Push them where the session allows (root `AGENTS.md`, "Who runs what"),
else say what still needs pushing.

## 7. Agent-loop numbers

The counts on `khe.ee/agents/` come from `metrics/agent-loop.json` in
khe-architecture, which this step refreshes after the commits above (estate
ADR-044). In the work account's instance, where `git push` is refused, skip
it with one line saying the numbers wait for the next retro.

- In `repos/khe-architecture` on a clean `main`, `git pull --ff-only`.
  Not on `main`, dirty, or the pull fails: skip with one line naming why.
- From the root, run `bash scripts/agent-metrics.sh --since 2026-10-22
  --json > repos/khe-architecture/metrics/agent-loop.json`: unsandboxed on
  the laptop (it calls gh and reads remote refs), inside the sandbox on
  agent-vm. It takes about five minutes, so run it in the background and
  wait for it to finish.
- Compare it with the committed file without its date:
  `diff <(git -C repos/khe-architecture show HEAD:metrics/agent-loop.json | jq 'del(.until)') <(jq 'del(.until)' repos/khe-architecture/metrics/agent-loop.json)`.
  No difference: `git -C repos/khe-architecture checkout -- metrics/agent-loop.json`
  and say in one line that no count changed.
- Otherwise run `bash scripts/check.sh` in `repos/khe-architecture`. When
  it passes, `git -C repos/khe-architecture add metrics/agent-loop.json`,
  then `KHE_REVIEW_SKIP="generated agent-loop snapshot" git -C
  repos/khe-architecture commit -m "agent-loop numbers"` as a command of its
  own, and push after the `@{u}..` check in the root `AGENTS.md`. When it fails,
  restore the file as above and report the check's line. The closing message
  names the review skip and its reason, as `CLAUDE.md` asks.

## 8. Worktrees

Last, remove each `repos/<name>` worktree this session made for the task.
Another session's worktree stays, and so does the desktop app's own under
`.claude/worktrees/`. Run this from the main checkout, after `git -C <main
checkout> fetch`, and remove a worktree only when all of these hold:

- `git -C <worktree> merge-base --is-ancestor HEAD origin/main` succeeds, so
  a pull request still waiting to merge keeps its worktree.
- `git -C <worktree> status --porcelain` lists nothing. A `node_modules` or
  `.venv` symlink counts as untracked: delete the link alone with a plain
  `rm`.
- No later run of the same plan needs it.

Then `git -C <main checkout> worktree remove <absolute path>`, never with
`--force`, and `git -C <main checkout> branch -d <branch>`. When `-d` refuses
only because the main checkout is behind, `-D` is safe: the first check has
already put the branch on `origin/main`. Name in the closing message any
worktree left behind and why.
