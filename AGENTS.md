# AGENTS.md - sysclean

This repository is a fork of `sysclean`, an OpenBSD administrative tool that
finds obsolete files, directories, users and groups after an upgrade.  The
canonical upstream is read-only.  This fork adds an explicit apply mode
(`-x`) that can remove files, remove empty directories, delete users and
groups, and update selected account properties.

Treat every change to detection, selection, path validation, account
handling or removal as security-sensitive.

## Repository map

| Path | Purpose |
| --- | --- |
| `sysclean.pl` | The entire Perl program: scanner, modes, package/library integration, account checks and apply mode. |
| `sysclean.8` | Primary documentation in `mdoc(7)` format. |
| `README.md` | Generated from `sysclean.8` by the `README.md` Makefile rule. |
| `AUDIT.md` | Security review and known limitations of apply mode. Read it before changing `-x`. |
| `Makefile` | BSD makefile (`bmake`), `bsd.prog.mk`, regression checks, installation and release tarball. |
| `scripts/validate-agent-knowledge.py` | Dependency-free structural and Git-diff enforcement for agent/skill synchronization. |
| `.github/workflows/agent-maintenance.yml` | Pull-request enforcement for agent/skill synchronization. |
| `sysclean.ignore` | Example ignore file shipped with the project. |
| `regress/apply.t` | Non-destructive unit tests for apply-mode helpers. |
| `regress/stubs/` | Stub `OpenBSD::*` modules used only by the unit tests. |
| `.agents/skills/` | Specialized procedures for agents. |

## Relationship with upstream and OpenBSD

* Upstream: <https://codeberg.org/semarie/sysclean/>.  It remains the
  canonical read-only scanner.
* Fork: <https://github.com/daviduhden/sysclean>.
* The fork targets OpenBSD-current.  The reference installation is the
  running release/current installation, its locate databases,
  `/var/sysmerge/etc.tgz`, enabled `rcctl(8)` services and the installed
  package database.
* Never attribute fork-only behavior (`-x`, apply-mode `-i`, `usermod`
  recommendations, account uid/gid protection, fail-closed reference checks)
  to upstream.
* Preserve upstream copyright, license text and attribution.  The fork
  copyright line is already present in `sysclean.pl` and `sysclean.8`.

## Architecture

`sysclean.pl` is a single Perl file with several packages:

* `sysclean` - base scanner, inventory, ignore handling, account walking,
  apply helpers and sandbox setup.
* `sysclean::files` - default mode; filters libraries used by packages and
  suppresses a locally newer library version.
* `sysclean::allfiles` - `-a`; reports every unexpected path, including
  libraries used by packages.
* `sysclean::packages` - `-p`; reports obsolete libraries with the packages
  that use them.  Does not apply changes.
* `OpenBSD::PackingElement::*` - walkers that translate PLIST elements into
  expected paths, users, groups, sample directories and used libraries.

The program flow is:

1. `create()` validates options and chooses a subclass.
2. `new()` loads hard-coded ignores, runs `init()`, always protects
   `/etc/sysclean.ignore` and `/etc/changelist`, and optionally loads the
   user ignore files.
3. `init()` locks the package database, sets the initial unveil view, builds
   the base inventory, then the account and package inventory.  Read-only
   mode installs its `pledge(2)` ceiling after external helpers finish.
4. `walk()` scans users, groups and the filesystem.
5. In apply mode only, `apply()` deduplicates the recorded actions, validates
   them, tightens the sandbox, removes/updates elements and reports failures.

### Inventory representation

* `{expected}` - exact absolute paths that belong to the reference
  installation.  Built from a hard-coded list, `/etc/hostname.*`, the
  `locate` source/X databases, `/dev/MAKEDEV` echo output, enabled `rcctl`
  services, package PLIST entries and package `@cwd` ancestors.
* `{ignored}` - exact paths or directory subtrees that must not be inspected
  or removed.  Contains hard-coded writable/service trees, `/bsd.syspatch*`,
  package sample directories and paths loaded from ignore files.
* `{users}`, `{groups}` - expected account keys from
  `/var/sysmerge/etc.tgz` and package `@newuser`/`@newgroup` entries.
* `{user_fields}`, `{group_fields}` - reference fields used to detect modified
  accounts and to refuse unsafe uid/gid changes.
* `{used_libs}` - `@wantlib` entries mapping a library name to the packages
  that use it.
* `{actions}` - apply-mode plan.  Each item is an exact path, user, group or
  user modification.  Discovery and execution are separate phases.

`File::Find` walks from `/` with `follow => 0` and `no_chdir => 1`.  An
ignored path is pruned.  An unexpected directory is pruned and reported as
one directory; its contents are not inspected.  Consequently, the expected
set must contain every legitimate directory.  Unknown directories are not
recursively emptied.

### Base, packages and libraries

* Base files come from the hard-coded list, `/etc/hostname.*`, the
  `locate -d src.db -d xorg.db '*'` output, `/dev/MAKEDEV all` in `eo=echo`
  mode, and `rcctl ls on`.
* Package files come from `OpenBSD::PackageInfo::installed_packages()` and
  `OpenBSD::PackingList->from_installation()`.
* Default mode suppresses libraries present in `{used_libs}` and warns about
  a local library that is newer than the reference (`OpenBSD::Library` and
  `is_better`).
* `-p` uses `OpenBSD::PackingList::DependOnly` and prints
  `path<TAB>package`.
* `-a` does not filter used libraries in read-only output.  In apply mode,
  `sysclean::allfiles::find_sub` refuses to queue a library present in
  `{used_libs}` and warns; unusual library names may not be recognized.

### Accounts

Expected system users/groups come from `/var/sysmerge/etc.tgz` (base) and
package metadata.  Only uid/gid below 1000 are considered.  A modified user
is one whose `name:uid` matches but whose group, login class, home or shell
differs.  Apply mode restores those fields with `usermod(8)`.  Obsolete users
and groups are removed with `userdel(8)`/`groupdel(8)`; `userdel` is called
without `-r`, so home directories are preserved.

If a name exists in the reference but the current uid (or gid) differs, the
account is reported but not removed or modified.  Immediately before an
account helper runs, the account is re-read and revalidated.

### Analysis, report and apply

* Analysis/read-only: `sysclean`, `sysclean -i`, `sysclean -a`,
  `sysclean -p`.  No system modification.
* Report: stdout lists paths, `@user` and `@group` lines; warnings go to
  stderr with `[WARN]`.
* Apply: only `sysclean -x` (optionally `-a` or `-i`).  `-x -p` is refused.

## Option contract

| Combination | Behavior |
| --- | --- |
| no options | Read-only.  Lists obsolete paths, users and groups.  Loads user ignore files (`/etc/changelist`, `/etc/sysclean.ignore`) and hides ignored elements. Excludes libraries used by packages. |
| `-i` | Read-only "include ignored": does **not** load the user ignore files, so ignored elements are listed.  Hard-coded ignores remain active. |
| `-a` | Read-only all-files: reports used libraries too.  Cannot be combined with `-p`. |
| `-p` | Read-only package mode: prints obsolete libraries and the packages using them.  Cannot be combined with `-a` or `-x`. |
| `-x` | Apply mode.  Loads no user ignore files, so elements listed there are removal candidates.  Hard-coded ignores remain active. |
| `-x -i` | Apply mode **with** user ignore files loaded.  Paths matching those files, and `@user`/`@group` entries, are protected and never removed.  This is the opposite of the read-only meaning of `-i`. |
| `-x -a` | Apply all-files.  Warns that recognized used libraries are protected from removal; unrecognized library names may not be matched to `{used_libs}`. |
| `-x -p` | Refused. |
| `-a -p` | Refused (usage error). |

The controlling expression is
`my $with_ignored = $apply ? defined $$options{i} : !defined $$options{i};`
in `create()`.  Do not "simplify" it without preserving this contract.

## Fundamental invariants

1. The default mode is strictly read-only.
2. No system modification happens without an explicit `-x`.
3. Only elements selected by the authorized detection procedures may be
   modified.
4. Protected paths are never removed.
5. Removal is never recursive.
6. Symbolic links are never followed during removal.
7. Relative, empty, `/`, non-canonical, control-character and `..` paths are
   refused.  A path with a symlinked ancestor is refused.
8. Account operations validate names and `usermod` arguments rigorously.
9. Home directories are preserved when deleting users.
10. Partial errors are reported and reflected in the exit status.
11. Security mechanisms are not disabled or weakened without a documented
    justification and review.
12. Query modes remain independent of the destructive mode.

Additional implementation rules:

* Expected, ignored and `/etc/changelist`-protected elements are refused a
  second time in apply mode.
* A path inside an ignored directory is refused even if it somehow reached
  the action list.
* A known account name with a different uid/gid is never treated as an
  obsolete account.
* Reference-inventory failures are fail-closed in apply mode: empty/failed
  `locate`, failed `rcctl`, missing/empty `etc.tgz` members, unreadable
  package PLISTs, `partial-*` packages and missing account helpers abort
  before removal.
* Apply mode exits with status 1 if any requested removal or account update
  fails.

## Security policy

Any change to detection, selection or removal is potentially critical.
Before changing those components, require an analysis of:

* false positives, including incomplete reference data;
* race conditions (TOCTOU) between scan, validation and removal;
* symlink attacks, including ancestor components and final components;
* path traversal and non-canonical paths;
* argument injection into `userdel`, `groupdel`, `usermod` or other helpers;
* validation errors and silent configuration-loading failures;
* process privileges and helper child processes;
* partial failures and exit status;
* differences between the detection phase and the application phase.

Do not consider a change safe merely because it uses `pledge(2)` or
`unveil(2)`.  Distinguish implemented guarantees, verified guarantees and
known limitations.  Account helper children are outside the parent's
sandbox because no `execpromises` are installed.

## Agent policy

* Use subagents for independent investigation and review when available.
* For sensitive changes, assign a dedicated security-review subagent.
* Each subagent must report the modules examined, risks found, evidence
  (files/functions/commits) and the tests it considers necessary.
* The main agent integrates the findings, resolves contradictions and remains
  accountable for the final change.
* Do not let a security subagent's approval replace negative tests and
  independent review.
* Do not run `sysclean -x` on the host while auditing or testing.
* Do not delete real users or groups, or modify `/etc/master.passwd`,
  `/etc/group` or account databases for testing.
* Do not assume an element is disposable because it is absent from one
  database.
* Never add recursive deletion, never allow glob expansion during the
  destructive phase, never weaken path validation for performance, and never
  hide partial failures.

## Development conventions

* Use the Perl version shipped in OpenBSD base (`use v5.36` currently).
* Prefer base-system modules (`OpenBSD::*`, `File::Find`, `File::Basename`,
  `Archive::Tar`, `Getopt::Std`) and package infrastructure.  Avoid CPAN
  dependencies and new runtime dependencies.
* Avoid GNU-only tools; use OpenBSD/BSD equivalents.
* Use BSD make (`bmake`), never GNU make.
* Keep changes small and reviewable.  Preserve inherited behavior unless a
  documented safety fix requires a change.
* Preserve license headers, copyrights and upstream attribution.
* Use lexical filehandles, list-form `open`/`system`, `defined` checks and
  `\A...\z` anchors.  Do not use string `eval`, shell interpolation or
  unnecessary subprocesses.
* Do not add privileges beyond those already needed by `-x`.
* Do not run `sysclean` against the host as part of an ordinary edit; use
  static checks and disposable environments.

## Testing and validation

Safe checks for normal changes:

* `perl -c sysclean.pl`
* `bmake regress` (syntax, apply unit tests, man lint, README sync, man date)
* `python3 scripts/validate-agent-knowledge.py --scope worktree` (agent/skill structure and
  local-reference check)
* `python3 scripts/validate-agent-knowledge.py --scope range --base <target-branch> --head HEAD` (requires
  the target branch to be available locally)
* `mandoc -T lint -W style sysclean.8`
* `git diff --check`

Absolute rule: automated tests must never run `sysclean -x` against the
host.  Destructive tests belong in disposable virtual machines or isolated
fixtures.  Do not assume `DESTDIR` or `PKG_DBDIR` redirects every operation:
`sysclean` scans `/`, reads `/etc` and `/var/sysmerge`, and invokes account
helpers at absolute paths.  Verify the real paths before treating an
environment variable as isolation.

`regress/apply.t` is a unit test only.  It uses `File::Temp` and stub
`OpenBSD::*` modules; it never touches system files or accounts.  Do not add
dangerous tests to `make regress`.

## Documentation maintenance

| Change | Update |
| --- | --- |
| Architecture, modes, invariants | `AGENTS.md` and the relevant skill |
| Detection/inventory | `sysclean-inventory` |
| Removal/apply | `sysclean-apply-mode` and `AUDIT.md` |
| Sandbox/privileges | `sysclean-sandbox` and `AUDIT.md` |
| Accounts | `sysclean-accounts` |
| Tests | `sysclean-testing` |
| Packages/libraries | `sysclean-packages-libraries` |
| Ignore rules | `sysclean-ignore-rules` |
| Perl structure | `sysclean-perl-development` |
| Build/release | `sysclean-build-release` |
| Manual/README | `sysclean-documentation` |
| Upstream merge | `sysclean-upstream` |

Do not rewrite every document after each change.  Keep instructions
synchronized with the code and delete stale references.  `AUDIT.md` is the
authoritative security record; skills should reference it rather than
duplicate it.

## Continuous Agent & Skills Maintenance

**Agent instructions and skills are living repository artifacts.**

**Every repository modification MUST include an agent/skills synchronization
step.** This applies to code, tests, configuration, dependencies, build and CI
workflows, documentation, architecture, and changes to agent instructions
themselves. A change that updates no applicable agent or skill knowledge is
incomplete; do not satisfy this rule with cosmetic edits, timestamps, or empty
sections.

Before starting a change and again once at the end of the task:

1. Inspect the root and any path-relevant `AGENTS.md` files, specialized
   `.agent.md` files, and skills under `.agents/skills/`,
   `.github/skills/`, `.claude/skills/`, or other tool-specific skill roots.
   Also inspect provider instruction files such as `CLAUDE.md`, Copilot
   instructions, and Cursor rules when present.
2. Use the change-to-skill mapping above and each skill's **When to use**
   section to identify the affected instructions. For cross-cutting work,
   inspect every plausible skill and resolve overlaps instead of guessing.
3. Update each affected `AGENTS.md`, agent, or `SKILL.md` with verified,
   reusable knowledge: current behavior, paths, commands, validation steps,
   safety constraints, or architecture. Correct stale or contradictory
   instructions and validate links and cross-references.
4. If no existing skill covers a recurring responsibility, decide whether a
   focused skill is justified; otherwise extend the nearest skill. Do not
   create duplicate or one-task skills. Keep Agent Skills frontmatter intact.
5. When changing instructions, skills, or this policy, review the full
   instruction set once for consistency. Repeat validation only if that review
   finds and fixes an inconsistency; this avoids a maintenance loop.
6. Run `python3 scripts/validate-agent-knowledge.py --scope worktree` for structural and
   local-reference checks. Before completing a change, run
   `python3 scripts/validate-agent-knowledge.py --scope range --base <target-branch> --head HEAD` using the
   branch the change will be compared against. CI runs the same change check
   for pull requests. Also run the normal checks relevant to the implementation.

The validator checks Git change paths, meaningful non-whitespace instruction
diffs, required sections/frontmatter, Markdown fences, and local Markdown link
targets. It cannot determine whether an update is semantically relevant or
factually correct; a human/agent review against the implementation remains
mandatory.

> Before completing any task, inspect the applicable AGENTS.md and SKILL.md
> files, update the affected instructions, and validate their consistency with
> the implementation.
>
> A code change without the corresponding agent knowledge maintenance is
> considered incomplete.
>
> Never claim completion when the synchronization step has been skipped or has
> failed.

### Shared Agent Knowledge Validation Contract

Use `python3 scripts/validate-agent-knowledge.py --scope worktree` for local
changes and `python3 -m unittest discover -s tests/agent_knowledge_validator -v`
for its contract tests. The validator requires Python 3.11+ and Git, uses only
the Python standard library, and publishes contract version `1.0.0`. All
adopting repositories share the same CLI, AK001-AK006 identifiers, output
schema, and exit codes (`0` pass, `1` policy failure, `2` execution/configuration
error). For a pull request, pass both revisions with
`--scope range --base BASE_REF --head HEAD_REF`; compare from their merge base.

Read [Agent Knowledge Validation Contract](docs/agent-knowledge-validation.md)
for the complete rules, JSON schema, optional repository configuration,
warning semantics, and extension process. AK004 and AK006 can require human
review; their warnings do not prove or disprove semantic correctness. Keep the
canonical script and black-box unittest suite byte-identical across adopting
repositories. Repository-specific requirements belong in the documented TOML
configuration or a stable `AKX...` extension, never in a private fork of the
shared rules. The GitHub PR workflow runs the same tests and range command;
it does not edit files or require secrets.

### Mandatory Definition of Done

- [ ] Repository changes implemented.
- [ ] Relevant agent instructions reviewed.
- [ ] Relevant skills reviewed.
- [ ] Affected AGENTS.md / SKILL.md files updated.
- [ ] Obsolete knowledge removed.
- [ ] New reusable knowledge incorporated.
- [ ] Agent and skill references validated.
- [ ] Automated maintenance checks passed.
- [ ] Final synchronization status reported.

If a check cannot be completed, fix it or state the specific limitation and
mark synchronization as **FAIL**; do not claim the task is complete.

Every final task report must include **Agent & Skills Synchronization** and
list the agents and skills reviewed, instruction files updated, reusable
knowledge added or corrected, validations actually run, and a final **PASS** or
**FAIL** status. Report semantic review separately from automated checks.

### Post-Change Knowledge Synchronization

Every agent working in this repository owns this synchronization step,
regardless of the coding tool used. Agents must identify the skills related to
their responsibilities, review them after every repository change, update them
when implementation behavior or reusable procedures change, and verify that
their own instructions remain accurate. They must run or delegate the
applicable checks, report the synchronization result, and leave the task
incomplete if required instruction updates or validation are missing.

## Skills

Use the specialized skill when the task matches its description:

* `sysclean-inventory` - obsolete-element detection and false positives.
* `sysclean-packages-libraries` - package metadata, PLIST, shared libraries,
  `-a`/`-p`, `PKG_DBDIR`, package locking.
* `sysclean-ignore-rules` - ignore files, globs, `@user`/`@group`,
  precedence, `-i` and `-x`.
* `sysclean-apply-mode` - `-x` planning, validation, removal, errors.
* `sysclean-accounts` - users, groups, `userdel`/`groupdel`/`usermod`.
* `sysclean-sandbox` - `pledge(2)`, `unveil(2)`, privileges and children.
* `sysclean-perl-development` - Perl structure, safety and static review.
* `sysclean-testing` - regression, unit, negative and isolation testing.
* `sysclean-build-release` - BSD make, install and release.
* `sysclean-documentation` - `mdoc`, README, AUDIT and safe examples.
* `sysclean-upstream` - upstream comparison, merges and patches.

## Known limitations

`AUDIT.md` is authoritative.  In particular: a TOCTOU window remains between
validation and removal; a top-level path requires `unveil("/", "rwc")`; the
`rwc` grant covers the whole parent directory; account helper children are
not confined by the parent's pledge/unveil; stale or incomplete reference
data can still produce false positives; `-x -a` protects only libraries whose
names match `{used_libs}`; ignore globs are expanded at load time; and
`PKG_DBDIR`/`DESTDIR` do not isolate the host root.
