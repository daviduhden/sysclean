---
name: sysclean-apply-mode
description: Use when changing, reviewing, or testing sysclean apply mode -x, including action planning, path validation, unlink and rmdir handling, symlink safety, partial failures, exit codes, or the boundary between detection and removal.
---

# sysclean-apply-mode

## When to use

Use this skill for any change to:

* `apply`, `prepare_apply`, `queue_path`, `remove_path`,
  `check_removable_path`, `path_has_symlink_ancestor`,
  `path_has_ignored_ancestor`, `sort_paths_deepest_first`, `path_depth`;
* the apply-mode action list or its ordering/deduplication;
* removal errors, summary counters or exit status;
* the `-x` interaction with `-i`, `-a` or `-p`;
* a suspected false positive that could become a removal.

## When not to use

Do not use this skill for:

* read-only inventory construction (use `sysclean-inventory`);
* package/library semantics (use `sysclean-packages-libraries`);
* account helper behavior beyond its apply orchestration (use
  `sysclean-accounts`);
* the sandbox promise/unveil design (use `sysclean-sandbox`);
* documentation wording (use `sysclean-documentation`).

## Related files and components

* `sysclean.pl`: the apply helpers listed above, plus `create`, `apply`,
  `remove_user`, `remove_group`, `modify_user`.
* `AUDIT.md`: authoritative threat model, invariants, sandbox description and
  known limitations.
* `regress/apply.t` and `regress/stubs/`.
* `sysclean.8`/`README.md`: `-x`, CAVEATS, EXIT STATUS text.
* `AGENTS.md`: fundamental invariants and security policy.

## Model

Apply mode is a two-phase design:

1. **Discovery.**  The normal scan records exact actions:
   `{type => 'path', name => ...}`, `{type => 'user', name => ..., uid => ...}`,
   `{type => 'group', name => ..., gid => ...}` or
   `{type => 'user_mod', name => ..., uid => ..., opts => [...]}`.
2. **Application.**  `apply()` deduplicates actions, `prepare_apply()` validates
   and tightens the sandbox, then paths are removed deepest-first, followed by
   user/group deletion and user modifications.

There is no re-scan and no glob expansion in the application phase.  This
separation is mandatory.  Do not move detection into `remove_path`.

## Validation invariants

`check_removable_path` rejects:

* undefined or empty paths;
* relative paths;
* exactly `/`;
* control characters (`\x00-\x1f\x7f`);
* non-canonical forms: `//`, `/.`, trailing `/`, `..` components;
* exact expected paths;
* exact ignored paths;
* paths inside an ignored directory;
* paths with a symlinked ancestor.

`prepare_apply` applies this check **before** unveiling parent directories.
`remove_path` rechecks immediately before `lstat`.  The final component may
be a symlink; it is unlinked, never followed.  Directories are removed with
`rmdir` only, never recursively.

`remove_path` uses `lstat($path)` and `-d _` from that stat buffer.  This is
the intended way to distinguish a directory from a symlink-to-directory.

## Partial failures and exit status

* Every refused/failed path, user, group or modification increments
  `{removed}{failed}`.
* `apply()` returns 1 when the failure counter is non-zero.
* `main()` exits 1 in that case.
* A missing required account helper, a failed parent-directory unveil, a
  failed unveil lock or a failed final pledge aborts before removal.
* Do not hide failures, convert them to warnings without a counter, or return
  0 from a partial run.

## Risks and limits

* A TOCTOU window remains between validation and `unlink`/`rmdir`.  A
  symlinked ancestor is checked, but the check and operation are not atomic.
* A top-level target requires `unveil("/", "rwc")`, which widens the write
  view for the rest of the run.
* `rwc` on a parent grants write access to every entry in that directory, not
  only the selected path.
* Account helpers run as children outside the parent's pledge/unveil.
* A stale/incomplete reference inventory can still produce a false positive.
* `-x -a` protects libraries whose names match `{used_libs}`, but unusual
  library names or incomplete `@wantlib` metadata can leave a used library
  unprotected.
* There is no transaction, backup or rollback.

## Analysis procedure

1. Read `AUDIT.md` completely before touching `-x`.
2. Trace the candidate from its detection function (`find_sub`,
   `walk_users`, `walk_groups`) to the action list.
3. Verify that the action is recorded only in apply mode and only after the
   normal detection decision.
4. Walk through `prepare_apply` and `remove_path` line by line.  Check the
   order: validation before unveil, helper checks before any path removal,
   unveil lock before pledge, pledge before removal.
5. Check every path form: canonical, `//`, `/.`, trailing slash, `..`, empty,
   `/`, control characters, ignored ancestor, symlinked ancestor, expected.
6. Check symlink final component: `lstat` + `unlink`, target preserved.
7. Check empty versus non-empty directory: `rmdir` only.
8. Check duplicate actions and deepest-first ordering.
9. Check failure counters and exit status for each refusal/failure branch.
10. Check the account revalidation path if the change touches users/groups.

## Modification procedure

1. Keep discovery and application separate.
2. Add validation, never remove it.  Prefer refusing a suspicious path over
   guessing its intent.
3. Never add recursive deletion.  Never add a fallback that empties a
   directory after `rmdir` fails.
4. Never add glob expansion, shell invocation or option-string concatenation
   in the destructive phase.
5. Validate paths before granting write permission.
6. Preserve the `lstat`/`unlink`/`rmdir` model and the final-component
   symlink behavior.
7. Add a negative test for every new refusal branch and for every new
   failure counter.
8. Require an independent security-review subagent for any change to
   selection, validation, ordering or removal.
9. Update `AUDIT.md` and this skill if an invariant or limitation changes.

## Required tests

At minimum, non-destructive unit tests for:

* every rejected path form;
* expected and ignored refusal;
* ignored-ancestor refusal;
* symlinked-ancestor refusal;
* regular file removal;
* symlink removal with target preservation;
* empty directory removal;
* non-empty directory refusal;
* duplicate/ordering behavior;
* failure counter and return value;
* apply refuses an expected path.

For changes to the account-helper branch, add VM/fixture tests for a missing
helper, a changed uid/gid, and a partial failure.  These cannot be exercised
safely by the host unit tests.

Never run `sysclean -x` against the host.  Use `File::Temp`, stubs, fixtures
or a disposable VM.

## Checks

* `perl -c sysclean.pl`
* `make regress`
* `git diff --check`
* manual review of `AUDIT.md` against the code
* independent security review for sensitive changes

## References

* `AUDIT.md`: threat model, safety invariants, sandbox, limitations.
* `sysclean.pl`: `apply`, `prepare_apply`, `remove_path`,
  `check_removable_path`, `path_has_symlink_ancestor`,
  `path_has_ignored_ancestor`.
* `regress/apply.t`.
* OpenBSD manuals: `lstat(2)`, `unlink(2)`, `rmdir(2)`, `pledge(2)`,
  `unveil(2)`.
