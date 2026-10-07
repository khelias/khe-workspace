# CLAUDE.md

@AGENTS.md
@repos/khe-architecture/ESTATE.md

## Workflow

Built-ins, no custom skills. Run these without being asked, at default
effort; no `/effort ultracode` or workflows unless the operator asks.

- **Plan** a non-trivial change in plan mode, with each step's check
  command. Plan files land in `repos/khe-meta/plans/` (`plansDirectory`).
  The operator does not switch modes: when a task needs a plan, enter plan
  mode yourself with the `EnterPlanMode` tool rather than planning in chat.
  After writing the plan file and before handing over the `/goal` line,
  have a subagent without this conversation review it: what does the plan
  get wrong or leave out that would break the goal or correctness? Gaps,
  not style. Verify each finding, fix the plan for the real ones, say which
  were dropped. Plan mode names the file with a random slug and allows no
  other edits, so after leaving it rename the file (`git mv` once
  committed) to a descriptive kebab-case name (`n8n-removal.md`) before
  the `/goal` line names it.
- **Execute** a written plan through `/goal`, which only the operator can
  type: end the planning turn with the exact line to paste, a condition
  provable from output plus a turn cap, e.g. `/goal every step in
  repos/khe-meta/plans/x.md is checked and npm test exits 0 in the output,
  or stop after 20 turns`. Also offer the same line as a `spawn_task` chip,
  so one click runs it in a fresh session; whether the chip's prompt runs
  as the slash command is unverified, so check the new session shows the
  goal active. Say which model the goal session should run: `sonnet` when
  every step is mechanical and spelled out, `opus` when steps leave
  judgement calls. The operator sets it in the new session, since switching
  models inside a session drops the earlier thinking.
- **Check against the plan** after a `/goal` run, before the review: a
  subagent with `model: opus` compares the diff to the plan file. Every
  step implemented, the listed edge cases tested, nothing outside the
  plan's scope changed. The goal evaluator reads only the transcript, so
  "every step is checked" is the executor's own claim until this passes.
  Fix the real gaps and say which findings were dropped.
- **Review** every code change (not docs-only) before committing:
  `/code-review` (medium; `high` for risky or public-facing changes).
  Skills can pin a model and whether this one does is unverified, so after
  a `sonnet` goal ask the operator to switch the session to `opus` first.
  Verify each finding against the code, fix the confirmed ones, and say
  which were dropped. If you skip the review, say so and why.
- **See it working** for UI changes: `/run` in the browser pane.

## Harness facts

- **`git commit` in a repo is gated.** `.claude/hooks/commit-gate.sh` runs
  that repo's `check:` first and blocks the commit on failure. Fix the
  cause; never work around the gate. Do not run `check:` yourself right
  before committing; the gate already does. It knows a repo listed in
  `repos/repos.yaml` by its git common dir under `repos/` of the session
  root or the main checkout, so a worktree of `repos/<name>` is gated
  wherever it sits, else by a remote that is its `url:` or its checkout.
  Any other repo inside the workspace is blocked; repos outside it, such as
  scratch repos, pass.
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
  `.claude/skills/`, scoped with `paths:`.
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
