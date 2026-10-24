---
name: sysclean-inventory
description: Use when changing or auditing how sysclean determines expected files, ignored paths, obsolete directories, service-generated files, locate databases, MAKEDEV devices, or fresh-versus-upgraded inventories.
---

# sysclean-inventory

## When to use

Use this skill for:

* a reported false positive or false negative in the file/directory listing;
* changes to `add_expected_base`, `add_expected_base_one`,
  `add_expected_dev`, `add_expected_rcctl`, `walk_filesystem` or `find_sub`;
* changes to the hard-coded expected or ignored lists;
* investigating why a path is or is not reported after an OpenBSD upgrade;
* comparing a fresh installation with an upgraded system.

## When not to use

Do not use this skill for:

* path removal mechanics or `-x` execution (use `sysclean-apply-mode`);
* package PLIST fields, shared-library relations or `-a`/`-p` semantics (use
  `sysclean-packages-libraries`);
* ignore-file precedence and `-i` (use `sysclean-ignore-rules`);
* account deletion or `usermod` (use `sysclean-accounts`);
* sandbox promises (use `sysclean-sandbox`).

## Related files and components

* `sysclean.pl`: `init`, `init_ignored`, `add_expected_base`,
  `add_expected_base_one`, `add_expected_dev`, `add_expected_rcctl`,
  `add_expected_ports_info`, `walk_filesystem`, `find_sub`.
* `sysclean.8`, `README.md`, `AUDIT.md`.
* `sysclean.ignore` (example only; the live file is `/etc/sysclean.ignore`).
* OpenBSD data: `/usr/lib/locate/src.db`,
  `/usr/X11R6/lib/locate/xorg.db`, `/dev/MAKEDEV`, `rcctl ls on`,
  `/var/sysmerge/etc.tgz`, `/var/db/pkg`.

## Inventory model and invariants

`{expected}` is the set of exact absolute paths that belong to the reference
installation.  `{ignored}` is the set of paths/subtrees that must never be
inspected or removed.  `File::Find` walks `/` with `follow => 0` and
`no_chdir => 1`:

1. an ignored path is pruned;
2. an expected path is skipped (a directory is descended into);
3. an unexpected directory is pruned and reported as one path;
4. an unexpected non-directory is reported by `find_sub`.

Therefore, a missing expected directory is especially dangerous: it hides
its whole subtree behind one false positive.  The expected set must include
every legitimate directory, not only files.

Hard rules:

* Do not treat absence from one database as proof of obsolescence.
* Do not infer obsolescence from a stale locate database, a disabled
  service, a missing X database, a partial package database or a skipped
  `sysmerge`.
* Do not add a path to `{expected}` merely to silence a warning without
  understanding why it is present.
* Do not remove a path from `{ignored}` without a security review.
* Apply mode consumes the scan result; a false positive becomes a removal
  candidate.

## Analysis procedure

1. Read `AGENTS.md` and the current `AUDIT.md` sections on reference data and
   known limitations.
2. Identify the mode: default, `-i`, `-a`, `-p` or `-x` (with or without
   `-i`).  The inventory differs only through subclass overrides, not through
   a separate scanner.
3. Trace the path through every source in this order:
   * hard-coded `expected` list and `/etc/hostname.*`;
   * `locate` source and X databases;
   * `/dev/MAKEDEV` echo output;
   * `rcctl ls on` service-specific entries;
   * package `@cwd` ancestors and PLIST file entries;
   * hard-coded `{ignored}` and package sample directories;
   * user ignore files (only when loaded).
4. Check whether the path or one of its ancestors is in `{ignored}`.  An
   ignored ancestor prunes the subtree even if the path itself is expected.
5. Check whether the path is a directory.  An unknown directory is reported
   once and not descended into.
6. Verify each external source independently in a read-only environment:
   * confirm the locate databases match the running release/current;
   * run `rcctl ls on` and compare it with service entries in the code;
   * inspect `/dev/MAKEDEV` output in `eo=echo` mode;
   * inspect `/var/sysmerge/etc.tgz` member names and contents;
   * compare `PKG_DBDIR` contents with the running system.
7. Compare against a fresh install of the same release and against an
   upgraded system.  Expected files that are present only on a fresh install
   are a strong signal of a version assumption.
8. Run only read-only modes (`sysclean`, `-i`, `-a`, `-p`) in a disposable
   environment.  Never use `-x` to test a hypothesis.

### Is this file really obsolete?

A path is a credible removal candidate only when all of the following hold:

* it is absent from every expected source that would legitimately contain it;
* it is not in `{ignored}`, not under an ignored directory, and not a
  service-generated file for an enabled service;
* it is not owned by an installed package (`pkg_info -W`, PLIST, `+CONTENTS`);
* it is not a local configuration or user-data file that the tool cannot
  distinguish from an obsolete base file;
* the locate database and `/var/sysmerge/etc.tgz` correspond to the running
  release/current;
* no installed package or running service references it;
* its type (regular file, symlink, empty directory) is understood.

When any of these is uncertain, report a false positive; do not propose a
removal.

## Modification procedure

1. Add the missing source to the most specific function, not to a broad
   hard-coded ignore.
2. Normalize directory keys by removing a trailing slash (except `/`), so
   they match `File::Find` paths.
3. Validate external output and fail closed in apply mode:
   * an empty `locate` inventory is always an error; a failed `locate` is
     fatal in apply mode and a warning in read-only mode;
   * a missing optional X locate database is skipped, not fatal;
   * a failed `rcctl ls on` aborts apply mode;
   * an unexpected `MAKEDEV` command is an error;
   * missing/empty `etc.tgz` members are an error.
4. Keep the read-only behavior conservative: a warning is acceptable in
   read-only mode only when removal cannot follow.
5. Add or update a non-destructive test when the logic can be isolated.
6. Update `AGENTS.md` only for architectural changes; update this skill for
   detection changes.  Do not duplicate the whole `AUDIT.md`.

## Checks

* `perl -c sysclean.pl`
* `make regress` (never includes a destructive `-x` run)
* read-only output comparison in a disposable VM:
  `sysclean`, `sysclean -i`, `sysclean -a`, `sysclean -p`
* `git diff --check`
* for OpenBSD-version changes, repeat on a fresh install and an upgraded
  install of the target release/current

## References

* `sysclean.pl`: `init`, `add_expected_base`, `add_expected_dev`,
  `add_expected_rcctl`, `add_expected_ports_info`, `walk_filesystem`.
* `AUDIT.md`: "Known limitations" and "Differences from upstream".
* `sysclean.8`: DESCRIPTION, FILES, EXAMPLES.
* OpenBSD manuals: `locate(1)`, `MAKEDEV(8)`, `rcctl(8)`, `sysmerge(8)`,
  `pkg_info(1)`.
* Upstream: <https://codeberg.org/semarie/sysclean/>.
