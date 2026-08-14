# crew-checkout write-guard

This document is the authoritative human-readable contract for the crew-checkout write-guard.
`bin/fm-crew-checkout-pretool-check.sh` is the single decision owner, the harness transport, the crew-worktree scope, and the output renderer.
The tracked harness adapters forward the command or file path without classifying it.

It is the crew-side counterpart of the primary-session guard family that shares the same cross-harness hook machinery:
the cd-guard (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`), the watcher-arm seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`), and the delegation-shape guard (`bin/fm-subagent-pretool-check.sh`, `docs/subagent-guard.md`).
Those all protect the primary session; this one protects everything the primary session owns from a crew reaching over into it.

## Purpose and boundary

A crewmate or scout runs in its own linked git worktree of the firstmate repo.
The ship-brief worktree-isolation assertion proves only that the crew STARTS in that worktree; nothing stops a later command from reaching over into the primary firstmate checkout, or a sibling worktree, and writing there.
That has actually happened: a crew `cd`'d into the primary checkout and committed onto its local `main`, because the cd-guard is deliberately inert inside a crew worktree - it only protects the primary session.

This guard is the inverse scope.
It fires only in a crew or scout task worktree and denies a tool action that `cd`s into, `git -C`/`--git-dir`/`--work-tree` targets, or writes a file under any firstmate checkout that is not the crew's own worktree.
It keys on the git-common-dir relationship, not repo identity: the primary and every worktree share one object store, so a target under a worktree whose common dir matches the crew's own but whose top-level differs is a foreign firstmate checkout.

This guard is not a general sandbox.
Its threat model is agent mistakes, the same as the other guards: an accidental absolute-path `cd` + `git commit` into the primary checkout, not a deliberately obfuscated bypass.
It never evaluates, expands, sources, or runs any byte of the submitted command; it inspects `cd`/`pushd` targets and `git` path options by word position only.

## Scope: crew/scout task worktrees only

The guard fires only in a genuine crew or scout task worktree - a linked firstmate worktree where `git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`, that carries `AGENTS.md` and `bin/`.
It reuses `fm_primary_scope_matches` from `bin/fm-primary-scope-lib.sh` to exit inert (exit 0, no output) in the two places that are NOT crews:

- the primary firstmate checkout (a plain checkout, protected instead by the cd-guard), and
- a secondmate home (marked by `.fm-secondmate-home`, its own primary session).

Any failure to positively confirm a firstmate linked worktree is treated as inert, never as a block, so a broken or unexpected environment never denies a legitimate command.
The one exception to fail-open is a target that resolves to a foreign firstmate checkout once scope is confirmed: that case always denies, so the guard fails toward blocking the cross-checkout write rather than toward allowing it.

## Own worktree resolution

The decision needs to know which worktree is the crew's own.
By default it resolves the own worktree from the guard script's own location (`$SCRIPT_DIR/..`), which is correct when a harness invokes the tracked script from inside the crew worktree - for example Claude's `"$CLAUDE_PROJECT_DIR"/bin/...` hook.
When the invoking harness runs the script from the shared code root instead of the worktree (the Pi crew extension does this, because the extension file lives in `state/` outside the worktree), the caller pins the crew worktree with `FM_ROOT_OVERRIDE=<crew-worktree>`.
`bin/fm-crew-checkout-pretool-check.sh` owns both mechanics.

## Block vs allow

The guard **blocks**, with exit 2 and the reason code `[crew-cross-checkout-write]`:

- a `cd` or `pushd` whose target resolves under a foreign firstmate checkout (the primary or a sibling worktree);
- a `git -C <path>`, `git --git-dir=<path>`, or `git --work-tree=<path>` whose path resolves under a foreign firstmate checkout;
- a file-write tool (Edit/Write/MultiEdit/NotebookEdit) whose `file_path`/`notebook_path` resolves under a foreign firstmate checkout.

The guard **allows** (exit 0, no output):

- any command or write whose target is under the crew's own worktree;
- any read anywhere, including a command that merely mentions a foreign checkout path without a `cd`/`git` position (a quoted `cd` string inside `echo`, a `cat`/`grep`/`ls` of a primary path), and any read-only tool payload;
- a relative `cd`/target, which resolves against the crew's own cwd and is never a cross-checkout reach;
- any path outside every firstmate checkout.

Only absolute (or `~`-anchored) targets are classified; keyword detection uses the raw token so a quoted word inside another command never arms it.
Deeper deliberate obfuscation is out of scope by the same agent-mistake threat model the cd-guard uses.

## Harness wiring

The decision owner is harness-agnostic; each harness routes its crew sessions to it through that harness's own hook or extension mechanism.
See `.agents/skills/harness-adapters/SKILL.md` for the per-harness mechanism facts.

| Harness | Crew wiring | Status |
|---|---|---|
| claude | `.claude/settings.json` PreToolUse hooks (`Bash` and `Edit\|Write\|MultiEdit\|NotebookEdit` matchers) forward the payload with `--claude`. The tracked settings load in the crew worktree; the script self-scopes to the crew. | wired |
| pi / pi-signed | The generated crew extension (`state/<id>.pi-ext.ts`, written by `bin/fm-spawn.sh`) adds a `tool_call` block that runs the checker with `--command` and `FM_ROOT_OVERRIDE=<worktree>`, returning `{block: true}` on exit 2. Covers the `bash` tool (the accident vector). | wired |
| codex | `.codex/hooks.json` PreToolUse Bash hook (mirror the cd-guard entry). | scoped follow-up |
| opencode | `.opencode/plugins/` `tool.execute.before` (mirror `fm-primary-cd-check.js`). | scoped follow-up |
| grok | `.grok/hooks/` PreToolUse hook (grok also loads Claude-compatible project settings, so a grok crew already gets partial coverage through the Claude wiring above). | scoped follow-up |
| kimi | Guarded global hook family (mirror the kimi turn-end hook). | scoped follow-up |

Pi is prioritized alongside Claude because a Pi crew has no permission system, auto-approves every tool, and loads none of the Claude PreToolUse guards, so it is the most exposed harness.
The remaining harnesses cover the `bash` reach-over vector through their own mechanisms in follow-up work; the shared decision owner already handles them the moment their wiring lands.
Pi's native file-edit tool name is not yet verified, so file-tool coverage on Pi is part of that follow-up; the `bash` vector (the actual accident) is covered now.

## Validation

The portable regression `tests/fm-crew-checkout-pretool-check.test.sh` pins the decision through the executable interface with real git worktrees and no harness:
the deny/allow matrix across all harness entry forms, the crew-worktree scoping (inert in the primary, secondmate homes, and non-firstmate repos), the Pi integration form (`--command` with `FM_ROOT_OVERRIDE`), the read-never-denied cases, the sibling-worktree case, the fail-open transport, and an end-to-end regression that first reproduces the reach-over commit onto the primary and then proves the guard denies the exact command.

Live per-harness block behavior - that Pi actually refuses the tool call on `{block: true}`, and that Claude honors the PreToolUse deny - is harness-dependent and must be proven against the real harness after any harness upgrade, following the two-test rule in `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
