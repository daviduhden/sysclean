---
name: sysclean-build-release
description: Use when working on the sysclean BSD makefile, bsd.prog.mk, script or manual installation, DESTDIR/BINDIR/MANDIR, release tarballs, versioning, distributed files, or the sysutils/sysclean port.
---

# sysclean-build-release

## When to use

Use this skill for:

* `Makefile` targets and variables;
* `realinstall`, `BINDIR`, `MANDIR`, `DESTDIR`, permissions/owners;
* `README.md` generation;
* `release` and `DISTRIBUTED_FILES`;
* versioning and tarball contents;
* port/package compatibility.

## When not to use

Do not use this skill for:

* runtime behavior (use the domain skill);
* documentation content (use `sysclean-documentation`);
* tests that are not build/release related (use `sysclean-testing`).

## Related files and components

* `Makefile`.
* `sysclean.pl`, `sysclean.8`, `README.md`, `sysclean.ignore`, `AUDIT.md`.
* `bsd.prog.mk` from the base system.
* `pax`, `install`, `mandoc`, `make` (BSD make/bmake).

## Current build contract

* The Makefile is a BSD makefile and begins with `# bake-format off` to keep
  GNU-make formatters away.  It uses `.if/.else/.endif`,
  `.include <bsd.prog.mk>`, `${.CURDIR}`, `${MAKE}` and `?=`.
* `MAN=sysclean.8`; `SCRIPT=sysclean.pl`.
* `BINDIR?=/usr/local/sbin`; `MANDIR?=/usr/local/man/man`.
* `realinstall` installs `${SCRIPT}` as `${DESTDIR}${BINDIR}/sysclean` with
  `${INSTALL} ${INSTALL_COPY} -o ${BINOWN} -g ${BINGRP} -m ${BINMODE}`.
  The manual is installed by `bsd.prog.mk` from `MAN`/`MANDIR`.
* `README.md` is generated from `sysclean.8` with `mandoc -T markdown` and a
  small `sed` normalization.
* `regress` runs syntax, apply unit tests, man lint, README sync and man date.
* `release` is conditional on `VERSION`:
  * undefined: prints an error and fails;
  * defined: builds `sysclean-${VERSION}.tar.gz` from
    `DISTRIBUTED_FILES` using `chmod a+rX` and `pax`.
* `DISTRIBUTED_FILES` currently includes `AUDIT.md`, `Makefile`,
  `README.md`, `regress`, `sysclean.ignore`, `sysclean.8` and
  `sysclean.pl`.  The non-destructive `regress/` tests are included so that
  `make regress` is usable from a release tarball.

Hard rules:

* Use BSD make, never GNU make.
* Do not remove `bsd.prog.mk` or replace it with a hand-written install.
* Do not change `DESTDIR`/`BINDIR`/`MANDIR` semantics without checking the
  port and the install target.
* Do not add a runtime file to the repository without deciding whether it
  belongs in `DISTRIBUTED_FILES`.
* Do not edit `README.md` independently of `sysclean.8`; it is generated.
* Keep the release reproducible from a clean Git checkout.

## Analysis procedure

1. Read the whole `Makefile`, including the conditional release block.
2. Identify whether the change affects the default goal, `all`, `install`,
   `realinstall`, `regress`, `README.md` or `release`.
3. Check `DISTRIBUTED_FILES`: every file needed to build/read the release must
   be present; generated files must be reproducible.
4. Check `DESTDIR` use: only the script install is staged; the man page comes
   from `bsd.prog.mk`.
5. Check permissions and owners: `${BINOWN}`, `${BINGRP}`, `${BINMODE}`,
   `chmod a+rX` for distributed files.
6. Check versioning: `VERSION` must be explicit; no date-based or implicit
   version.
7. Check the port: `sysutils/sysclean` may expect a specific install layout,
   manual location and file list.

## Modification procedure

1. Make the smallest Makefile change.
2. Preserve BSD make syntax and the `bake-format off` directive.
3. Update `DISTRIBUTED_FILES` if a new non-test file is required at runtime or
   for documentation.
4. Regenerate `README.md` through the Makefile rule, not by hand.
5. Bump the version only with an explicit decision; do not invent one.
6. Verify the release in a clean checkout or disposable directory.
7. Update this skill if the build contract changes.

## Checks

* `bmake -n` (parse only)
* `make regress`
* `make README.md` and confirm the README diff is limited to the intended
  manual change
* `make release VERSION=<version>` in a clean tree
* inspect the tarball with `pax -f`/`tar -tzf`:
  * top-level `sysclean-<version>/`
  * `Makefile`, `README.md`, `sysclean.ignore`, `sysclean.8`,
    `sysclean.pl`, `AUDIT.md`
  * `regress/apply.t` and `regress/stubs/` (non-destructive tests)
  * no build artifacts, temporary files or test residue
* `git diff --check`
* `git status`

## References

* `Makefile`.
* `bsd.prog.mk` and `make(1)`.
* `pax(1)`, `install(1)`, `mandoc(1)`.
* OpenBSD port `sysutils/sysclean`.
* `AGENTS.md`: BSD make and release rules.

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
* Run `python3 scripts/validate-agent-knowledge.py --scope worktree` and, before completion,
  `python3 scripts/validate-agent-knowledge.py --scope range --base <target-branch> --head HEAD`. --head HEAD Also run
  relevant checks listed by this skill. Report checks only when they were run.
* If this skill, another skill, or agent policy changes, review the complete
  instruction set once and repeat validation only to correct a discovered
  inconsistency. Do not add one-run notes that will not help future work.

Include an **Agent & Skills Synchronization** section in the final report. Name
the agents and skills reviewed, instruction files updated, reusable knowledge
added or corrected, validations run, and status **PASS** or **FAIL**.
