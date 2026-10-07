# AGENTS.md

Personal preferences for every repo in the KHE workspace. Commands and
conventions of one repo live in `repos/<name>/AGENTS.md`.

## Communication

- Conversation in Estonian. Code, identifiers, file names, comments, commit
  messages and repo docs in English.
- User-facing strings and translations: grammatically correct Estonian, no
  machine-translated approximations. If unsure, ask.
- Match response weight to question weight: routine work gets terse output,
  decision-heavy work gets the reasoning trail. The operator works with the
  agent partly to learn, not just to receive results.
- No AI tells: no emoji, no em-dashes (use a hyphen or comma, or rephrase),
  no bloated openings or closings, no headers, tables or bullet lists on
  simple answers.

## Who runs what

The agent prepares, the operator executes anything that leaves this machine or
touches a running host:

- `git push`, `ssh`, and any command against the homelab VM are the operator's.
  Hand them over as complete, copy-pasteable command blocks, one command per
  block, in the order they must run. A half-given chain costs a round trip.
- Commit locally as normal. Say plainly what still needs pushing. Before
  handing over a push, list `git log --oneline @{u}..` for that repo and name
  any commit this session did not make: the push ships them too.
- Ask clarifying questions before writing, not after the operator has pushed
  a first draft: every iteration costs them a push.
- Read-only APIs (Home Assistant, GitHub) the agent uses directly.

## Where the estate is described

- `repos/khe-meta/ESTATE.md` - the estate index: every repo, what it is for, where
  it is deployed. Start there when it is not obvious which repo owns a thing.
- `repos/khe-meta/house/` - private house documentation: Home Assistant rollout
  and measurements, HVAC, network. Device ids, LAN addresses of house devices
  and anything identifying live here and **never** in a public repo.
- Each repo's own `AGENTS.md` - its commands, conventions and operating
  procedure; the ha-estfeed fork has none. `repos/khe-homelab/AGENTS.md`
  has the Home Assistant procedure.
- `repos/repos.yaml` - the repos and each one's `check:` command;
  `scripts/workspace.sh status` shows branch and dirty state per repo.

## Verification

Before calling a change done, run the repo's `check:` from `repos/repos.yaml`
and, for UI changes, look at it in a browser at mobile and desktop width.
Report failures as failures. If it cannot be verified here, say so.

## Judgement

Corrections the operator has had to make more than once. When a correction
repeats one made before (check memory and past transcripts), propose a
one-line entry here, or a hook if it can be checked mechanically. Do not add
it unasked; a one-off correction goes to memory.

- **Check a fact at its source before calling it a problem.** One row of data
  is not a finding. Do not recommend undoing a decision, a booking or a
  setting on the strength of a single number that has not been verified where
  it came from.
- **Keep effort and payoff in proportion.** A recommendation that costs money
  or a weekend has to be worth it against what is already in place. Say what
  the existing data or hardware already gives before proposing more of it.
- **Ask when people actually do the thing before optimising timing.** A
  schedule that is right on paper and wrong for the household is wrong. Pin
  down the moment that matters rather than the whole window.
- **Look for the earlier work before writing a new plan.** Docs, git history,
  plan files and past session transcripts usually hold a decision that was
  already made; continuing it beats re-deciding it.
- **Prefer the current stable version.** Check what the newest stable release
  is before pinning; starting from an outdated base costs more over time than
  the upgrade risk it avoids.
- **Do not inherit a number without checking it.** A figure carried over from
  an older document is not evidence, and inventing a justification for it is
  worse than saying it is unverified.
- **Write longer plans to a file, not into the conversation.** A plan that
  only exists in chat is lost by the next session.

## Code and docs

- Comments only for a non-obvious why, never for what the code does.
- Trivial changes need no doc update. A touched feature that is documented
  nowhere gets a one-line summary. When unsure whether to document, ask.
- After a non-trivial change (new feature, moved files, removed concept,
  behaviour shift), sweep `README.md`, `ARCHITECTURE.md`, `ROADMAP.md`, the
  repo's and the root's `AGENTS.md`/`CLAUDE.md`, affected ADRs and overlapping
  `docs/*.md`, and fix what is now wrong in the same commit. The test: would a
  fresh agent form a misleading picture? A judgement call, not a hard rule.
  An affected ADR gets a new ADR that supersedes it, or a fix to its Status
  line or links, never an edit of its decision.
- A structural change (named library bump, moved files, new decision,
  changed build/test/deploy command, new invariant) updates that repo's
  `AGENTS.md` in the same commit.
- In `AGENTS.md` files prefer descriptive facts over prohibitions: "Tailwind
  v3 currently" beats "DO NOT use v4", which goes silently wrong the day v4
  lands. Hard prohibitions stay for security and invariants, with an override
  path ("without an ADR").
- A README is for people and holds what rarely changes: what the repo is and
  why, the few commands to run it, where it lives, and links to the rest. No
  versions, counts, file trees, full command lists or rules: those live in
  `package.json`, `AGENTS.md`, `ARCHITECTURE.md` or the code, and a copy in
  the README is the one that goes stale. The CI badge is the live status.
- Edit existing docs; do not add new doc files (READMEs, CHANGELOGs) unless
  asked.
- Verification artifacts (screenshots, saved pages, one-off scripts) go to the
  session scratchpad, not into a repo or the workspace root.

## Boundaries

- **Ask first:** destructive operations (`rm -rf`, `git reset --hard`,
  dropping tables, force-push), rewriting published commits, new
  dependencies, CI/CD changes.
- **Never:** skip git hooks (`--no-verify`); commit secrets or credentials;
  put agent attribution (`Co-Authored-By`, "generated with") in commits or
  PRs, forks included.
