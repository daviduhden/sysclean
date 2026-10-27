---
name: sysclean-ignore-rules
description: Use when changing or auditing sysclean ignore files, glob patterns, @user and @group entries, changelist compatibility, ignore precedence, or the difference between -i in read-only and apply mode.
---

# sysclean-ignore-rules

## When to use

Use this skill for:

* `/etc/sysclean.ignore`, `/etc/changelist` or the shipped
  `sysclean.ignore` example;
* `@include`, glob expansion, comments, `+` compatibility lines;
* `@user`/`@group` protection;
* a path unexpectedly reported or unexpectedly protected;
* `-x` versus `-x -i` behavior.

## When not to use

Do not use this skill for:

* removal mechanics (use `sysclean-apply-mode`);
* account deletion rules (use `sysclean-accounts`);
* package sample directories as a package-metadata issue (use
  `sysclean-packages-libraries` for the PLIST side).

## Related files and components

* `sysclean.pl`: `init_ignored`, `add_user_ignored`, `walk_filesystem`,
  `walk_users`, `walk_groups`, `check_removable_path`,
  `path_has_ignored_ancestor`.
* `sysclean.ignore` (example), `/etc/sysclean.ignore`, `/etc/changelist`.
* `sysclean.8`/`README.md`: FILES and `-i` sections.
* `AUDIT.md`: expected/ignored protection and `-i` semantics.

## Sources and precedence

There are three ignore sources:

1. **Hard-coded ignores** in `init_ignored`: `/home`, `/root`, `/tmp`,
   `/usr/local`, `/usr/obj`, `/usr/ports`, `/usr/src`, `/usr/xenocara`,
   `/usr/xobj`, `/etc/ssl/cert.pem`, `/usr/share/zoneinfo`, `/var/backups`,
   `/var/cache`, `/var/cron`, `/var/db`, `/var/dbupdate`, `/var/empty`,
   `/var/log`, `/var/mail`, `/var/run`, `/var/spool/smtpd`, `/var/sysmerge`,
   `/var/syspatch`, `/var/tmp`, `/var/www/htdocs`, `/var/www/logs`,
   `/var/www/run`, `/var/www/tmp`, and `/bsd.syspatch*`.
2. **Service/package ignores** added during inventory: `rcctl`-enabled
   service directories and package sample directories.
3. **User ignore files**: `/etc/changelist` and `/etc/sysclean.ignore`,
   loaded only in read-only default mode and in `-x -i`.

Precedence in `walk_filesystem` is: **ignored first**, then expected, then
unexpected.  An ignored path sets `File::Find::prune`, so its whole subtree
is invisible.  An expected path is skipped; if it is a directory, the walk
descends into it.  An unexpected directory is pruned and reported once.

In apply mode, `check_removable_path` rechecks:

* exact `{ignored}` membership;
* an ignored ancestor (`path_has_ignored_ancestor`);
* exact `{expected}` membership;
* canonical absolute form, no `..`, no control characters, no symlinked
  ancestor.

`/etc/sysclean.ignore` and `/etc/changelist` are always added to
`{expected}`, so they are never reported or removed even when `-i` is absent.

## `-i` semantics

The same flag has opposite effects:

| Invocation | Ignore files loaded? | Effect |
| --- | --- | --- |
| `sysclean` | yes | user-ignored elements are hidden |
| `sysclean -i` | no | user-ignored elements are listed; hard-coded ignores still active |
| `sysclean -x` | no | user-ignored elements are removal candidates |
| `sysclean -x -i` | yes | user-ignored elements are protected |

The controlling expression is
`$with_ignored = $apply ? defined $options{i} : !defined $options{i}`.
Do not replace it with a simple boolean.

## Format rules

* Lines are chomped.  A leading `+` is removed for `changelist(5)`
  compatibility.
* Whole-line comments (`^\s*#.*$`) and whitespace-separated inline comments
  (`\s+#.*$`) are removed.  A `#` without preceding whitespace is part of the
  path.
* A line starting with `/` is an absolute path or glob.  Globs are expanded
  when the file is read, using `File::Glob` semantics.  A trailing slash is
  normalized away (except for `/`) so directory keys match `File::Find`.
* `@user <name>[:uid:group:class:home:shell]` records the full key and the
  name.  The name form protects the account even if another field later
  changes.
* `@group <name>[:gid]` records the full key and the name.
* `@include "path"` loads another file.  A file is processed only once
  (loop guard).  A missing include is an error; it is not silently ignored.
* Any other non-empty line is an error.

Globs are expanded at load time, never during the destructive phase.  A
directory created later and matching an ignore pattern is not added to the
ignored set; document this rather than adding a second glob expansion in
apply mode.

## Risks

* A glob that matches nothing provides no protection.
* A stale `/etc/changelist` or a failed `@include` can silently remove a
  protection; the code now treats a missing required include as fatal.
* An unreadable ignore file is fatal when it exists; an absent optional
  top-level file is normal.
* An ignore entry for a directory protects the whole subtree only if the
  exact directory path is in `{ignored}` at walk time.
* `@user`/`@group` matching is name/key based; do not assume it matches a
  uid-only or gid-only tuple unless that exact key is present.
* `-x` without `-i` deliberately ignores the user files.  Never describe it
  as "respecting ignored files".
* Hard-coded ignores are not user-configurable and are always active.

## Modification procedure

1. Decide whether the change belongs to the hard-coded list, the service/
   package inventory, or the user file format.
2. Preserve ignored-before-expected precedence and directory pruning.
3. Keep exact-string keys compatible with `File::Find` (absolute, no trailing
   slash except `/`).
4. Validate `@user`/`@group` names and keep the name-based protection.
5. Keep `@include` loop protection and required-include failure.
6. Do not add a glob expansion to `remove_path` or `apply`.
7. Update this skill and the FILES/`-i` documentation when semantics change.
8. Add a non-destructive unit test for pattern parsing and precedence.

## Checks

* `perl -c sysclean.pl`
* `make regress`
* read-only tests with a fixture `/etc/sysclean.ignore` and `/etc/changelist`
  in a disposable environment
* `sysclean` versus `sysclean -i` output comparison
* `git diff --check`

## References

* `sysclean.pl`: `init_ignored`, `add_user_ignored`, `walk_filesystem`,
  `check_removable_path`, `path_has_ignored_ancestor`.
* `sysclean.8`/`README.md`: FILES, `-i`, `-x`.
* `AUDIT.md`: expected/ignored protection, `-i`, glob limitation.
* OpenBSD manuals: `changelist(5)`, `File::Glob(3p)`, `glob(3)`.

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
