---
name: next
description: Answer "what should I do next" from what the estate already records - unfinished work first, then ready roadmap items, all sized against the time the operator has and checked against git. Read-only; the counterpart of retro. Use when the operator asks what to do next, what is pending, or "mis järgmiseks".
---

# Next

`retro` writes the estate's state; this reads it. Write nothing: no roadmap,
plan or tracker edits. The answer is short, and in Estonian like the rest
of the conversation. Do not quote LAN addresses, MACs or device ids from
plan or house files; say what the item is instead.

## 1. Time budget

Take it from the operator's words (`/next õhtu`). Otherwise ask once with
`AskUserQuestion`: about an hour, an evening, or a weekend. It sizes
everything in steps 2 and 3.

## 2. Unfinished work

Repos, PRs and CI in one call from the workspace root:

```bash
for r in $(awk '/^[[:space:]]*- name:/{print $3}' repos/repos.yaml); do
  git -C repos/$r fetch --quiet
  gh pr list --repo khelias/$r --state open --json number,title,author,createdAt,statusCheckRollup --jq ".[]|\"$r#\(.number) \(.author.login) \(.createdAt[:10]) ci=\([.statusCheckRollup[]?|(.conclusion // .state)]|unique|join(\",\")) \(.title)\""
  gh run list --repo khelias/$r --branch main --status completed --limit 20 --json workflowName,conclusion --jq "group_by(.workflowName)|map(.[0])|.[]|select(.conclusion!=\"success\")|\"$r CI: \(.workflowName) \(.conclusion)\""
done
scripts/workspace.sh status
```

- Ahead of upstream: unpushed commits (`git -C repos/<name> log --oneline
  @{u}..`). Behind: a pull. Dirty: untracked `__pycache__` and other build
  output is leftover, not work; any other dirty file may be another
  session's, so say so rather than call it abandoned.
- A Renovate PR is held for review once its CI is green and it is more than
  a day old. A failed CI on a PR or on `main` is an item of its own.
- A push, a merge of a `khe-homelab` PR (it deploys to the running host)
  and anything on the VM are the operator's: offer them as `AGENTS.md`
  describes under "Who runs what".

Plans in `repos/khe-meta/plans/`: open `- [ ]` steps, or a Status line (in
any of its forms) that is not done. A plan with no Status, no Outcome and
no ticked step whose last commit (`git log -1 --format=%cs`) is under 14
days old may be written but not started. Plans from before `retro`
(2026-10-17) often lack Status and Outcome; that alone does not make them
unfinished. Then sort the open steps:

- A push step is done when that repo is not ahead of upstream.
- A step that runs only on a condition ("if HA does not come up") is not
  open.
- A step whose work is in the repo's `git log` since the plan's date is
  done; that is drift, for step 4.
- A step only the host or a UI can show (Proxmox, NPM, UniFi, runner
  backups) goes in one line of things to check by hand, not counted.
- A plan named like credentials (`*password*`, `*secret*`): do not open
  it. Give its name and open-step count, and let the operator size it.

## 3. Ready roadmap items

Sources, in this order: Horizon 1 of `repos/khe-meta/ROADMAP.md`, the
near-term sections of each repo's `ROADMAP.md`, and the first measurable
steps in `repos/khe-meta/AMBITIONS.md` and the repos' Ambitions sections.
Read them even when step 2 found plenty: the operator may want new work.

- **Ready.** Drop an item whose "Waits for" names something not yet done,
  checked at the blocker's source. Note the blocker that holds up the most
  items: clearing it may be the best candidate.

## 4. Drift

Only for what steps 2 and 3 looked at, not a full audit: a plan step or
roadmap item still open whose work is committed, or marked done with no
commit to show; a `Last reviewed:` line older than 30 days (a file without
one is fine). Name it; fixing it is `retro`'s job or the operator's.

## 5. Rank and answer

Rank everything from steps 2 and 3 together:

1. Time-sensitive: a date, a season or a release makes it due (the monthly
   Home Assistant release PR, trip dates in khe-trips, the heating season
   in `repos/khe-meta/house/`, a grace period ending).
2. Unfinished before new: finish before starting.
3. Internet-facing or security work before the rest.
4. Older before newer.

Size each item: its own Estimate when it has one, otherwise yours, marked
as yours. An item too big for the budget can be named with the slice that
fits.

The answer: at most three items, each with why now, its size against the
budget and its one next action, and which one you recommend. Then, one line
each and only when there is something: the rest still open, decisions
waiting on the operator, things to check by hand, housekeeping (a pull,
leftover files), drift. Blocked items stay out, except the one blocker
worth clearing.

End by asking which to take. A non-trivial pick goes to plan mode as
`CLAUDE.md` describes.
