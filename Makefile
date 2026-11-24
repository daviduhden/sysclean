# bake-format off
#	$OpenBSD$
#
# This is a BSD makefile (bmake).  It relies on .if/.else/.endif and on
# .include <bsd.prog.mk>, which GNU-make tools such as mbake cannot parse.
# The "bake-format off" directive on the first line tells mbake to leave
# the file untouched so that both formatters and bmake stay happy.

MAN=	sysclean.8

SCRIPT=	sysclean.pl

BINDIR?=	/usr/local/sbin
MANDIR?=	/usr/local/man/man

realinstall:
	${INSTALL} ${INSTALL_COPY} -o ${BINOWN} -g ${BINGRP} -m ${BINMODE} \
		${.CURDIR}/${SCRIPT} ${DESTDIR}${BINDIR}/sysclean

# Generate into temporary files so a renderer failure leaves the README intact.
RENDER_README=	LC_ALL=C mandoc -I os=OpenBSD -T markdown sysclean.8 > "$$tmp/raw" && \
	sed -e 's/&nbsp;/ /g' -e 's/&lt;/</g' -e 's/&gt;/>/g' \
	    -e 's/\\\[/[/g' -e 's/[[:blank:]]*$$//' "$$tmp/raw" > "$$tmp/README.md"

README.md: sysclean.8 Makefile
	@set -e; tmp=$$(mktemp -d ./.sysclean-readme.XXXXXXXX); \
		trap 'rm -rf "$$tmp"' EXIT; trap 'exit 1' HUP INT TERM; \
		${RENDER_README}; \
		chmod 644 "$$tmp/README.md"; mv "$$tmp/README.md" "$@"

regress: run-regress-perl-syntax \
	run-regress-apply-unit \
	run-regress-man-lint \
	run-regress-man-readme \
	run-regress-man-date

# check perl syntax
run-regress-perl-syntax:
	@echo TEST: perl syntax
	@perl -c sysclean.pl

# check the apply-mode helpers; these tests use File::Temp only and never
# touch system files or accounts
run-regress-apply-unit:
	@echo TEST: apply mode helpers
	@perl regress/apply.t

# check man page
run-regress-man-lint:
	@echo TEST: man page lint
	@mandoc -T lint -W style sysclean.8

# ensure README.md and man page are in sync
run-regress-man-readme:
	@echo TEST: README.md sync
	@set -e; tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/sysclean-readme.XXXXXXXX"); \
		trap 'rm -rf "$$tmp"' EXIT; trap 'exit 1' HUP INT TERM; \
		${RENDER_README}; \
		diff -q README.md "$$tmp/README.md"

# Use the editorial revision date. Header-only commits need no date change.
run-regress-man-date:
	@echo TEST: man page date
	@LC_ALL=C perl -MTime::Piece -ne 'next unless /^\.Dd\b/; \
		die "invalid .Dd date\n" unless /^\.Dd ([A-Za-z]+ [1-9][0-9]?, [0-9]{4})$$/; \
		$$date = $$1; $$t = Time::Piece->strptime($$date, "%B %d, %Y"); \
		die "invalid .Dd date\n" unless $$t->strftime("%B ") . $$t->mday . \
		    $$t->strftime(", %Y") eq $$date; $$dates++; \
		END { die "expected one .Dd date\n" unless $$dates == 1 }' sysclean.8

.if !defined(VERSION)
release:
	@echo "error: please define VERSION"; false

.else
release: sysclean-${VERSION}.tar.gz

DISTRIBUTED_FILES = \
	AUDIT.md \
	LICENSE \
	Makefile \
	README.md \
	regress/apply.t \
	regress/stubs/OpenBSD/LibSpec.pm \
	regress/stubs/OpenBSD/PackageInfo.pm \
	regress/stubs/OpenBSD/PackingList.pm \
	regress/stubs/OpenBSD/Paths.pm \
	regress/stubs/OpenBSD/Pledge.pm \
	regress/stubs/OpenBSD/Unveil.pm \
	sysclean.ignore \
	${MAN} \
	${SCRIPT}

# Always snapshot the manifest from the checkout. In particular, do not
# remake the tracked README as a side effect of creating the archive.
.PHONY: sysclean-${VERSION}.tar.gz
sysclean-${VERSION}.tar.gz:
	@set -e; umask 022; tmp=$$(mktemp -d ./.sysclean-release.XXXXXXXX); \
		trap 'rm -rf "$$tmp"' EXIT; trap 'exit 1' HUP INT TERM; \
		stage="$$tmp/sysclean-${VERSION}"; \
		for file in ${DISTRIBUTED_FILES}; do \
			mkdir -p "$$stage/$$(dirname "$$file")"; \
			cp "$$file" "$$stage/$$file"; chmod 644 "$$stage/$$file"; \
		done; \
		chmod 755 "$$stage/${SCRIPT}"; \
		if [ -n "$${SOURCE_DATE_EPOCH:-}" ]; then \
			stamp=$$(date -u -r "$$SOURCE_DATE_EPOCH" '+%Y%m%d%H%M.%S'); \
			TZ=UTC find "$$stage" -exec touch -t "$$stamp" {} +; \
		fi; \
		(cd "$$tmp" && pax -wd -x ustar -f release.tar \
			"sysclean-${VERSION}" "sysclean-${VERSION}/regress" \
			"sysclean-${VERSION}/regress/stubs" "sysclean-${VERSION}/regress/stubs/OpenBSD" \
			${DISTRIBUTED_FILES:S,^,sysclean-${VERSION}/,}); \
		gzip -n -c "$$tmp/release.tar" > "$$tmp/release.tar.gz"; \
		mv "$$tmp/release.tar.gz" "$@"

.endif

.include <bsd.prog.mk>
