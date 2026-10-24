---
name: sysclean-testing
description: Use when adding or running sysclean regression tests, unit tests, read-only checks, option matrix tests, negative path/symlink tests, or isolated apply-mode tests, while keeping destructive operations off the host.
---

# sysclean-testing

## When to use

Use this skill for:

* `make regress` and its targets;
* `regress/apply.t` or new unit tests;
* read-only behavior tests;
* option-combination tests (`-a`, `-i`, `-p`, `-x`);
* malformed path, symlink, expected/ignored, package/library, account or
  partial-failure tests;
* idempotence and apply-plan tests;
* differential comparison with upstream.

## When not to use

Do not use this skill for:

* changing the behavior being tested (use the matching domain skill);
* build/release packaging (use `sysclean-build-release`);
* manual documentation (use `sysclean-documentation`).

## Absolute safety rule

**Automated tests must never execute `sysclean -x` against the host.**

Do not:

* run `sysclean -x` on the machine where you are developing;
* delete real users, groups, files or directories;
* modify `/etc/master.passwd`, `/etc/group`, `/var/db/pkg` or account
  databases for a test;
* add a destructive target to `make regress`;
* rely on `DESTDIR` or `PKG_DBDIR` as isolation without verifying every path.
  `sysclean` scans `/`, reads `/etc` and `/var/sysmerge`, and invokes helpers
  at absolute paths.

Use instead:

* `File::Temp` directories;
* stub `OpenBSD::*` modules;
* fixture account/package data;
* a disposable virtual machine or jail dedicated to the test.

## Existing targets

`Makefile` currently provides:

* `run-regress-perl-syntax`: `perl -c sysclean.pl`.
* `run-regress-apply-unit`: `perl regress/apply.t` (non-destructive unit
  tests with stubs and `File::Temp`).
* `run-regress-man-lint`: `mandoc -T lint -W style sysclean.8`.
* `run-regress-man-readme`: regenerates `README.md` and compares it.
* `run-regress-man-date`: checks `.Dd` against the last commit date of
  `sysclean.8`.

`regress/apply.t` covers path validation, ignored/expected refusal,
symlinked-ancestor refusal, regular file/symlink/empty-directory removal,
non-empty directory refusal, account-name and `usermod` argument validation,
action queuing, `-x -a` protection for used libraries, the path-only
`prepare_apply` policy, and successful/failed apply runs.  It never invokes
account helpers or system paths.

## Test matrix

Read-only:

* default output;
* `-i` (include ignored) versus default;
* `-a` (used libraries included);
* `-p` (path and package columns);
* `-a -p` and `-x -p` refusal;
* `-h`/usage behavior.

Inventory:

* expected base file present/absent;
* missing/empty locate database (apply fails closed);
* missing optional X locate database (skipped);
* `MAKEDEV` output parsing and unknown command;
* `rcctl` enabled/disabled service entries;
* package file, `@cwd` ancestor, sample directory, `@dir`;
* fresh install versus upgraded fixture.

Ignore rules:

* exact path, glob, directory subtree, trailing slash;
* `+` compatibility, comments, `#` in a path;
* `@include` loop and missing include;
* `@user`/`@group` full key and name form;
* read-only `-i` versus `-x -i`.

Apply helpers:

* all rejected path forms (`''`, relative, `/`, `..`, `//`, `/.`, trailing
  slash, control characters);
* expected, ignored, ignored ancestor, symlinked ancestor;
* regular file, symlink (target preserved), empty directory, non-empty
  directory;
* duplicate actions and deepest-first ordering;
* failure counter and return value;
* a missing helper must abort before removal;
* unmasked errors must produce exit 1.

Accounts:

* name validation, `\z` anchoring;
* `usermod` option/value validation and injection refusal;
* full-key/name ignore matching;
* uid/gid mismatch is reported, not deleted;
* revalidation refuses a reused name or changed uid/gid.

Packages/libraries:

* `wantlib` key alignment;
* used library suppression in default mode;
* `-a` exposure and `-p` package mapping;
* `-x -a` refusal to queue a library present in `{used_libs}`;
* unreadable PLIST/`partial-*` fail-closed behavior;
* `PKG_DBDIR` is captured at process start.

Idempotence/plan:

* a second read-only run after a simulated cleanup reports no new action;
* duplicate actions are removed before the plan is built;
* an empty plan succeeds without touching the system.

## Adding a test

1. Choose the smallest layer that exercises the logic.
2. For pure helpers, use `require sysclean.pl` (the `main() unless caller`
   guard prevents execution) and construct a fake object.
3. Use `File::Temp` for filesystem operations and `CLEANUP => 1`.
4. Skip a filesystem test if the temporary directory itself has a symlinked
   ancestor, since the tool refuses such paths by design.
5. Stub every `OpenBSD::*` module the loaded file needs.
6. Capture stdout/stderr so TAP output stays clean.
7. Never call `create()`, `init()` or `walk()` unless the test supplies safe
   fixtures for every external command.
8. Add the target to `regress` only if the test is non-destructive and safe on
   a normal OpenBSD developer machine.

## Checks

* `perl -c sysclean.pl`
* `make regress`
* `git diff --check`
* inspect `git status` for leftover test files
* for account/package integration, run in a disposable VM and confirm the VM
  is disposable before any `-x` test

## References

* `Makefile`: regression targets.
* `regress/apply.t`, `regress/stubs/`.
* `AUDIT.md`: limitations that require VM/negative tests.
* `AGENTS.md`: absolute safety rule.
* OpenBSD manuals: `Test::More(3p)`, `File::Temp(3p)`.
