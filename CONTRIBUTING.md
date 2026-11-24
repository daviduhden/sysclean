# Contributing

All contributions are welcome, including those created or assisted by artificial intelligence (AI).

**The use of AI is explicitly permitted**, without any requirement to disclose its use.

All changes must be appropriately tested and verified before submission, regardless of whether they were produced manually or with AI assistance.

Contributors are responsible for ensuring that their changes work as intended and do not introduce regressions.

Use OpenBSD base make or BSD make (`bmake`) with the OpenBSD make includes.
The script and manual can be installed under a staging root with
`make install DESTDIR=/path/to/staging` after creating the destination
directories. The staging root is for installation only. A running sysclean
still inspects the host's filesystem, packages and accounts.

Use `make regress` on OpenBSD for syntax, isolated unit tests and manual
checks. See the [OpenBSD validation matrix](docs/openbsd-validation.md) for
portable checks, native integration tests and release acceptance checks.
