---
name: sysclean-perl-development
description: Use when modifying sysclean.pl, adding Perl packages or methods, handling references and errors, validating arguments, avoiding command injection, or running Perl static review and Perl::Critic.
---

# sysclean-perl-development

## When to use

Use this skill for:

* structural changes to `sysclean.pl`;
* new packages, subclasses or overridden methods;
* error handling, lexical variables, references or regular expressions;
* file descriptors, subprocesses, `system`, `open` or `exec`;
* Perl::Critic/static review;
* compatibility with the Perl shipped in OpenBSD base.

## When not to use

Do not use this skill for:

* semantics of inventory/apply/accounts (use the matching domain skill);
* build/release or documentation workflows;
* adding a new dependency without a demonstrated need.

## Related files and components

* `sysclean.pl` (single-file program, `use v5.36`).
* `Makefile`: `perl -c sysclean.pl`, `make regress`.
* `regress/apply.t`.
* OpenBSD base modules: `OpenBSD::PackageInfo`, `OpenBSD::PackingList`,
  `OpenBSD::LibSpec`, `OpenBSD::Pledge`, `OpenBSD::Unveil`,
  `OpenBSD::Paths`, `Archive::Tar`, `File::Find`, `File::Basename`,
  `Getopt::Std`.

## Language and structure

* Use `use v5.36` and syntax supported by the Perl in the target
  OpenBSD-current base.  Do not raise the minimum version without checking
  the base system.
* The file uses packages:
  * `sysclean` (base class and main scanner);
  * `sysclean::files`, `sysclean::allfiles`, `sysclean::packages`
    (subclasses via `use parent -norequire, qw(sysclean)`);
  * `OpenBSD::PackingElement::*` (PLIST walkers).
* Preserve the subclass/override structure.  `find_sub`, `plist_reader`,
  `add_expected_base_one`, `add_expected_rcctl` and `add_expected_users` are
  extension points; changing their contract affects multiple modes.
* `walk_sysclean` is dispatched through `OpenBSD::PackingElement`.  Keep the
  base no-op and add only the element-specific behavior.
* Do not introduce a new top-level package or a second script without a
  demonstrated need.

## Error handling and validation

* Use `$self->err($code, @msg)` for fatal errors; it exits with the requested
  code and prefixes `[ERROR]`.
* Use `$self->warning(@msg)` for recoverable problems that are reported.
* Do not silently ignore a failed reference read in apply mode.
* Check `defined` before using optional hash values or references.
* Use `//` only when an undefined value is semantically equivalent to the
  fallback; do not use it to hide malformed data.
* Validate external data at the boundary (account names, usermod arguments,
  paths, package fields).
* Use `\A...\z` for whole-string validation; `^...$` allows a trailing
  newline in some contexts.

## References and regular expressions

* Prefer lexical variables and explicit dereferencing.
* Do not use symbolic references.
* Do not use string `eval`; it is not needed and creates an injection surface.
* Wrap optional third-party calls in `eval { ... }` only to convert a
  failure into a controlled error; always inspect `$@` and the return value.
* Use `/o` only for a genuinely constant pattern.  Do not use `/o` on a
  pattern built from changing data.
* Escape data inserted into regular expressions with `quotemeta` or use
  literal comparisons.
* Avoid catastrophic backtracking.  Keep patterns anchored and simple.

## File descriptors and subprocesses

* Use lexical filehandles (`open my $fh, '<', $path`).
* Use the list form of `open` and `system`; never pass a shell string.
* Use `'-|'` for read pipes and check `close`/`$?` where the helper's result
  affects the inventory.
* Never interpolate a filename or account name into a command string.
* Do not use `exec`/`system`/backticks without a clear need, a fixed absolute
  or base-system executable, and a list argument.
* Preserve the existing `local $ENV{eo} = 'echo'` scoping for MAKEDEV.
* Close filehandles and restore the working directory when you change it.

## Dependencies and style

* Prefer modules already in OpenBSD base and package infrastructure.
* Do not add CPAN/runtime dependencies.
* Respect the existing perltidy/Perl::Critic conventions.  Do not reformat
  unrelated code or impose a new style.
* Keep comments factual; do not claim a security guarantee that is not
  implemented.
* Preserve license and copyright headers.
* Keep changes small and reviewable.

## Analysis procedure

1. Identify the package and method you are changing, and every caller
   (including subclass overrides and PLIST walkers).
2. Check whether the method is called in read-only and/or apply mode.
3. Trace data from its source (system file, package metadata, user input) to
   the sensitive operation.
4. Check every `system`, `open`, `eval`, regex, `defined` and `//` in the
   touched path.
5. Check failure handling and exit codes.
6. Check whether the change belongs in the base class or a subclass.
7. Review the diff for accidental formatting churn.

## Modification procedure

1. Make the smallest change that fixes the actual problem.
2. Add validation at the boundary rather than at the call site only.
3. Convert helper failures into controlled errors; do not ignore `$?`.
4. Add a unit test when the logic can be tested without system access.
5. Run static checks; do not run destructive modes.
6. Update the domain skill and `AGENTS.md` only if the contract changes.

## Checks

* `perl -c sysclean.pl`
* `perlcritic sysclean.pl` when available (do not make the project depend on
  it)
* `perltidy --check` only if the project already uses that workflow; do not
  reformat unrelated code
* `make regress`
* `git diff --check`
* manual grep for new `system`, `eval`, backticks and shell strings

## References

* `sysclean.pl`.
* `Makefile`.
* `AGENTS.md`: development conventions and security policy.
* OpenBSD manuals: `perl(1)`, `perlsub(1)`, `perlsec(1)`, `perlre(1)`,
  `open(2)`, `execve(2)`.
