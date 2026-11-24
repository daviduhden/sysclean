---
name: sysclean-packages-libraries
description: Use when working on OpenBSD package metadata, PLIST walking, shared-library detection, wantlib relations, PKG_DBDIR, package database locking, or the -a and -p modes of sysclean.
---

# sysclean-packages-libraries

## When to use

Use this skill for:

* package files reported as obsolete;
* missing or incorrect `@wantlib`/used-library relations;
* changes to `plist_reader`, `walk_sysclean`, `add_expected_ports_info` or
  `find_sub`;
* `-a`/`-p` behavior;
* `PKG_DBDIR`, package database locking or partial package installations;
* library ABI/version questions.

## When not to use

Do not use this skill for:

* base `locate`/`MAKEDEV`/`rcctl` inventory (use `sysclean-inventory`);
* file removal mechanics (use `sysclean-apply-mode`);
* account metadata unless it comes from the same PLIST change (use
  `sysclean-accounts` for account semantics);
* unconditional sandbox changes (use `sysclean-sandbox`).

## Related files and components

* `sysclean.pl`: `add_expected_ports_info`, `plist_reader`,
  `sysclean::files`, `sysclean::packages`,
  `OpenBSD::PackingElement::*::walk_sysclean`.
* `sysclean.8`/`README.md`: `-a`, `-p`, `PKG_DBDIR`.
* OpenBSD modules: `OpenBSD::PackageInfo`, `OpenBSD::PackingList`,
  `OpenBSD::LibSpec`, `OpenBSD::Library`.
* Data: `$PKG_DBDIR` (default `/var/db/pkg`), `+CONTENTS`, `+REQUIRED_BY`,
  `+REQUIRING`.

## Model and invariants

* Ordinary queries use `installed_packages()` with the database selected
  when OpenBSD::PackageInfo loads. Apply and `-n` select the canonical host
  database and hold a verified shared flock on its directory. BSD package
  tooling uses the same lock protocol.
* Read `+CONTENTS` with `OpenBSD::PackingList->read` and check the input
  stream. Apply and preview require the PLIST name to match the database
  entry, including synthesized `.libs-*` package names.
* `plist_reader` passes a whitelist of annotations to the PLIST parser.
  `@cwd`, `@file`, `@lib`, `@sample`, `@bin`, `@rcscript`, `@wantlib`,
  `@newuser`, `@newgroup` and `@dir` are relevant.  An annotation that is not
  passed through is silently invisible to the inventory.
* `FileObject`/`Cwd` add package paths and their ancestors to `{expected}`.
* `Sampledir` adds a sample directory to `{ignored}`.
* `Wantlib` indexes OpenBSD LibSpec objects by stem with the package name
  and its `@localbase`. `library_consumers` applies native directory and ABI
  matching. Apply protects every compatible candidate.
* Default mode also suppresses libraries newer than the maximum base
  reference for the same directory and stem.
* `-p` reads package names, local bases and wantlib declarations and prints
  one `library<TAB>package` row per compatible consumer.
* `-a` lists used libraries in ordinary queries. Apply and preview enforce
  dependency protection before queueing and when checking the plan.

Hard rules:

* Never mark a library removable without checking `{used_libs}` and the
  installed package relations.
* Do not assume `@wantlib` is complete for old/broken packages.
* Do not add a new runtime package dependency.
* Do not change `PKG_DBDIR` handling as if it isolated the filesystem scan.
  `sysclean` still scans `/`, reads `/var/sysmerge/etc.tgz` and invokes
  helpers at absolute paths.
* Treat `partial-*` packages as an incomplete inventory: apply mode must
  abort, not guess.

## Analysis procedure

1. Read the PLIST annotations in `plist_reader` and the walkers that consume
   them.  Check whether the relevant annotation is passed through.
2. For a reported package file, inspect the owning package's `+CONTENTS`
   under `PKG_DBDIR`, not only `pkg_info` output.
3. For a library, record:
   * the exact filename (`libfoo.so.M.m`);
   * the stem used by sysclean (`foo`);
   * every package returned by `library_consumers` for the exact path;
   * whether any installed package has a `+REQUIRED_BY`/`+REQUIRING` relation
     that still expects it.
4. Check `pkg_info -W <path>` and the package's `@wantlib` entries.
5. Check ABI/version semantics: `OpenBSD::Library::is_better` compares major
   and minor; it does not prove that a library is unused or safe to remove.
6. Check the package database for `partial-*`, `.libs-*` and unreadable
   `+CONTENTS`.  Apply mode must fail closed on an unreadable packing list or
   a partial installation.
7. Use `-p` to see package consumers, then `-a` only for a read-only listing.
   Do not use `-x -a` to test.
8. For `PKG_DBDIR`, verify whether the alternative database describes the
   same host root.  If not, do not treat the result as a complete reference.

## Modification procedure

1. Prefer a pass-through annotation or a walker over a hard-coded path.
2. Add the annotation to `plist_reader` only if the parser and walker
   semantics are understood.  `@dir` is already supported; `@libset` is not.
3. Keep the stem index aligned with native `OpenBSD::LibSpec` semantics.
4. Preserve the package local base in every mode that evaluates wantlib.
5. On an unreadable PLIST, abort both modes.  On `partial-*`, abort apply
   mode and warn in read-only mode; do not present a complete-looking
   inventory.
6. Add a unit or fixture test using temporary package trees and stub
   modules.  Never require a real package database for `make regress`.
7. Update this skill and `sysclean-inventory` if the model changes.

## Checks

* `perl -c sysclean.pl`
* `make regress`
* read-only `sysclean -p` and `sysclean -a` in a disposable environment
* `pkg_info -W`, `pkg_check`, `+CONTENTS` inspection
* `git diff --check`

## References

* `sysclean.pl`: `add_expected_ports_info`, `plist_reader`,
  `sysclean::files`, `sysclean::packages`,
  `OpenBSD::PackingElement::Wantlib`, `OpenBSD::PackingElement::NewUser`,
  `OpenBSD::PackingElement::NewGroup`.
* `AUDIT.md`: package inventory, `-x -a`, `PKG_DBDIR` limitations.
* OpenBSD manuals: `pkg_info(1)`, `pkg_add(1)`, `package(5)`, `library(7)`.
* Upstream: <https://codeberg.org/semarie/sysclean/>.

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
* Run `perl scripts/validate-agent-knowledge.pl --scope worktree` and, before completion,
  `perl scripts/validate-agent-knowledge.pl --scope range --base <target-branch> --head HEAD`. Also run
  relevant checks listed by this skill. Report checks only when they were run.
* If this skill, another skill, or agent policy changes, review the complete
  instruction set once and repeat validation only to correct a discovered
  inconsistency. Do not add one-run notes that will not help future work.

Include an **Agent & Skills Synchronization** section in the final report. Name
the agents and skills reviewed, instruction files updated, reusable knowledge
added or corrected, validations run, and status **PASS** or **FAIL**.
