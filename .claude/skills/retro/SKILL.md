---
name: retro
description: Close out a finished task by recording what it taught - the plan file's Status and Outcome, the roadmap entry it moves, and a proposed AGENTS.md Judgement line when an operator correction repeats. Use after a task's last commit, at the end of a /goal run, or when the operator asks for a retro or wrap-up.
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
- At the end, add `## Outcome`. Its first line is exactly one Caught line,
  which `scripts/agent-metrics.sh` reads:

  `**Caught:** plan review <n> (<d> dropped); plan check <n>; code review <n> (<d> dropped); security review <n|->; operator <n|pending>; push <unchanged|changed|discarded|pending>.`

  Plan review is copied from the plan's `**Plan review:**` line. `<n>`
  counts findings acted on, `<d>` those dropped; `-` marks a check that
  did not run. `operator` (what the operator's look before the push found)
  and `push` (pushed unchanged, changed first, or discarded) stay `pending`
  until the operator says; then update the line in its own khe-meta commit.
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
- Follow-ups the task found go in as new items there.
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
Say what still needs pushing.
