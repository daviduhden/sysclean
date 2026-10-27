---
name: sysclean-upstream
description: Use when comparing this fork with the canonical sysclean upstream, merging upstream changes, preserving fork-only apply mode, resolving conflicts, porting security fixes, or preparing patches for upstream.
---

# sysclean-upstream

## When to use

Use this skill for:

* fetching or comparing upstream;
* merging/rebaseing upstream changes;
* preserving the fork's `-x` mode during a merge;
* backporting upstream security/correctness fixes;
* preparing an upstreamable patch that excludes fork-only features;
* adapting to a new OpenBSD release.

## When not to use

Do not use this skill for:

* ordinary local feature work that has no upstream relationship;
* deciding to delete local fork changes without authorization;
* documentation-only edits that do not affect provenance.

## Related files and components

* Remotes: `origin` (GitHub fork), `upstream` (Codeberg canonical, push
  disabled).
* `sysclean.pl` fork provenance comment.
* `sysclean.8`/`README.md` FORK section.
* `AUDIT.md`.
* Git history and tags (upstream 4.2 merge base historically; fork tags 5.0,
  5.1).
* OpenBSD `sysutils/sysclean` port.

## Upstream versus fork

Canonical upstream: <https://codeberg.org/semarie/sysclean/>.  It is
read-only.

Fork-only behavior:

* apply mode `-x` and all apply helpers, including `-x -a` protection for
  libraries recorded in `{used_libs}`;
* apply-mode `-i` semantics;
* `usermod` recommendations for modified users;
* account uid/gid mismatch protection and revalidation;
* `@dir` PLIST pass-through, stripping of `pkg_add(1)` `!` markers from
  account metadata, and name-based `@user`/`@group` matching;
* fail-closed reference-inventory checks;
* `[INFO]`/`[WARN]`/`[ERROR]` logging and control-character escaping;
* additional hard-coded ignores (`/etc/ssl/cert.pem`,
  `/usr/share/zoneinfo`, `/var/dbupdate`, `/var/tmp`, `/var/empty`);
* always protecting `/etc/sysclean.ignore` and `/etc/changelist`;
* the later read-only `pledge(2)` (after helper execution);
* apply unit tests, `AUDIT.md`, the FORK manual section and fork copyright.

Everything else is inherited: read-only scanner, package/library integration,
locate/MAKEDEV/rcctl inventory, base/package account model, README generation,
release/regress targets.

Hard rules:

* Do not attribute fork-only features to upstream.
* Do not delete local fork modifications without explicit authorization.
* Do not silently drop `-x` during a merge.
* Do not merge upstream changes without re-running the read-only and
  apply-mode checks.
* Preserve upstream license and attribution.

## Analysis procedure

1. Inspect remotes and tags:
   * `git remote -v`
   * `git tag --list`
   * `git log --oneline --decorate --graph --all`
2. Identify the merge base and the fork-only commits:
   * `git merge-base HEAD upstream/main`
   * `git log --oneline <merge-base>..upstream/main`
   * `git log --oneline <merge-base>..HEAD`
3. Compare the files most likely to conflict:
   * `sysclean.pl` (inventory, account, apply, walkers);
   * `sysclean.8`/`README.md` (options, CAVEATS, FORK);
   * `Makefile` (regress/release);
   * `AUDIT.md` (fork-only).
4. Classify each upstream change as:
   * safe to take unchanged;
   * needs adaptation because of `-x`;
   * relevant security fix;
   * incompatible with a fork invariant;
   * documentation/version-only.
5. Check whether the upstream change alters the expected/ignored model,
   library relations, account keys, helper invocation or sandbox sequence.
   Those require the corresponding domain skill and the apply-mode security
   review.
6. Check new OpenBSD modules/APIs against the base Perl and the target
   release/current.
7. Prepare an upstream patch separately if the fix is generic: exclude `-x`,
   apply-mode `-i`, fork logging, fork ignores and AUDIT-specific text unless
   the upstream maintainer asks for them.

## Merge procedure

1. Start from a clean tree; record the current commit and tags.
2. Fetch upstream read-only; do not push to upstream.
3. Merge or rebase in a branch dedicated to the sync.
4. Resolve conflicts by preserving the fork invariants first, then upstream
   behavior, then style.
5. Re-apply fork-only features deliberately; do not assume a conflict
   resolution kept them.
6. Update `AUDIT.md` if the sandbox, validation or known limitations change.
7. Update the FORK section only if provenance or repository location changes.
8. Run read-only checks and the non-destructive test suite.  Do not run `-x`
   on the host.
9. Record the upstream commit/tag and the fork commit in the final report.

## Checks

* `perl -c sysclean.pl`
* `make regress`
* `git diff --check`
* `git status`
* read-only smoke tests in a disposable VM (`sysclean`, `-a`, `-p`, `-i`)
* apply-mode unit tests (`regress/apply.t`)
* review of every conflict hunk for lost fork invariants

## References

* `AGENTS.md`: upstream/fork relationship and maintenance table.
* `AUDIT.md`: fork-only security record.
* `sysclean.pl` header, `sysclean.8` FORK section.
* Upstream: <https://codeberg.org/semarie/sysclean/>.
* Fork: <https://github.com/daviduhden/sysclean>.

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
