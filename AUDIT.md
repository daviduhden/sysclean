# Audit: apply mode (`-x`)

This document records the security review of the apply mode added by this
fork.  The canonical upstream, which remains read-only, is
<https://codeberg.org/semarie/sysclean/>.

## Scope

The fork adds a single option, `-x`, that removes the obsolete elements
`sysclean` reports instead of only listing them.  Everything else,
including the default read-only behaviour, is unchanged from upstream.

## Threat model

`sysclean` runs as root and scans the whole filesystem.  The apply mode is
the only code path that modifies the system, so the audit focuses on:

1. removing a path that was not actually reported (false positive);
2. following a symbolic link out of the intended target;
3. deleting more than intended (recursion, globs, `..`, `/`);
4. injecting options through account names passed to `userdel(8)` /
   `groupdel(8)`;
5. arbitrary writes after the sandbox is set up.

## Safety invariants

The apply path enforces the following invariants:

* **Opt-in.**  Nothing is removed unless `-x` is given.  Without it the
  program behaves exactly as upstream and only reads the system.
* **Explicit proposal only.**  Only paths recorded by the normal scan are
  candidates.  Planned paths are stored as an exact list; no globbing or
  re-scanning happens at removal time.
* **Absolute paths only.**  Relative paths, the empty path and `/` are
  refused.
* **No traversal.**  Any path containing a `..` component is refused.
* **Expected/ignored protection.**  A path present in the `expected` or
  `ignored` sets is refused as a second line of defence.
* **No symlink following.**  Removal uses `lstat(2)`; symbolic links are
  unlinked, never dereferenced.
* **No recursion.**  Directories are removed with `rmdir(2)` only, so a
  non-empty directory is never removed.  There is no recursive unlink.
* **Deepest-first order.**  Candidates are processed deepest-first so that
  empty directories can be removed after their contents.
* **Account names are validated.**  Names must match
  `^[A-Za-z0-9_][A-Za-z0-9._-]*$`, which also rejects a leading `-` and
  therefore option injection.  `userdel` is called without `-r`, so home
  directories are preserved.
* **Ignored elements are always respected.**  `-x` is refused with `-p`
  (informational package mode) but works with `-i`: in apply mode the
  ignore files (`/etc/changelist`, `/etc/sysclean.ignore`) are always
  honored, so `-i` never causes an ignored file to be removed.  `-x -a`
  warns because the all-files listing may include libraries used by
  installed packages.

## Sandbox (`pledge(2)` / `unveil(2)`)

Read-only mode is unchanged: `unveil("/", "r")` (+ helper executables) and
the final `pledge("rpath getpw")` both lock `unveil(2)` (a pledge without
the `unveil` promise locks it).

In apply mode the `unveil` promise is retained during the scan.  Just
before applying, `prepare_apply()`:

1. unveils each *parent directory* of a targeted path with `rwc`, so write
   access is limited to the directories that actually hold an obsolete
   element (more specific `unveil` rules override the read-only `/`);
2. unveils `/usr/sbin/userdel` and `/usr/sbin/groupdel` with `rx` only when
   accounts must be removed;
3. locks `unveil(2)` with `unveil()`; and
4. reduces `pledge(2)` to `rpath wpath cpath getpw`, adding `proc exec`
   only when helper programs are executed.

Because `pledge(2)` is called without `execpromises`, `execve(2)` drops the
veil for the `userdel(8)` / `groupdel(8)` children, which then run their own
sandbox.

### Known limitations

* When an obsolete element is a top-level entry (for example `/data`), its
  parent is `/`, so `unveil("/", "rwc")` is required for that invocation.
  This is unavoidable if top-level entries are to be removed.
* A path that is replaced (raced) between the scan and the removal is
  removed by its name with `lstat`/`unlink`/`rmdir` semantics.  The prime
  target is a non-empty directory, which `rmdir` refuses, or a symlink,
  which is unlinked rather than followed.
