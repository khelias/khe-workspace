# CLAUDE.md

@AGENTS.md
@repos/khe-architecture/ESTATE.md

## Workflow

Built-ins, plus the custom skills in `.claude/skills/`: the UI ones, scoped
to the web apps' source, `plan-file` for planning and `/goal` runs, `retro`,
and `next`, which reads what `retro` records when the operator asks what to
do next. Run these without being asked, at
default effort; no `/effort ultracode` or workflows unless the operator asks.

- **Plan** a non-trivial change in plan mode yourself (`EnterPlanMode`)
  and load the `plan-file` skill as you enter it; a plan-review subagent is
  pointed at the skill for the ADR criteria.
- **Execute** a written plan through the `/goal` line the `plan-file` skill
  describes.
- **Check against the plan** at the end of a `/goal` run, before the
  review, with the opus subagent the `plan-file` skill describes.
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
  the plan file's Status and Outcome, the roadmap entry it moves, a
  Judgement line when a correction repeats, and the removal of the task's
  own worktrees. A small fix with no plan and no roadmap entry does only
  the removal.

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
- **The gate keeps `pr: true` repos off `main`.** In a repo that
  `repos/repos.yaml` marks `pr: true` (estate ADR-023) it refuses a commit
  on `main`, the remote's default branch or a detached HEAD; the push
  and PR for such a repo are in `AGENTS.md`. It runs before the command, so
  `git switch -c x && git commit` in one call is checked against the old
  branch: run the switch as a command of its own first.
  `KHE_PR_SKIP="<reason>" git commit ...` skips only this rule, for an
  emergency, and shows the reason to the operator; it may stand beside
  `KHE_REVIEW_SKIP` in either order.
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
- **The Bash sandbox blocks raw TCP and the network tools.** WebSocket
  scripts, `git push`, `gh` and `ssh` need `dangerouslyDisableSandbox:
  true`; `curl` and REST do not. `docker-vm` resolves only with Tailscale up.
- **Sandboxed git may not see every ref.** Branches and worktrees made in
  the main checkout, and remote refs such as `origin/main`, can be missing,
  so `@{u}..` prints nothing and ahead reads 0. Run checks of unpushed
  commits, branches or worktrees with `dangerouslyDisableSandbox: true`.
- **What else blocks commands depends on the Claude instance.** In the work
  account's instance, `~/.claude/guardrails/pretooluse-guard.sh` fails the
  whole Bash command on a recursive `rm`, `git checkout --`, `git reset
  --hard` and other destructive git, kubectl, helm and docker patterns;
  user-settings deny rules refuse any `rm`; managed settings deny reading
  `.env` and `.env.*` (`.example` included), `ssh` and `git push`, so there
  the operator pushes from a handover. The personal instance
  (`CLAUDE_CONFIG_DIR=~/.claude-isiklik`) has none of these: the commit gate
  is the net, and Boundaries still apply. Revert with an edit instead of a
  destructive command, and ask the operator to run anything refused.
  Deleting config entries and bulk enable/disable scripts are stopped by the
  auto mode classifier, not a rule, so the outcome varies; inline Python on
  named entities passes.
- **The personal instance also runs on agent-vm**, a Debian VM with the
  workspace cloned to `~/khe`
  ([khe-homelab `infrastructure/agent-vm.md`](https://github.com/khelias/khe-homelab/blob/main/infrastructure/agent-vm.md)).
  There the config dir is the default `~/.claude`, bash is 5 with gawk and
  upstream gitleaks, the gate runs unchanged (its push cases checked there
  2026-11-14) and Bash runs in a strict sandbox (estate ADR-027): no
  `dangerouslyDisableSandbox` retry, outbound to GitHub, npm, PyPI,
  Anthropic, Debian and Hinnavaatlus (for khe-deals) only, `~/.ssh` and
  `~/.config/khe` unreadable; git,
  `git push` and `gh` work inside it. Sessions start in auto mode; `ssh`,
  `scp` and the HA scripts run outside the sandbox only when the call holds
  that one command (no `cd`, pipe or redirect), and each asks the operator,
  so a docker-vm command or an HA write waits for a tap on the phone. The HA
  scripts run as `/home/khe/khe/repos/khe-home-assistant/.venv/bin/python
  scripts/ha-ws.py '<json>'` from the checkout. There is no browser pane and
  no Claude in Chrome: Playwright's Chromium is in `~/.cache/ms-playwright`,
  used from a repo that has Playwright, with the static server in the same
  call because a sandboxed command's localhost is its own (the command is
  in khe-homelab `infrastructure/agent-vm.md` "Sandbox"), then read the
  image. Jobs that run without the operator are GitHub-hosted Actions, never
  agent-vm: the weekly digest in khe-homelab first.
  Its memory folder is keyed by the VM's workspace path, not the laptop's.
  Parallel sessions there use `repos/<name>` worktrees as above. Projects
  reached the account on 2026-11-16 (project "KHE"): a claude.ai Projects
  task runs there only as a local thread, in `~/khe`: a cloud thread reads just
  `CLAUDE.md`, so it has no gate and no skills, and the project's
  instructions (`projects/khe-instructions.md`) forbid it. The laptop's
  personal instance is the fallback when the VM is down.
- **The gate also checks pushes** (estate ADR-023): it refuses any force
  push (`--force*`, `-f`, `--mirror`, a `+ref`), deleting `main` or
  `--prune` in any repo, a push that moves `main` of a `pr: true` repo (a
  bare `git push` there from `main` included), a
  tag push matching a repo's `release_tag:` (khe-ui) and `gh pr merge
  --admin`. It also refuses a push it cannot read (a value from a variable,
  `GIT_DIR`, any global option before `push` but `-C`, or `HEAD` after a
  branch switch in the same call) and one that could run a command of its
  choosing (`--receive-pack`, `--exec`, `GIT_SSH*`, `GIT_CONFIG_*`, an
  ASKPASS). It reads the command line only: a git command inside a quoted
  string with spaces (`ssh "..."`, `bash -c '...'`), a script or an alias is
  not seen, so never commit or push on docker-vm.
