# CLAUDE.md

@AGENTS.md
@repos/khe-architecture/ESTATE.md

## Workflow

Built-ins, plus the custom skills in `.claude/skills/`: the UI ones, scoped
to the web apps' source, and `retro`. Run these without being asked, at default
effort; no `/effort ultracode` or workflows unless the operator asks.

- **Plan** a non-trivial change in plan mode, with each step's check
  command. Plan files land in `repos/khe-meta/plans/` (`plansDirectory`).
  The operator does not switch modes: when a task needs a plan, enter plan
  mode yourself with the `EnterPlanMode` tool rather than planning in chat.
  The plan's Context lists the decisions it makes, each with its ADR or
  why it needs none. A decision needs one when it is hard to reverse,
  picks between real alternatives, and spans two or more repos or decides
  which repo owns a concern (estate ADR in `khe-architecture/decisions/`),
  or shapes one repo's architecture (that repo's `docs/adr/` or
  `docs/decisions/`; khe-homelab's `docs/service-choices.md`). Writing it
  is a step of the plan, Accepted on the day the operator approves the
  plan; a changed Accepted decision gets a superseding ADR in the same
  way. A plan in the area of a Proposed ADR says whether it accepts,
  changes or leaves it, and why.
  After writing the plan file and before handing over the `/goal` line,
  have a subagent without this conversation review it: what does the plan
  get wrong or leave out that would break the goal or correctness, and
  which decision it makes lacks its ADR step? Gaps, not style. Verify
  each finding, fix the plan for the real ones, say which
  were dropped. Plan mode names the file with a random slug and allows no
  other edits, so after leaving it rename the file (`git mv` once
  committed) to a descriptive kebab-case name (`n8n-removal.md`) before
  the `/goal` line names it.
- **Execute** a written plan through `/goal`, which only the operator can
  type: end the planning turn with the exact line to paste, a condition
  provable from output plus a turn cap, e.g. `/goal every step in
  repos/khe-meta/plans/x.md is checked, an opus subagent comparing the diff
  to the plan reports no unfixed gaps, grep -c '^## Outcome'
  repos/khe-meta/plans/x.md prints 1, and npm test exits 0 in the output,
  or stop after 20 turns`. The Outcome clause makes the retro part of the
  run. Also offer the same line as a `spawn_task` chip,
  so one click runs it in a fresh session; whether the chip's prompt runs
  as the slash command is unverified, so check the new session shows the
  goal active. Say which model the goal session should run: `sonnet` when
  every step is mechanical and spelled out, `opus` when steps leave
  judgement calls. The operator sets it in the new session, since switching
  models inside a session drops the earlier thinking.
- **Check against the plan** at the end of a `/goal` run, before the
  review: a subagent with `model: opus` compares the diff to the plan file.
  Every step implemented, the listed edge cases tested, nothing outside the
  plan's scope changed. The goal evaluator reads only the transcript, so
  "every step is checked" is the executor's own claim until this passes.
  It is a clause of the goal condition because as a separate step it
  gets skipped. Fix the real gaps and say which
  findings were dropped.
- **Review** every code change (not docs-only) before committing:
  `/simplify` first, which applies its own fixes for reuse and duplication
  (copied helpers drift apart across repos), then `/code-review` (medium; `high` for risky or public-facing
  changes) over the result. Add `/security-review` when the change touches
  an internet-facing surface (the adventure proxy, nginx, Cloudflare or
  tunnel config, GitHub Actions workflows) or the commit gate. Run it
  through a subagent: the skill ends its reply with the report alone, which
  in the main loop ends the turn and stalls a `/goal` run.
  Skills can pin a model and whether this one does is unverified, so after
  a `sonnet` goal ask the operator to switch the session to `opus` first.
  Verify each finding against the code, fix the confirmed ones, and say
  which were dropped. The commit gate blocks a code commit until a
  `/code-review` has run in the session; a deliberate skip prefixes the
  commit with `KHE_REVIEW_SKIP="<reason>"` and is reported to the operator
  with the reason.
- **See it working** for UI changes: `/run` in the browser pane.
- **Close out** a task after its last commit with the `retro` skill:
  the plan file's Status and Outcome, the roadmap entry it moves, and a
  Judgement line when a correction repeats. A small fix with no plan and
  no roadmap entry skips it.

## Harness facts

- **`git commit` in a repo is gated.** `.claude/hooks/commit-gate.sh` runs
  that repo's `check:` before the commit and blocks it on failure. Fix the
  cause; never work around the gate. Do not run `check:` yourself right
  before committing; the gate already does. It knows a repo listed in
  `repos/repos.yaml` by its git common dir under `repos/` of the session
  root or the main checkout, so a worktree of `repos/<name>` is gated
  wherever it sits, else by a remote that is its `url:` or its checkout.
  Any other repo inside the workspace is blocked; repos outside it, such as
  scratch repos, pass.
- **The gate requires a code review** before a commit that may include
  code, in every gated repo, private ones included: any staged, unstaged or
  untracked file other than `md txt pdf png jpg jpeg gif webp svg` (a file
  without an extension is code; a rename counts both names). The evidence
  is a `Skill` call to `code-review` in the session transcript or a
  subagent's, once per session; a `/code-review` the operator types is
  not recognised, so have Claude run it. It is checked before the personal-data scan and `check:`.
  `KHE_REVIEW_SKIP="<reason>" git commit ...` skips only this check; an
  empty value or a mention inside a message does not. No readable
  transcript blocks a code commit. Another session's dirty files in the
  same tree count too: work in a worktree.
- **The gate fails closed.** Its hook has `"onFailure": "block"`, so a
  crash, a timeout or a missing script blocks every Bash call in every
  root session, not just commits. It runs under macOS `/bin/bash` 3.2. If it
  breaks, revert `.claude/settings.json` or the script by edit, not Bash.
- **The gate also scans for personal data** in every repo, the root
  included, unless `repos/repos.yaml` marks it `private: true`: lines the
  commit adds (staged, unstaged, untracked) and the message, against the
  gitleaks patterns in `.claude/hooks/pii-rules.toml` (MAC, isikukood,
  phone, Estonian coordinates, e-mail, LAN address). Pattern-only: names
  and street addresses are not caught and stay a judgement call. Commits
  made by merge, cherry-pick, revert or rebase are not scanned, and a
  same-call `git add -f` is refused: force-add first, then commit. A false
  positive gets an allowlist entry with a reason in `pii-rules.toml`.
- **Parallel sessions share each repo's working tree.** Run `git status` in
  the repo before the first edit; if it shows changes this session did not
  make, another session is there: work in a worktree of `repos/<name>`
  (not a desktop worktree of the workspace root, which has no `repos/`) and
  install dependencies there before committing. Stage by path: the gate
  refuses `git add -A`, `git add .`, `git add -u` and `git commit -a`, and
  a commit whose repo it cannot resolve (a shell variable in `-C` or `cd`).
  A plan file in `repos/khe-meta/plans/` is committed by its own path, in its
  own commit.
- **Skills in `repos/<name>/.claude/skills/` do not load from here**
  (gitignored directories are skipped). A needed skill goes in this repo's
  `.claude/skills/`, scoped with `paths:` when it belongs to one area.
- **Grep reaches `repos/` only through `.rgignore`**, which negates the
  `.gitignore` entry.
- **The browser pane reads only this root's `.claude/launch.json`**
  (gitignored, per machine), not a repo's own. Commands run from the root,
  so paths start with `repos/<name>/`. Serve a static build with
  `python3 -m http.server <port> --directory <path>`.
- **The Bash sandbox blocks raw TCP.** WebSocket scripts need
  `dangerouslyDisableSandbox: true`; `curl` and REST do not.
- **This machine blocks commands outside this repo's control.**
  `~/.claude/guardrails/pretooluse-guard.sh` fails the whole Bash command on
  a recursive `rm`, `git checkout --`, `git reset --hard` and other
  destructive git, kubectl, helm and docker patterns. User-settings deny
  rules refuse any `rm`; managed settings deny reading `.env` and `.env.*`
  (`.example` included), `ssh` and `git push`. Revert with an edit instead,
  and ask the operator to run anything refused. Deleting config entries and
  bulk enable/disable scripts are stopped by the auto mode classifier, not a
  rule, so the outcome varies; inline Python on named entities passes.
