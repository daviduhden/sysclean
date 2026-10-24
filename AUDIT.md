# Audit: apply mode (`-x`)

This document records the security review of the apply mode added by this
fork.  The canonical upstream, which remains read-only, is
<https://codeberg.org/semarie/sysclean/>.

## Scope

The fork adds a single option, `-x`, that removes the obsolete elements
`sysclean` reports instead of only listing them.  The default mode remains
strictly read-only.  The fork also contains a small number of changes that
are not part of upstream (logging prefixes, additional hard-coded ignores,
a later read-only `pledge(2)`, account safety checks, and the `-i` semantics
in apply mode); those are listed under "Differences from upstream" below.

## Threat model

`sysclean` runs as root and scans the whole filesystem.  The apply mode is
the only code path that modifies the system, so the audit focuses on:

1. removing a path that was not actually reported (false positive);
2. following a symbolic link out of the intended target;
3. deleting more than intended (recursion, globs, `..`, `/`);
4. injecting options through account names or account fields passed to
   `userdel(8)`, `groupdel(8)` or `usermod(8)`;
5. applying changes from an incomplete or failed reference inventory;
6. arbitrary writes or executions after the sandbox is set up.

## Safety invariants

The apply path enforces the following invariants:

* **Opt-in.**  Nothing is removed unless `-x` is given.  Without it the
  program only reads the system.
* **Explicit proposal only.**  Only elements recorded by the normal scan are
  candidates.  Planned paths are stored as an exact list; no globbing or
  re-scanning happens at removal time.
* **Canonical absolute paths only.**  Relative paths, the empty path, `/`,
  `//`, `/.` components, trailing slashes, control characters and any `..`
  component are refused.
* **No ignored subtree.**  A path inside a hard-coded or loaded ignored
  directory is refused as a second line of defence, in addition to the
  exact-path check.
* **No symlinked ancestor.**  A path with a symbolic link in an ancestor
  component is refused.  The final component may be a symbolic link; it is
  unlinked, not followed.
* **Expected/ignored protection.**  A path present in the `expected` or
  `ignored` sets is refused.  `/etc/sysclean.ignore` and
  `/etc/changelist` are always added to `expected`, so apply mode cannot
  remove them, even when `-i` is not given.
* **No recursion.**  Directories are removed with `rmdir(2)` only, so a
  non-empty directory is never removed.  There is no recursive unlink.
* **`lstat(2)` and `unlink(2)`/`rmdir(2)`.**  Removal uses `lstat(2)` so a
  symbolic link is never dereferenced.
* **Deepest-first order.**  Candidates are processed deepest-first for
  deterministic ordering.  Because unknown directories are pruned during the
  scan, a queued directory normally has no queued descendants; removal still
  uses `rmdir` only and succeeds only for an already-empty directory.
* **Account names are validated.**  Names must match
  `^[A-Za-z0-9_][A-Za-z0-9._-]*$`, which rejects a leading `-` and
  therefore option injection.  Arguments are passed to helpers as a list,
  never through a shell.
* **`usermod(8)` values are validated.**  Only `-g`, `-L`, `-d` and `-s`
  are accepted, with an accompanying value; values starting with `-` or
  containing control characters are refused.
* **Accounts are revalidated immediately before use.**  `userdel`,
  `groupdel` and `usermod` are called only if the account still exists with
  the uid/gid recorded during the scan, is still not expected, and is not
  ignored.  A reused name or a changed uid/gid causes the operation to be
  refused and counted as a failure.
* **Name/uid mismatch is not deletion.**  If a name exists in the reference
  but the current uid differs (or a group name exists with a different
  gid), the account is reported but not removed or rewritten.
* **Home directories are preserved.**  `userdel` is called without `-r`.
* **`-i` controls ignored elements in apply mode.**  `-x` is refused with
  `-p`.  With `-x -i` the ignore files (`/etc/changelist`,
  `/etc/sysclean.ignore`) are loaded and those elements are never removed;
  without `-i` they are treated as ordinary obsolete elements.  The
  hard-coded ignored directories and files are always respected.  A failed
  `@include` is a hard error rather than a silent loss of protection.
* **`-x -a` protects used libraries.**  All-files mode reports libraries used
  by installed packages in read-only mode.  In apply mode, `find_sub` refuses
  to queue a library whose name is present in `{used_libs}` and warns.  A
  library whose name does not match the expected
  `lib<stem>.so.<major>.<minor>` form is not protected by this check.
* **Reference input is fail-closed in apply mode.**  An empty or failed
  `locate` inventory, a failed `rcctl ls on`, an empty or unreadable
  `/var/sysmerge/etc.tgz` member, an unreadable package packing list, a
  `partial-*` package, or a missing account helper aborts apply mode before
  any path is removed.
* **Partial failures are visible.**  Every refused or failed removal or
  account operation increments a failure counter; apply mode exits with
  status 1 when at least one operation failed.

## Sandbox (`pledge(2)` / `unveil(2)`)

The scan invokes `locate(1)`, `/dev/MAKEDEV` and `rcctl(8)` before a syscall
ceiling is installed.  Read-only mode therefore pledges `rpath getpw` only
after those helpers finish.  `OpenBSD::Pledge` adds `stdio` implicitly.  The
pledge lacks the `unveil` promise, which locks the read-only unveil view
(`unveil("/", "r")` plus the helper executables).

Apply mode stays unpledged during the scan because account helpers may be
executed later.  Its read-only unveil view is retained until
`prepare_apply()`:

1. validates every planned path and drops refused ones before granting any
   write permission;
2. unveils each remaining parent directory with `rwc`;
3. checks and unveils only the account helpers that are actually needed
   (`userdel`, `groupdel`, or `usermod`) with `rx`;
4. locks `unveil(2)` with `unveil()`; and
5. pledges `rpath wpath cpath getpw`, adding `proc exec` when an account
   helper must be executed.  `OpenBSD::Pledge` adds `stdio` implicitly.

A failure of any parent-directory unveil, of the unveil lock, or of the
final pledge aborts the run before removal.  A missing required account
helper is also fatal before removal.

No `execpromises` are installed.  When an account helper is executed, the
child starts unpledged and with its own (empty) unveil view; the parent
retains its pledge and unveil restrictions.  The child is therefore outside
the parent's sandbox and may use its own sandboxing.  This is a deliberate
limitation, not a guarantee that the helper is confined.

### Implemented, verified, and unverified

* **Implemented:** the validation calls, the unveil/pledge sequence, the
  helper checks, the exit status, and the fail-closed reference checks
  described above.
* **Covered by unit tests:** `regress/apply.t` exercises path validation,
  symlinked-ancestor refusal, expected/ignored refusal, removal of regular
  files and symbolic links, empty/non-empty directory handling, account
  name and `usermod` argument validation, action queuing, `-x -a` protection
  for used libraries, the path-only `prepare_apply()` policy, and
  successful/failed apply runs.  The tests use
  `File::Temp` and stub `OpenBSD::*` modules; they never touch system files
  or accounts.
* **Unverified:** the exact behaviour of every OpenBSD helper version, the
  `unveil(2)` vnode limit in large runs, the account-helper execution path,
  and race-free removal.  These require disposable virtual machines and
  negative integration tests.
* **Not claimed:** that `pledge(2)`/`unveil(2)` make the apply path safe by
  themselves.  The path and account checks are the primary controls.

### Known limitations

* **TOCTOU window.**  A path can be replaced between the scan, the
  `lstat(2)` check and the `unlink(2)`/`rmdir(2)` call.  The final-component
  symlink is unlinked rather than followed, a non-empty directory is refused
  by `rmdir`, and a symlinked ancestor is refused when checked, but the
  check and the operation are not atomic.
* **Top-level entries.**  When an obsolete element is a top-level entry
  (for example `/data`), its parent is `/`, so `unveil("/", "rwc")` is
  required for that invocation.  This grants write permission on the whole
  unveiled root for the rest of the run.
* **`rwc` breadth.**  `unveil(parent, "rwc")` grants write access to every
  entry in that parent directory, not only to the selected path.
* **Helper children are unconfined.**  See the `execpromises` note above.
* **Incomplete reference inputs.**  A stale locate database, a service
  that is not enabled, an unknown `MAKEDEV` layout, an empty package
  database, or a skipped `sysmerge` can make a legitimate file or account
  look obsolete.  Apply mode refuses obviously failed inputs, but it cannot
  detect a reference that is complete yet wrong for the running system.
* **`-x -a`.**  Used libraries are protected only when their filename matches
  the `lib<stem>.so.<major>.<minor>` form and the stem/version is present in
  `{used_libs}`.  Unusual library names or incomplete `@wantlib` metadata can
  leave a used library unprotected; the warning does not prove otherwise.
* **Ignore globs.**  Ignore patterns are expanded when the ignore file is
  read, not during removal.  A directory created later and matching an
  ignore pattern is not added to the ignored set; it may be reported if the
  scan reaches it.  This is intentional: no glob is expanded in the
  destructive phase.
* **Hard-coded ignore list.**  The list covers common writable and
  service-owned trees, but it is not a complete policy for every possible
  local layout.
* **No transaction or backup.**  Removals happen in place.  A partial run
  leaves the system partially cleaned and exits non-zero; there is no
  rollback.
* **`PKG_DBDIR` is not isolation.**  It changes the package database used
  for reference data, but the filesystem scan, `/etc`, `/var/sysmerge` and
  account helpers still refer to the host root.  `DESTDIR` is not honoured
  by `sysclean`; it is only a build/install variable.
* **Logs are not an audit trail.**  Control characters in pathnames are
  escaped in `[INFO]`/`[WARN]`/`[ERROR]` messages, but apply mode does not
  write to `syslog` and does not keep a durable record.

## Differences from upstream

The fork's apply mode is the main difference.  The following changes are
also fork-only and must not be attributed to upstream:

* `-x`, including `queue_*`, `check_removable_path`, `remove_path`,
  `remove_user`, `remove_group`, `modify_user`, `prepare_apply` and
  `apply`;
* the apply-mode meaning of `-i` (protect ignored elements instead of
  including them);
* the `usermod(8)` recommendations for modified system users;
* account uid/gid mismatch protection and account revalidation;
* `@dir` PLIST pass-through and stripping of `pkg_add(1)` `!` markers from
  account metadata;
* name-based `@user`/`@group` ignore matching;
* the `[INFO]`/`[WARN]`/`[ERROR]` logging helpers and control-character
  escaping;
* additional hard-coded ignores (`/etc/ssl/cert.pem`,
  `/usr/share/zoneinfo`, `/var/dbupdate`, `/var/tmp`, `/var/empty`);
* always treating `/etc/sysclean.ignore` and `/etc/changelist` as expected;
* the fail-closed reference-inventory checks;
* the later read-only `pledge(2)` (after helper execution);
* this audit, the `FORK` manual section and the fork copyright lines.

The upstream repository remains the canonical source for the read-only
scanner, package/library integration, `locate`, `MAKEDEV`, `rcctl` and the
base/package inventory model.
