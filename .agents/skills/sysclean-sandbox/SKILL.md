---
name: sysclean-sandbox
description: Use when changing or auditing pledge, unveil, privilege handling, exec promises, helper execution, or the read-only versus apply-mode sandbox in sysclean.
---

# sysclean-sandbox

## When to use

Use this skill for:

* `OpenBSD::Pledge`, `OpenBSD::Unveil`, `pledge(2)`, `unveil(2)`;
* the `init` and `prepare_apply` sandbox sequence;
* helper execution (`locate`, `MAKEDEV`, `rcctl`, `userdel`, `groupdel`,
  `usermod`);
* privilege assumptions or a suspected sandbox regression;
* claims about what the sandbox does and does not cover.

## When not to use

Do not use this skill for:

* path/account validation (use `sysclean-apply-mode` or
  `sysclean-accounts`);
* general removal mechanics (use `sysclean-apply-mode`);
* documentation-only wording (use `sysclean-documentation`).

## Related files and components

* `sysclean.pl`: `init`, `prepare_apply`, `remove_user`, `remove_group`,
  `modify_user`.
* `AUDIT.md`: "Sandbox", "Implemented, verified, and unverified",
  "Known limitations".
* `AGENTS.md`: security policy and "do not consider pledge/unveil sufficient".
* OpenBSD manuals: `pledge(2)`, `unveil(2)`, `OpenBSD::Pledge(3p)`,
  `OpenBSD::Unveil(3p)`.

## Actual phases

### Read-only mode

1. `init()` runs `lock_db(1)`, sets `unveil("/", "r")` and `rx` unveils for
   `/dev/MAKEDEV`, `/usr/bin/locate` and `/usr/sbin/rcctl`.
2. It runs the base, device and service helpers while still unpledged.
3. It calls `pledge("rpath getpw")` after all external execution.
   `OpenBSD::Pledge` adds `stdio`.
4. The pledge lacks `unveil`, so the unveil view is locked.
5. It builds account and package inventory under the ceiling.
6. The scan runs under `rpath getpw stdio`.

### Apply mode

1. The scan runs unpledged; the initial unveil view is read-only.
2. `apply()` collects and deduplicates actions.
3. `prepare_apply()` validates every path and drops refused paths **before**
   granting write permission.
4. It unveils each remaining parent directory with `rwc`.
5. It checks and unveils only the account helpers needed: `userdel`,
   `groupdel` and/or `usermod`, each `rx`.
6. It calls `unveil()` to lock the view.
7. It pledges `rpath wpath cpath getpw`, adding `proc exec` when any account
   helper must run.  `stdio` is implicit.
8. Paths are removed, then users/groups, then user modifications.

A failure of a parent-directory unveil, the unveil lock or the final pledge
aborts before removal.  A missing required account helper is also fatal before
removal.

## Guarantees and limits

Implemented and inspected:

* the calls, promise strings and ordering above;
* validation before write permission;
* fatal handling of unveil/pledge failures in prepare_apply;
* account helper existence checks before removal;
* read-only view locking via a pledge without `unveil`.

Not guaranteed:

* That `pledge`/`unveil` makes removal safe.  Path and account checks are the
  primary controls.
* That account helper children are confined.  No `execpromises` are
  installed; `execve` gives the child an unpledged, unveiled start.  The
  parent retains its pledge/unveil restrictions.
* That a top-level removal avoids `unveil("/", "rwc")`.
* That `rwc` is narrower than the parent directory; it grants write access to
  every entry in that directory.
* That the unveil vnode limit is never reached in a large run.
* That there is no TOCTOU window between validation and removal.

Do not claim a guarantee that is only implemented but not tested.  Do not
claim the children inherit the parent's sandbox.

## Rules for changes

* Do not weaken a promise or unveil permission without a documented threat
  analysis and security review.
* Do not remove `unveil()` locking.
* Do not add write permission before path validation.
* Do not add `rwc` to `/` unless the top-level removal case requires it.
* Do not use `execpromises` as a casual isolation mechanism.  It changes the
  helper's inherited promise set and can break legitimate `userdel`,
  `groupdel` or `usermod` behavior.  Justify it exhaustively and test it in a
  disposable VM.
* Do not propose a configuration that prevents legitimate operation just to
  make the promise set look smaller.
* Keep `proc exec` when account helpers must run; without it `system()` cannot
  execute them.  The apply path must not remain completely unpledged merely
  because an account helper is needed.
* Keep `getpw` for account revalidation and `rpath`/`wpath`/`cpath` for the
  scan and removal.
* If you change the sequence, update `AUDIT.md` and this skill together.

## Analysis procedure

1. Read `AUDIT.md`'s sandbox section and compare it with the code.
2. List every external program invoked and the phase in which it runs.
3. For each phase, record: unveiled paths, permissions, active promises,
   whether unveil is locked, and whether exec is possible.
4. Check whether a helper child inherits or loses the sandbox.
5. Look for validation that happens after a permission grant.
6. Check failure handling: are unveil/pledge failures fatal before removal?
7. Check the top-level path case and the `rwc` scope.
8. Verify that no new syscall is needed but missing (for example `proc` for
   `system`, `getpw` for `getpwnam`, `wpath`/`cpath` for removal).
9. Test only in a disposable VM.  A unit test with stubs can verify call
   order, not real kernel behavior.

## Checks

* `perl -c sysclean.pl`
* `make regress`
* stub-based tests for the call order and promise strings
* disposable-VM smoke test for read-only and path-only apply
* disposable-VM test for the account-helper path, if changed
* `git diff --check`
* independent security review for any sandbox change

## References

* `AUDIT.md`: Sandbox, Implemented/verified/unverified, Known limitations.
* OpenBSD manuals: `pledge(2)`, `unveil(2)`, `OpenBSD::Pledge(3p)`,
  `OpenBSD::Unveil(3p)`.
* `sysclean.pl`: `init`, `prepare_apply`.

## Maintenance & Continuous Learning

When this skill is used to change the repository, the agent MUST complete this
review before reporting the task complete:

* Re-read the applicable root/path `AGENTS.md` files and this skill after the
  implementation; identify other skills and agent instructions affected by the
  changed behavior, paths, tools, configuration, or safety assumptions.
* Update this skill or the other affected instruction files with verified,
  reusable knowledge when procedures, tools, examples, validation commands, or
  project assumptions have changed. Every repository change must include a
  substantive, relevant agent/skills update; do not make cosmetic or empty
  edits to satisfy the rule.
* Remove stale or conflicting guidance, preserve this skill's frontmatter, and
  validate local references and consistency with the implementation. If no
  reusable update is warranted for this skill, identify which other applicable
  agent/skill file carries the maintenance update.
* Run `perl regress/check-agent-maintenance.pl --lint` and, before completion,
  `perl regress/check-agent-maintenance.pl --base <target-branch>`. Also run
  relevant checks listed by this skill. Report checks only when they were run.
* If this skill, another skill, or agent policy changes, review the complete
  instruction set once and repeat validation only to correct a discovered
  inconsistency. Do not add one-run notes that will not help future work.

Include an **Agent & Skills Synchronization** section in the final report. Name
the agents and skills reviewed, instruction files updated, reusable knowledge
added or corrected, validations run, and status **PASS** or **FAIL**.
