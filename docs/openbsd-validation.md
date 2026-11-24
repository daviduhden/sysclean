# Native OpenBSD validation

Use a disposable OpenBSD-current VM and a second VM on the supported stable
release chosen for the change. Record the image and architecture, `uname -r`,
Perl version, tested revision, installed sets and package state. Cover a clean
installation and an upgraded installation. Include a system with X sets and one
without them. Restore a snapshot between cases that alter the guest.

## Portable checks

```sh
perl -Iregress/stubs -c sysclean.pl
prove regress/apply.t
prove tests/agent_knowledge_validator/test_validator.pl
```

These tests use temporary fixtures. Stub sandbox calls record requested
permissions. Native checks establish whether the kernel accepts them.

## Native matrix

Run `make regress` using the guest's BSD make and base Perl. Use test images
without shared host filesystem mounts, real account data or service
credentials. Never use the live development system for an apply test.

| Area | Cases and evidence |
| --- | --- |
| Query modes | Compare default, `-a`, `-i` and `-p` output on clean and upgraded images. Record diagnostics, exit status and any candidates on the clean image. |
| Apply selection | Compare `-n` and `-x` candidate decisions with the same `-a` and `-i` flags. Cover exclusions from both local files, explicit inclusion of ignored candidates, recognized used libraries and invalid mode combinations. |
| Packages | Check current native PLIST handling with ordinary, metadata-only and `.libs-*` package examples. Include directory-qualified library requirements and compatible minor versions. Check lock contention and refusal of missing, partial or invalid package inputs with guest fixtures. |
| System inventory | Check expected paths and enabled-service artifacts on images with and without X. Use guest snapshots for missing or incomplete reference data and verify that no planned action is executed after a fatal reference error. |
| Sandbox and paths | In the isolated guest, check that apply refuses a first-level candidate under `/` before touching a nested fixture. With the first-level candidate absent, verify removal of the intended nested fixture, preservation of protected paths and refusal of non-empty directories. |
| Accounts | Use disposable test identities in a fresh snapshot to verify protection of retained users' primary groups, handling of package fields and preservation configured by `usermgmt.conf`. Check actual postconditions and the summary. |
| Release | Generate the README on the target OpenBSD renderer. Build an archive on the guest, inspect its explicit file list, check `LICENSE` and script permissions, extract it and test installation into a disposable `DESTDIR`. When comparing checksums, use the same source, epoch, toolchain, and archive owner/group metadata. |

For each case record the invoked mode, exit status, stdout/stderr and relevant
state before and after. Compare read-only or preview state separately from
mutating cases. Stop any apply scenario if the preview includes unexpected
entries and inspect the reference data before proceeding.

## Performance baseline

Record wall time, CPU time and peak resident memory with OpenBSD
`/usr/bin/time -l` for the default report, `-a`, `-p` and `-n`. Use the
same guest snapshots and package databases across revisions. If a whole-run
difference warrants investigation, time inventory construction, traversal,
and plan sorting separately in a disposable instrumented build. Compare the
exit status and action set before attributing improvements to a change.
