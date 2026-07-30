---
name: change
description: End-to-end process for making a change to tailscale-direct-pfsense — branch, plan, implement with the project subagents, review with the reviewer subagents, verify, commit, and open a PR. Stops at the PR and never merges. Use for any non-trivial change to the daemon, rc.d wrapper, installer, uninstaller, tests, or docs.
---

# Making a change

The full path from idea to open PR. Work through the phases in order. Do not skip the review phase to save time — the two reviewer agents exist because `make test` cannot catch what they catch.

**The merge is always the human's.** This process ends with an open PR and a report. Never run `gh pr merge`.

## 1. Branch

Confirm a clean starting point, then branch. Never commit directly to `main`.

```sh
git status --short          # must be clean; stop and ask if not
git checkout main
git pull --ff-only
git checkout -b <type>/<slug>    # fix/…, feat/…, docs/…, test/…
```

If the working tree is dirty, stop and ask what to do with the existing changes rather than stashing on your own initiative.

## 2. Plan

Read before planning, not after:

- `AGENTS.md` — the rulebook; the non-negotiables and invariants that constrain the change
- the relevant `docs/` page — `daemon-behavior.md` for restart/cooldown/classification logic, `script-reference.md` for which script owns which guarantee, `testing.md` for test structure, `architecture.md` for component boundaries

Then state, concisely:

- what changes, and in which files
- which documented invariants the change touches or risks
- what tests will prove it, and which existing tests could break
- which docs must move in step (see `docs-sync` below)

Present the plan. For routine changes, proceed once stated. **For anything touching daemon invariants, the rc.d wrapper, `install.sh`, or `uninstall.sh`, wait for explicit approval before editing** — those run as root on a firewall, and a plan is cheaper to correct than a diff.

## 3. Implement

Core edits to `tailscale_watchdogd`, `tailscale_watchdog`, `install.sh`, and `uninstall.sh` are yours to make directly — no subagent covers them, deliberately, since they carry the project's risk.

Delegate the parts that have a subagent:

- **`shell-test-author`** — new or extended tests in `tests/`. It knows the sourcing pattern, the fake-command convention, and that new files must be registered in `TESTS` in the `Makefile`.
- **`docs-sync`** — propagating a config knob, default, provider, or version string across `README.md`, `tailscale_watchdog.conf.example`, `docs/`, `AGENTS.md`, and the assertions in `tests/test_docs_static.sh`.

Both write files. Give each the full context of the change; they start fresh with no memory of this conversation.

Syntax-check as you go — this is the cheapest possible feedback:

```sh
make smoke
```

## 4. Review

Run **both** reviewers on the diff, in parallel — send both `Agent` calls in a single message. They are read-only, they report rather than edit, and they cover deliberately non-overlapping ground:

- **`freebsd-shell-reviewer`** — will this actually run on FreeBSD `/bin/sh`? Bashisms and GNU-only flags pass every check on a Linux dev box and fail on the router.
- **`router-safety-reviewer`** — does this violate a safety rule or daemon invariant? Root-script conduct, secret handling, cooldown/deferral/counter semantics.

Triage what comes back. Fix real findings; for anything you judge a false positive, say so and why rather than silently dropping it. If the fixes are substantial, run the reviewers again on the updated diff.

Report the findings to the user even when you fixed them all — the reviewers' output is the evidence that the risky parts got looked at.

## 5. Verify

```sh
make test
```

**Check whether any failure predates the change** (`git stash` and re-run, or run the suite on `main`). Report a pre-existing failure as pre-existing; never claim to have fixed something you didn't touch, and never adjust an assertion to make an unrelated red test go green.

Never run, at any point in this process: `./install.sh`, `./uninstall.sh`, any `service …` command, or `tailscale ping`. They have live-router effects and are the human's call.

## 6. Commit

Per `AGENTS.md`, before committing: show the diff, explain the risk, and state which tests were run.

Check what you're about to stage:

```sh
git status --short
git diff
```

Never commit: a live `tailscale_watchdog.conf`, logs, temp files, `.codex-log`, or anything containing a token, real peer name, or private hostname. Verify explicitly — `git diff --cached` before the commit, not after.

Keep commits focused; one logical change. End the message with:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

## 7. Open the PR, then stop

```sh
git push -u origin <branch>
gh pr create --title "…" --body "…"
```

The body should give a reviewer what they need to judge it: what changed and why, the invariants it touches, the reviewer-agent findings and their resolution, and the test results including any pre-existing failure. End it with:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Then **stop and hand back**. Report the PR URL, the review findings, and the test state.

Do not merge. Do not run `gh pr merge`, do not enable auto-merge, do not push further commits to the branch unless asked. If the user reviews and asks you to merge, that is a new instruction — and even then, confirm the merge method before running it.
