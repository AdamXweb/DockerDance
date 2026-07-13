# Changelog

All notable changes to DockerDance are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/). `./manage.sh update-self` updates to
the latest tagged release.

## [Unreleased]

The changes below are on the way to the next release. Until they're tagged,
`update-self` will not offer them.

### Added
- **Zero-config app discovery.** `Apps="auto"` (the new default) manages every
  folder that contains a compose file (`docker-compose.yml`/`.yaml` or
  `compose.yml`/`.yaml`, or one folder deeper), in alphabetical order. Drop
  `manage.sh` into a `docker_volumes` folder and it just works. The `backup`
  folder and `*.pre-restore.*` folders are skipped.
- **`restore` command** (issue #2). Puts the newest backup archive for an app
  back in place: stops the app, moves the current data aside to
  `<app>.pre-restore.<timestamp>` (nothing is deleted), extracts, and starts
  again. Asks for confirmation, rolls back if extraction fails, and reads both
  the new relative-path archives and pre-v0.2.0 absolute-path ones.
- **`system-update` command.** Detects the host package manager — apt-get, dnf,
  yum, pacman, zypper, apk or brew — and runs the right non-interactive update,
  with per-manager root handling. `apt` remains as an alias.
- **`update-self` command.** Updates the script to the latest GitHub release:
  downloads `manage.sh` at the release tag, syntax-checks it, carries your
  settings over, and swaps it in place.
- **Interactive menu** when run with no arguments on a terminal: pick a command,
  then an app (or all). Uses fzf with a live `compose ps` preview when available,
  otherwise a numbered menu with a running/stopped dot per app.
- **Per-app targeting** (issue #1): `./manage.sh restart linkace` acts on just
  the named app(s).
- **Nested compose folders** (issue #6): if an app's compose file sits one
  folder deeper, the script follows it automatically when unambiguous.
- **Webhook notifications** (issue #3) via `NOTIFY_WEBHOOK` on update/backup/
  restore completion or failure (Slack and Discord payloads).
- **Colour, spinners, progress counters and run timing** (issue #5), respecting
  `NO_COLOR` and falling back to plain output without a terminal.
- **Optional `manage.conf`** for all settings, so configuration survives
  `update-self`. See `docker_volumes/manage.conf.example`.
- **`STOP_TIMEOUT`** and **`BACKUP_KEEP`** settings, `--version` flag, a run lock
  to stop overlapping runs, and a bash completion in `contrib/`.
- Shellcheck + dash CI workflow.

### Changed
- `update` and `backup` now **pull images while the app is still running**, then
  stop and start — downtime shrinks to just the restart window.
- Stops use `docker compose stop -t $STOP_TIMEOUT` (default 30s) so a busy
  database isn't SIGKILLed at docker's 10s default.
- Backups are written `chmod 600` with paths relative to `docker_volumes`
  (portable restores); a second backup in the same day no longer overwrites the
  first.
- Multi-app runs end with a per-app summary table (app / action / seconds).

### Fixed
- **Graceful shutdown before backup.** `docker compose kill` (SIGKILL) is
  replaced with `docker compose stop` everywhere, so databases shut down cleanly
  before their volumes are archived — `kill` risked backing up corrupt state.
- The Docker "is it installed?" check actually runs now (it was unreachable
  under `set -e`), and a `docker info` daemon-reachability check was added.
- Removed a stray `exec "$@"` that ran leftover arguments as a command.
- POSIX/dash correctness: `==` → `=`, quoted path expansions, backticks →
  `$(...)`; the `#!/bin/sh` shebang is now honest under dash.
- The backup target folder is created automatically (`mkdir -p`).
- `logs` no longer blocks forever on the first app; it follows with `-f` only
  when a single app is targeted.
- README install URLs corrected, and the alias example no longer clobbers
  `~/.bashrc`.

## [0.1.0] - 2022-07-12
- Initial release: bulk `start` / `stop` / `restart` / `update` / `backup` of
  docker-compose apps laid out in per-app folders.

[Unreleased]: https://github.com/AdamXweb/DockerDance/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/AdamXweb/DockerDance/releases/tag/v0.1.0
