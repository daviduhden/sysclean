---
name: sysclean-documentation
description: Use when editing sysclean.8, README.md, AUDIT.md, option descriptions, destructive-mode warnings, examples, environment variables, or validating mdoc and generated documentation.
---

# sysclean-documentation

## When to use

Use this skill for:

* `sysclean.8` (`mdoc(7)`);
* `README.md` and the `README.md` Makefile rule;
* `AUDIT.md` updates tied to apply-mode or sandbox changes;
* `-a`, `-i`, `-p`, `-x` descriptions;
* examples, warnings, environment variables and exit status;
* `mandoc` lint, README sync and `.Dd` date checks.

## When not to use

Do not use this skill for:

* runtime behavior changes (fix the code first, then document);
* build/release mechanics (use `sysclean-build-release`);
* duplicating the full `AUDIT.md` into a skill.

## Related files and components

* `sysclean.8`: primary manual.
* `README.md`: generated from the manual.
* `AUDIT.md`: security record.
* `Makefile`: `README.md` rule, `run-regress-man-lint`,
  `run-regress-man-readme`, `run-regress-man-date`.
* `sysclean.ignore`: example file, not the live `/etc/sysclean.ignore`.

## Documentation model

* `sysclean.8` is the source of truth.  `README.md` is generated with
  `mandoc -T markdown` and a small `sed` normalization.
* `AUDIT.md` is the authoritative security record for `-x`.  Do not duplicate
  its full content in skills or in `AGENTS.md`; reference it.
* Keep the manual and README synchronized.  Prefer editing the manual and
  running the Makefile rule; do not hand-edit README prose in normal work.
* `.Dd` must match the date of the last commit that changes `sysclean.8` (the
  regress target checks this).
* Preserve upstream attribution and the fork provenance section.

## Required content

The manual must clearly state:

* default mode is read-only;
* `-x` is the only destructive mode;
* `-x` is incompatible with `-p`;
* `-x -a` reports used libraries in read-only mode but protects them from
  removal when their names match `{used_libs}`;
* `-i` has opposite effects in read-only and apply mode:
  * read-only `-i` includes ignored filenames;
  * `-x -i` protects ignored elements;
* `-x` removes files with `unlink`, empty directories with `rmdir`, users and
  groups with `userdel`/`groupdel`, and restores selected user fields with
  `usermod`;
* home directories are preserved;
* a known account name with a different uid/gid is reported but not removed
  or modified;
* a path with a symlinked ancestor is not removed;
* hard-coded ignores are always respected;
* apply mode exits 1 if a requested removal or account update fails.

`PKG_DBDIR` affects only the package database.  Do not imply that
`PKG_DBDIR` or `DESTDIR` isolates the host root; record that limitation in
`AUDIT.md` and `AGENTS.md`, not as a runtime option in the manual.

Examples must be safe.  Prefer read-only examples first.  Do not present
`sysclean -x` as a routine command without the review warning and a clear
statement that it modifies the system.

## Analysis procedure

1. Read `sysclean.8` and `README.md` side by side; identify drift.
2. Check every option against `create()`, `main()`, the subclass selection and
   the actual behavior.
3. Check every example against the current output format.
4. Check `AUDIT.md` for claims that the manual must not contradict.
5. Check `FILES` and `ENVIRONMENT` against the code:
   * `/etc/sysclean.ignore`, `/etc/changelist`;
   * `PKG_DBDIR`;
   * hard-coded protected paths;
   * service/package-generated files.
6. Check the `.Dd` date and the FORK section.

## Modification procedure

1. Edit `sysclean.8` first.
2. Update `.Dd` to the intended commit date.
3. Regenerate `README.md` with the Makefile rule.
4. Update `AUDIT.md` separately if the change affects apply-mode guarantees,
   validation, sandbox behavior or limitations.
5. Do not add claims that are only planned or unverified.  Mark implemented,
   verified and known limitations distinctly.
6. Do not copy the full `AUDIT.md` into `AGENTS.md` or a skill.
7. Run `mandoc -T lint -W style sysclean.8` and the README sync/date checks.

## Checks

* `mandoc -T lint -W style sysclean.8`
* `make README.md`
* `make regress` (man lint, README sync, man date)
* `git diff --check`
* inspect `git diff` for accidental README-only edits or stale dates
* confirm no documentation claims a sandbox guarantee that is not implemented

## References

* `sysclean.8`, `README.md`, `AUDIT.md`.
* `Makefile`: man/README targets.
* `mdoc(7)`, `mandoc(1)`, `changelist(5)`, `pkg_info(1)`, `sysmerge(8)`.
* `AGENTS.md`: documentation maintenance table.

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
