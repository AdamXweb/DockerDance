# Contributing

Thanks for taking a look. Issues and pull requests are welcome — there are
[issue templates](.github/ISSUE_TEMPLATE) for bugs, feature requests and general
feedback. The output of `./manage.sh doctor` makes a bug report much easier to
act on.

## What you need

- A POSIX shell. `manage.sh` is plain POSIX `sh`, not bash — please keep it that
  way; CI syntax-checks it with `dash`.
- [ShellCheck](https://www.shellcheck.net) for linting.
- `bzip2`, because backup archives are `.tar.bz2` and the round-trip tests need
  it.
- [`just`](https://github.com/casey/just) is optional; the
  [`justfile`](justfile) is a shortcut for the commands below.

No docker daemon is needed to run the tests — the harness uses the stub in
[`tests/stub/docker`](tests/stub/docker).

## Tests and linting

```
sh tests/run-tests.sh        # or: just test
sh tests/run-tests.sh -v     # also show each case's captured output
```

Each case builds a fresh sandbox of fake app folders, runs `manage.sh` against
it, and asserts on the exit status, the output, and the exact docker actions the
stub recorded.

Linting, the same targets CI uses:

```
shellcheck docker_volumes/manage.sh contrib/dockerdance-completion.bash tests/run-tests.sh tests/stub/docker
sh -n docker_volumes/manage.sh
# or: just lint
```

## CI

[`.github/workflows/shellcheck.yml`](.github/workflows/shellcheck.yml) runs on
pushes to `main` and on pull requests. It runs ShellCheck, the `dash` syntax
check and the test harness, and then checks that the `VERSION` set in
`manage.sh` has a matching `## [VERSION]` section in
[`CHANGELOG.md`](CHANGELOG.md) — that drift would otherwise only surface at tag
time, because the release workflow takes its notes from that section.

## Releasing

Add the CHANGELOG section, set `VERSION` in `docker_volumes/manage.sh` to match,
then push the tag:

```
git tag -a v0.5.0 -m v0.5.0 && git push origin v0.5.0
# or: just release 0.5.0
```

[`.github/workflows/release.yml`](.github/workflows/release.yml) attaches
`manage.sh` and its `.sha256` to that version's release. Writing the release in
the GitHub UI first also works — the workflow adds the files and leaves your
title and notes alone. Re-running is safe: assets are replaced, notes are never
rewritten.
