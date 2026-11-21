---
name: plan-file
description: How a non-trivial change is planned, handed over and checked in the KHE workspace - the plan file and its ADR criteria, the plan-review subagent, the /goal line with its clauses, the model to run it on, and the opus check of the diff against the plan. Use when entering plan mode, writing or reviewing a plan file, handing over or running a /goal line.
---

# Plan file

The plan, execute and check steps of the `CLAUDE.md` Workflow. Review, See
it working and Close out stay there, since they apply to every change.

- **Plan** a non-trivial change in plan mode, with each step's check
  command. Plan files land in `repos/khe-meta/plans/` (`plansDirectory`).
  The operator does not switch modes: when a task needs a plan, enter plan
  mode yourself with the `EnterPlanMode` tool rather than planning in chat.
  Under its Status and Plan review lines the plan opens with a
  `**TL;DR:**` of two to four plain sentences in the shape of a PR's
  (`AGENTS.md` "Who runs what"): what changes and what the operator will
  notice, what could go wrong, how to undo it. The same TL;DR, in
  Estonian, goes beside the `/goal` line when the plan is handed over.
  The plan's Context lists the decisions it makes, each with its ADR or
  why it needs none. A decision needs one when it is hard to reverse,
  picks between real alternatives, and spans two or more repos or decides
  which repo owns a concern (estate ADR in `khe-architecture/decisions/`),
  or shapes one repo's architecture (that repo's `docs/adr/` or
  `docs/decisions/`; khe-homelab's `docs/service-choices.md`). Not an
  estate ADR: an exception to an estate rule (a point of that ADR), one
  repo's design, one machine's set-up (its runbook) or an agent convention
  (`AGENTS.md`, `CLAUDE.md`). Amend an existing ADR before writing a new
  one: an extension, narrowing or exception edits it in place, and only a
  reversal gets a new ADR (khe-architecture `AGENTS.md` Rules 2 and 4).
  Writing it is a step of the plan, Accepted on the day the operator
  approves the plan. A plan in the area of a Proposed ADR says whether it
  accepts, changes or leaves it, and why.
  After writing the plan file and before handing over the `/goal` line,
  have a subagent without this conversation review it: what does the plan
  get wrong or leave out that would break the goal or correctness, and
  which decision it makes lacks its ADR step, and does the TL;DR still
  match the Steps? Gaps, not style. Verify
  each finding, fix the plan for the real ones, say which
  were dropped, and write `**Plan review:** <n> (<d> dropped)` under the
  plan's Status for `retro`'s Caught line to copy. Plan mode names the file with a random slug and allows no
  other edits, so after leaving it rename the file (`git mv` once
  committed) to a descriptive kebab-case name (`n8n-removal.md`) before
  the `/goal` line names it, then commit and push it (root `AGENTS.md`,
  "Who runs what"), so the run can start on either machine.
- **Execute** a written plan through `/goal`, which only the operator can
  type: end the planning turn with the exact line to paste, a condition
  provable from output plus a turn cap, e.g. `/goal every step in
  repos/khe-meta/plans/x.md is checked, an opus subagent comparing the diff
  to the plan reports no unfixed gaps, grep -c '^## Outcome'
  repos/khe-meta/plans/x.md prints 1, and npm test exits 0 in the output,
  or stop after 20 turns`. The Outcome clause makes the retro part of the
  run. When a step touches a surface `CLAUDE.md` Review names for
  `/security-review`, the line also has the clause "a security-review
  subagent's findings are each fixed or dropped with a reason", since as a
  separate step it gets skipped. Also offer the same line as a
  `mcp__ccd_session__start_session` card, so one click runs it in a fresh
  session. A card started on 2026-11-12 delivered the line to the new
  session as text in its brief, not as an active goal: the new session
  works to it as its task, and the goal evaluator runs only if the operator
  types the `/goal` line there. Say which model the goal session should
  run: `sonnet` when
  every step is mechanical and spelled out, `opus` when steps leave
  judgement calls, and `sonnet` with `/advisor opus` when most steps are
  mechanical but a few leave a call: Sonnet runs the work and consults
  Opus at decision points
  ([advisor](https://code.claude.com/docs/en/advisor)). The operator sets
  both in the new session, since switching models inside a session drops
  the earlier thinking. `/advisor` saves to user settings and an Opus main
  model accepts an Opus advisor, so after the run `/advisor off` keeps it
  from doubling later Opus sessions. The advisor reads the same
  transcript, so it does not replace the opus check below.
  A `/goal` run marks what it is changing, because neither machine can see
  the other's running work. Before its first edit it pulls khe-meta, reads
  the `**Running:**` lines in `plans/*.md`, and stops to ask the operator
  when another plan names a repo this run will change. It then writes
  `**Running:** <laptop|agent-vm> <YYYY-MM-DD> <repo> [<repo> ...]` under
  the plan's Status, leaving khe-meta out of the list, commits and pushes
  that file at once, reads the lines again after the push, and stops to ask
  the operator on an overlap. `retro` removes the line.
- **Check against the plan** at the end of a `/goal` run, before the
  review: a subagent with `model: opus` compares the diff to the plan file.
  Every step implemented, the listed edge cases tested, nothing outside the
  plan's scope changed. The goal evaluator reads only the transcript, so
  "every step is checked" is the executor's own claim until this passes.
  It is a clause of the goal condition because as a separate step it
  gets skipped. Fix the real gaps and say which
  findings were dropped.
