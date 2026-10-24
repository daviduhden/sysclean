---
name: sysclean-accounts
description: Use when changing or auditing sysclean user and group detection, expected account data, userdel, groupdel, usermod, account name validation, uid or gid mismatch handling, or account-related apply behavior.
---

# sysclean-accounts

## When to use

Use this skill for:

* `walk_users`, `walk_groups`, `add_expected_users`;
* `NewUser`/`NewGroup` PLIST walkers;
* `@user`/`@group` ignore entries;
* `remove_user`, `remove_group`, `modify_user`, `user_mod_args`,
  `valid_account_name`, `valid_usermod_args`,
  `check_removable_user`, `check_removable_group`;
* uid/gid mismatch reports or `usermod` recommendations;
* account ordering or partial-failure behavior.

## When not to use

Do not use this skill for:

* package/library inventory outside account metadata (use
  `sysclean-packages-libraries`);
* generic path removal (use `sysclean-apply-mode`);
* sandbox details (use `sysclean-sandbox`);
* ignore-file syntax outside `@user`/`@group` (use
  `sysclean-ignore-rules`).

## Related files and components

* `sysclean.pl`: `add_expected_users`, `walk_users`, `walk_groups`,
  `queue_user`, `queue_group`, `queue_user_mod`, `user_mod_args`,
  `valid_account_name`, `valid_usermod_args`, `check_removable_user`,
  `check_removable_group`, `remove_user`, `remove_group`, `modify_user`.
* `OpenBSD::PackingElement::NewUser`, `NewGroup`,
  `pkg_account_value`.
* `/var/sysmerge/etc.tgz` (`./etc/master.passwd`, `./etc/group`).
* `AUDIT.md`, `sysclean.8`, `README.md`.

## Model and invariants

* Only uid/gid below 1000 are considered system accounts.
* Base reference users/groups come from `/var/sysmerge/etc.tgz`; package
  reference users/groups come from `@newuser`/`@newgroup`.
* Expected user keys are stored in two forms:
  `name:uid:group:class:home:shell` and `name:uid`.  Group keys are
  `name:gid`.
* `{user_fields}` records `uid`, `gid`, group, class, home and shell.
  `{group_fields}` records the expected gid by name.
* A **modified user** has a matching `name:uid` but a different group,
  login class, home or shell.  Apply mode restores those fields with
  `usermod(8)` using `-g`, `-L`, `-d`, `-s`.
* An **obsolete user/group** has no matching expected key.
* A name that exists in the reference with a different uid/gid is **not**
  obsolete.  It is reported but not removed or rewritten.  This prevents
  deleting a new account that reused an old name.
* `@user`/`@group` entries protect by full key and by name, so a field change
  does not silently defeat the ignore.
* `userdel` is called without `-r`; home directories are preserved.
* `usermod -d` changes the recorded home path but does not move files.

Hard rules:

* Validate names with `\A[A-Za-z0-9_][A-Za-z0-9._-]*\z`; this rejects a
  leading `-` and option injection.
* Pass arguments as a list to `system`; never use a shell string.
* Validate `usermod` option/value pairs: only `-g`, `-L`, `-d`, `-s`;
  reject control characters and values starting with `-`; reject empty
  `-g`/`-d`.
* Re-read the account immediately before the helper runs.  Refuse if it no
  longer exists, if its uid/gid changed from the queued value, if it is now
  expected, or if it is now ignored.
* Do not modify `/etc/master.passwd`, `/etc/group` or the account databases
  for testing.  Do not test on real host accounts.

## Analysis procedure

1. Determine whether the account is in the base reference, package reference,
   both, or neither.  Check `/var/sysmerge/etc.tgz` members and package
   `@newuser`/`@newgroup`.
2. Strip a leading `!` from package account fields before comparing; `!`
   marks a value that must not be changed.
3. Build the full and `name:uid`/`name:gid` keys exactly as the code does.
4. Check ignore entries by full key and by name.
5. Check modified-user fields.  Do not treat a missing field as a difference.
6. Check uid/gid mismatch before the obsolete branch.
7. In apply mode, trace the action's uid/gid into the helper and verify the
   revalidation in `check_removable_user`/`check_removable_group`.
8. Check ordering: paths, users, groups, then user modifications.  A group
   deletion after user deletion is intentional.
9. Check that a failed helper increments the failure counter and that the
   run exits 1.

## Modification procedure

1. Preserve the two-key expected-user model and the name-based ignore
   protection.
2. Do not add a deletion path for a name that exists in the reference with a
   different uid/gid.  Report it instead.
3. Keep `pkg_account_value` stripping of `!` markers.
4. Add any new helper option to `valid_usermod_args` and to the allowlist.
5. Keep `userdel` without `-r`.
6. Revalidate immediately before every helper call.
7. Add or update a fixture/stub test.  Never invoke real `userdel`,
   `groupdel` or `usermod` in `make regress`.
8. Update this skill and the manual if account behavior changes.

## Safe testing

* Unit tests may construct fake `{users}`, `{groups}`, `{user_fields}` and
  `{group_fields}` and call validation functions.
* Tests for deletion/modification belong in a disposable VM with fake
  account databases or fixtures.
* Do not run `sysclean -x` on the host.
* Do not create, modify or delete real accounts to reproduce a bug.
* Do not assume `PKG_DBDIR` redirects `/etc/master.passwd` or helper paths.

## Checks

* `perl -c sysclean.pl`
* `make regress`
* static review of every `system()` call and every option/value pair
* `git diff --check`
* VM/fixture test for account changes

## References

* `sysclean.pl`: account functions listed above.
* `AUDIT.md`: account invariants, helper sandbox limitations.
* `sysclean.8`/`README.md`: `-x`, account behavior, CAVEATS.
* OpenBSD manuals: `userdel(8)`, `groupdel(8)`, `usermod(8)`,
  `passwd(5)`, `group(5)`, `useradd(8)`.
