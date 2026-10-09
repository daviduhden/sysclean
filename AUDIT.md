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
  `ignored` sets is refused as a second line of defence.  The tool's own
  `/etc/sysclean.ignore` file is always added to `expected`, so apply mode
  can never remove it, even when `-i` is not given.
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
* **`-i` controls ignored elements in apply mode.**  `-x` is refused with
  `-p` (informational package mode).  With `-x -i` the ignore files
  (`/etc/changelist`, `/etc/sysclean.ignore`) are honored and those
  elements are never removed; without `-i` they are treated as ordinary
  obsolete elements and removed.  The hardcoded ignored directories
  (`/home`, `/var/log`, ...) are always respected.  `-x -a` warns because
  the all-files listing may include libraries used by installed packages.
* **User recommendations are applied.**  Obsolete users and groups are
  removed with `userdel(8)`/`groupdel(8)` (home directories preserved),
  and system users whose group, login class, home directory or shell
  differs from the reference are updated with `usermod(8)`.  Account
  names are validated before use and the values applied come from the
  trusted reference installation (base and package metadata).

## Sandbox (`pledge(2)` / `unveil(2)`)

Read-only mode is unchanged: `unveil("/", "r")` (+ helper executables) and
the final `pledge("rpath getpw")` both lock `unveil(2)` (a pledge without
the `unveil` promise locks it).

In apply mode the `unveil` promise is retained during the scan.  Because
`pledge(2)` can only *reduce* the promise set, the promises needed to apply
the changes (`wpath`/`cpath` to unlink files and `rmdir(2)` directories,
`proc`/`exec` to run the account helpers) are requested from the first
`pledge(2)` call in `init()`.  They stay harmless while scanning because
`unveil(2)` still exposes a read-only view of the filesystem
(`unveil("/", "r")`): `wpath`/`cpath` only permit the syscalls, they do not
grant access to paths that are not unveiled.

Just before applying, `prepare_apply()`:

1. unveils each *parent directory* of a targeted path with `rwc`, so write
   access is limited to the directories that actually hold an obsolete
   element (more specific `unveil` rules override the read-only `/`);
2. unveils `/usr/sbin/userdel`, `/usr/sbin/groupdel` and
   `/usr/sbin/usermod` with `rx` only when accounts must be removed or
   modified;
3. locks `unveil(2)` with `unveil()`; and
4. reduces `pledge(2)` to `rpath wpath cpath getpw`, keeping `proc exec`
   when helper programs must be executed.

Because `pledge(2)` is called without `execpromises`, `execve(2)` drops both
the pledge and the veil for the `userdel(8)` / `groupdel(8)` / `usermod(8)`
children, which then run their own sandbox.

### Known limitations

* When an obsolete element is a top-level entry (for example `/data`), its
  parent is `/`, so `unveil("/", "rwc")` is required for that invocation.
  This is unavoidable if top-level entries are to be removed.
* A path that is replaced (raced) between the scan and the removal is
  removed by its name with `lstat`/`unlink`/`rmdir` semantics.  The prime
  target is a non-empty directory, which `rmdir` refuses, or a symlink,
  which is unlinked rather than followed.
