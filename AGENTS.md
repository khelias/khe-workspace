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

The agent runs the whole loop, push and homelab commands included, where its
session allows it
([estate ADR-023](https://github.com/khelias/khe-architecture/blob/main/decisions/023-agent-pushes-where-its-session-allows.md));
where the session refuses `git push` or `ssh` (the work account's Claude
instance), the operator runs them from a handover:

- The agent pushes, opens the PR, turns on auto-merge and runs
  `ssh khe@docker-vm "..."` itself. A handover, where needed, comes once,
  when the work is done, as one copy-pasteable block chained with `&&` in
  the order it must run, cleanup included, so a failure stops the rest.
  Split it only where a step needs checking before the next.
- Kept with the operator in every session: a push that would ship commits
  this session did not make (khe-meta excepted, below), a diff under
  `.github/workflows/`, a `v*` tag
  in khe-ui (it publishes to npm), fetching secrets, and the destructive
  operations under Boundaries. Never a force push, and never an admin merge
  past a pull request's required checks.
- Agent sessions, Claude Code and Antigravity alike, share each repo's
  working tree. Run `git status` in the repo before the first edit; if it
  shows changes this session did not make, work in a worktree of
  `repos/<name>`. Stage by path, never everything.
- Commit locally as normal. Right before a push, `git fetch` that repo and
  confirm the branch is not behind its upstream, then list `git log
  --oneline @{u}..` and stop on any commit this session did not make: the
  push would ship it too. Say in the report what was pushed and where.
- khe-meta is private, holds documents and deploys nothing, so a session
  pushes each commit there right after making it, and that push may carry
  other sessions' commits: otherwise a plan stays on the machine that wrote
  it. When the branch is behind, rebase onto `origin/main` first; stop on a
  conflict, and never force push.
- In a repo marked `pr: true` in `repos/repos.yaml`, agent work reaches
  `main` through a pull request whose required checks pass: commit on a
  branch, then `cd <absolute repo path> && git fetch &&
  git log --oneline origin/main..<branch> && git push -u origin <branch> &&
  gh pr create --head <branch> --title "<title>" --body-file <body file> &&
  gh pr merge <branch> --auto --merge`.
  The check before it reads `origin/main..<branch>` instead of `@{u}..`. A
  PR behind `main` waits for `gh pr update-branch <branch>`, since the
  protection there is strict.
- On the homelab VM: what the agent runs there and what stays the
  operator's is in khe-homelab `AGENTS.md` "Access and operations".
- A session that stops with something only the operator can do first adds
  one line under **Waiting** in the Backlog of `repos/khe-meta/ROADMAP.md`,
  so it does not stay in a chat. Switching a service or a scheduled job off
  or on goes in the plan's Status in the same step, or under Waiting when
  there is no plan.
- The operator approves a fork PR run on a repo with a homelab runner, and
  only after reading its `.github/workflows/` diff (estate ADR-023 point 5; the setting
  is in `ESTATE.md` "Adding a repo").
- The operator reads a PR, not its code. The agent writes its title (what
  changes, in words, never the branch name) and a body file in the session
  scratchpad: a `TL;DR` of two to four plain sentences first (what a
  visitor or the operator will notice, what could go wrong, how to undo
  it), then the checks that ran and the estate ADR it follows. No code,
  no file lists, no private khe-meta links: the PR is public. The same
  TL;DR, in Estonian, goes in the agent's report with the PR link.
- Ask clarifying questions before writing, not after a first draft has
  shipped: every iteration costs a deploy.
- Read-only APIs (Home Assistant, GitHub) the agent uses directly.

## Workspace hooks

What the workspace's hooks enforce binds every harness that loads them:
Claude Code, and Antigravity through its adapter. Each harness's own wiring
and quirks are in `CLAUDE.md` "Harness facts" and `GEMINI.md`.

- A harness that cannot load the workspace commit gate, Codex today, reads
  and advises but does not commit or push in the estate
  ([estate ADR-023](https://github.com/khelias/khe-architecture/blob/main/decisions/023-agent-pushes-where-its-session-allows.md)).
- The gate is `.claude/hooks/commit-gate.sh`, with `hook-bypass.awk` and
  `pii-rules.toml` beside it. Claude Code runs it as a hook on every Bash
  call; Antigravity runs it through `.agents/hooks/commit-gate-adapter.sh`.
- **`git commit` in a repo is gated.** The gate runs that repo's `check:`
  before the commit and blocks it on failure. Fix the cause; never work
  around the gate. Do not run `check:` yourself right before committing;
  the gate already does. It knows a repo listed in `repos/repos.yaml` by its
  git common dir under `repos/` of the session root or the main checkout,
  so a worktree of `repos/<name>` is gated wherever it sits, else by a
  remote that is its `url:` or its checkout. Any other repo inside the
  workspace is blocked; repos outside it, such as scratch repos, pass.
- **The gate requires a code review** before a commit that may include
  code, in every gated repo, private ones included: any staged, unstaged or
  untracked file other than `md txt pdf png jpg jpeg gif webp svg` (a file
  without an extension is code; a rename counts both names). The evidence
  is read from the session transcript, once per session: in Claude Code a
  `Skill` call to `code-review`, in the transcript or a subagent's, in
  Antigravity an `invoke_subagent` of `code-reviewer`. It is checked before
  the personal-data scan and `check:`. `KHE_REVIEW_SKIP="<reason>" git
  commit ...` skips only this check; an empty value or a mention inside a
  message does not. A deliberate skip is reported to the operator with its
  reason. No readable transcript blocks a code commit. Another session's
  dirty files in the same tree count too: work in a worktree.
- **The gate keeps `pr: true` repos off `main`.** In a repo that
  `repos/repos.yaml` marks `pr: true` (estate ADR-023) it refuses a commit
  on `main`, the remote's default branch or a detached HEAD; the push and PR
  for such a repo are in "Who runs what". It runs before the command, so
  `git switch -c x && git commit` in one call is checked against the old
  branch: run the switch as a command of its own first.
  `KHE_PR_SKIP="<reason>" git commit ...` skips only this rule, for an
  emergency; the gate passes the reason to the harness, which shows it to
  the operator in its own way. It may stand beside `KHE_REVIEW_SKIP` in
  either order.
- **The gate refuses rather than passes** when it cannot decide: a commit
  whose repo it cannot resolve, a push or a call it cannot read. What a
  harness's hook does when the gate itself fails is in that harness's file.
- **The gate refuses skipping git hooks**: `--no-verify` and `-n` on a
  commit, `--no-verify` on a push, and core.hooksPath overrides (`-c` or
  `--config-env`, an included config file, `GIT_CONFIG_*` before a commit or
  push, `git config core.hooksPath`), behind any wrapper such as `timeout`
  or `xargs`. `hook-bypass.awk` reads them with shell quoting, so a message
  or heredoc that only mentions one passes. The same awk reads every shell
  command for all the gate's rules, so a quoted, escaped or `$'...'`
  subcommand (`git "commit"`, `git c\ommit`) is still a commit or push, and
  one behind a git option the gate cannot read, or inside `$(...)`,
  backticks or `<(...)`, is refused. Without that file a call that commits,
  pushes or runs `git config` is blocked.
- **The gate also scans for personal data** in every repo, the root
  included, unless `repos/repos.yaml` marks it `private: true`: lines the
  commit adds (staged, unstaged, untracked) and the message, against the
  gitleaks patterns in `pii-rules.toml` (MAC, isikukood, phone, Estonian
  coordinates, e-mail, LAN address). Pattern-only: names and street
  addresses are not caught and stay a judgement call. Commits made by
  merge, cherry-pick, revert or rebase are not scanned, and a same-call
  `git add -f` is refused: force-add first, then commit. A false positive
  gets an allowlist entry with a reason in `pii-rules.toml`.
- **Parallel sessions share each repo's working tree** (the rule is in "Who
  runs what"). The worktree is one of `repos/<name>`; install dependencies
  there before committing. The gate refuses `git add -A`, `git add .`,
  `git add -u` and `git commit -a`, and a commit whose repo it cannot
  resolve (a shell variable in `-C` or `cd`). It follows a `cd`, `pushd` or
  `popd` only as far as the shell would: one in a subshell, a pipeline or a
  `&` list ends there, and one that may not run (after `&&` or `||`, inside
  `if`, `case` or a loop, at the end of a pipeline), like a function
  definition or a `cd` it cannot read (behind `command`, `eval` or an
  option, or as an argument), leaves a later git call without `-C <absolute
  path>` refused. Put the `cd` first in the call or use `git -C`. A plan
  file in `repos/khe-meta/plans/` is committed by its own path, in its own
  commit.
- **The gate also checks pushes** (estate ADR-023): it refuses any force
  push (`--force*`, `-f`, `--mirror`, a `+ref`), deleting `main` or
  `--prune` in any repo, a push that moves `main` of a `pr: true` repo (a
  bare `git push` there from `main` included), a tag push matching a repo's
  `release_tag:` (khe-ui) and `gh pr merge --admin`. It also refuses a push
  it cannot read (a value from a variable, `GIT_DIR`, any global option
  before `push` but `-C`, or `HEAD` after a branch switch in the same call)
  and one that could run a command of its choosing (`--receive-pack`,
  `--exec`, `GIT_SSH*`, `GIT_CONFIG_*`, an ASKPASS). It reads the command
  line only: a git command inside a quoted string with spaces (`ssh
  "..."`, `bash -c '...'`), a script or an alias is not seen, so never
  commit or push on docker-vm.
- **Every session start syncs the repos.** The session-start
  hook, which Claude Code's hook and Antigravity's adapter both run (Codex
  has none yet), fast-forwards each repo under `repos/` that is on a clean
  `main` (`scripts/workspace.sh sync`). The root is never fast-forwarded,
  since its hooks run with the session's own rights: `behind` asks for a pull after
  reading what changed. It prints only what needs a look: `missing`,
  `branch`, `dirty`, `ahead` and `failed` name a repo it did not update,
  `npm ci` one it updated whose lock file changed. A `**Running:**` line it
  lists means a plan is changing the repos it names: ask the operator
  before changing one of them.

## Where the estate is described

- `repos/khe-architecture/ESTATE.md` - the estate index: every repo, what it is
  for, where it is deployed. Start there when it is not obvious which repo owns
  a thing. The estate ADRs are beside it in `repos/khe-architecture/decisions/`
  (public, cited as "estate ADR-NNN"); the estate roadmap and plans stay in the
  private `repos/khe-meta/`.
- `repos/khe-meta/house/` - private house documentation: Home Assistant rollout
  and measurements, HVAC, network, the 3D printer (`k2-printer.md`). Device
  ids, LAN addresses of house devices and anything identifying live here and
  **never** in a public repo.
- Each repo's own `AGENTS.md` - its commands, conventions and operating
  procedure; the ha-estfeed fork has none. `repos/khe-home-assistant/AGENTS.md`
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
- **One fact, one place on the page.** Before adding a summary, a panel or a
  shortcut, check whether what it repeats sits right below it; a second block
  for the same day or the same list is the repetition the operator keeps
  removing.
- **Research before the first answer.** For advice, a tool or a setup change,
  search the web across several current sources before answering or changing
  anything, and look at the whole picture, not only the slice asked about. A
  change made on what the agent already knew is the one that gets undone.
- **Write short from the first draft.** Each user-facing string makes one
  point; an explanation beside the thing it explains, in a legend, sublabel
  or link line, is cut before the operator sees it.

## Code and docs

- Comments only for a non-obvious why, never for what the code does or how
  it got there: history ("previously", "now uses", "V4:") goes in the commit
  message.
- Trivial changes need no doc update. A touched feature that is documented
  nowhere gets a one-line summary. When unsure whether to document, ask.
- After a non-trivial change (new feature, moved files, removed concept,
  behaviour shift), sweep `README.md`, `ARCHITECTURE.md`, `ROADMAP.md`, the
  repo's and the root's `AGENTS.md`/`CLAUDE.md`, affected ADRs and overlapping
  `docs/*.md`, and fix what is now wrong in the same commit. The test: would a
  fresh agent form a misleading picture? A judgement call, not a hard rule.
  An affected ADR is amended in place, with its Status date moved to that
  day, when the change extends, narrows or makes an exception to it; a
  reversal gets a new ADR and leaves the old one as a Superseded stub, and a
  decision that moves to one repo's docs leaves a Moved stub
  (khe-architecture `AGENTS.md` Rules 3 and 4).
- A structural change (named library bump, moved files, new decision,
  changed build/test/deploy command, new invariant) updates that repo's
  `AGENTS.md` in the same commit.
- **Link, don't restate.** Each rule has one home and every other file
  cites it: the decision in the estate ADR, workspace-wide agent behaviour
  here, the workspace hooks' rules in "Workspace hooks" here, Claude Code's
  harness facts (sandbox, instances, skills) in `CLAUDE.md`, Antigravity's
  in `GEMINI.md`, a shared tool's usage in its owning repo's `AGENTS.md` (the design check in
  khe-ui, VM operations in khe-homelab), repo set-up in `ESTATE.md` "Adding
  a repo". Copies drift, and an agent cannot tell which one is current;
  copying a rule into every repo it constrains made each decision a sweep.
  A repo's `AGENTS.md` holds only what is particular to it (a path, an
  exemption, a check, a deviation), cites the ADR as estate ADR-NNN with a
  link, and opens with a pointer to this file, so a session started inside
  one repo still finds the workspace rules.
- An estate ADR that becomes Accepted updates the one home of its rule, and
  a repo's `AGENTS.md` only where something particular to that repo changes
  (a path, an exemption, a check, a deviation).
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
- Adding an automated writer anywhere (a bot that merges, a scheduled job, an
  automation that acts) puts it in the writer register in khe-meta's
  `AMBITIONS.md` in the same change
  ([estate ADR-007](https://github.com/khelias/khe-architecture/blob/main/decisions/007-automated-writers.md)).
  This root's own Renovate automerge (Actions minor and patch once three days
  old, digests, pins) is undone by reverting its commit on `main`.
- Every web app runs `khe-design-lint` from `@khelias/ui` in its lint
  ([estate ADR-035](https://github.com/khelias/khe-architecture/blob/main/decisions/035-family-shell-and-design-check-with-its-exceptions.md)),
  against a committed baseline that only shrinks; its usage is in khe-ui
  `AGENTS.md` "The design check".
- Verification artifacts (screenshots, saved pages, one-off scripts) go to the
  session scratchpad, not into a repo or the workspace root.

## Boundaries

- **Ask first:** destructive operations (`rm -rf`, `git reset --hard`,
  dropping tables, force-push), rewriting published commits, new
  dependencies, CI/CD changes.
- **Never:** skip git hooks (`--no-verify`); commit secrets or credentials;
  put agent attribution (`Co-Authored-By`, "generated with") in commits or
  PRs, forks included.
