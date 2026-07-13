# Changelog

All notable changes to DockerDance are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/). `./manage.sh update-self` updates to
the latest tagged release.

## [0.3.0] - 2026-07-13

The first release since v0.1.0 - a substantial robustness, safety and UX
overhaul. `./manage.sh update-self` will offer this to anyone on v0.1.0.

### Added
- **Docker install offer.** When Docker isn't installed, commands now point to
  the official install docs and can fetch and run Docker's `get.docker.com`
  script for you after you confirm (interactive only, never in cron).
- **`status` dashboard.** One line per app - a coloured up/stopped dot,
  container state, image and health - built read-only from `compose ps -q`
  plus `docker inspect`.
- **`doctor` command.** Read-only environment/config check: docker daemon,
  compose flavour, curl/wget/fzf, the system-update package manager, tar
  safety, `DOCKER_VOLUMES` writability, `manage.conf`, stale lock, effective
  settings and discovered apps.
- **Health-aware start.** After `up -d`, `start`/`restart`/`update`/`backup`/
  `restore` wait for containers to become healthy (or just running, with no
  healthcheck) before reporting done. Tunable with `HEALTH_TIMEOUT` (0 skips).
- **Parallel image pulls.** `update` and `backup` pull all target apps'
  images at once, up to `PARALLEL_PULLS` (default 3); a failed pull leaves
  that app on its current image and is skipped rather than aborting the run.
- **`--dry-run`** previews any command without touching anything, **`-y`/`--yes`**
  skips confirmations (and lets `restore` run non-interactively), and **update**
  now confirms before recreating containers on a terminal. **`--no-color`** flag.
- **Interactive menu upgrades.** The command list is now fzf-driven when fzf
  is installed (arrow-key navigation, type-to-filter, Esc to quit/go back) and
  includes `system-update` and `update-self`; the numbered fallback also
  accepts a typed command name and a `b` to go back. Multi-app selection via
  fzf `TAB` or a space/comma list.
- **zsh and fish completions** alongside the bash one.
- **Zero-config app discovery.** `Apps="auto"` (the new default) manages every
  folder that contains a compose file (`docker-compose.yml`/`.yaml` or
  `compose.yml`/`.yaml`, or one folder deeper), in alphabetical order. Drop
  `manage.sh` into a `docker_volumes` folder and it just works. The `backup`
  folder and `*.pre-restore.*` folders are skipped.
- **`restore` command** (issue #2). Puts the newest backup archive for an app
  back in place: stops the app, moves the current data aside to
  `<app>.pre-restore.<timestamp>` (nothing is deleted), extracts, and starts
  again. Asks for confirmation, rolls back if extraction fails, and reads both
  the new relative-path archives and older v0.1.0-era absolute-path ones.
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

### Security
- **`restore` treats archives as untrusted.** Extraction happens in an
  isolated staging area (never `tar -C /`); members with `..` traversal or
  absolute paths are refused; legacy absolute-path archives are declined on
  busybox tar; and only the app's own folder is promoted into place. A
  tampered backup can no longer write elsewhere on disk.
- **Unpredictable temp file.** The step-output log is created with `mktemp`
  (owner-only, random name) instead of a predictable `/tmp` name, closing a
  symlink pre-creation angle when running as root.

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

[0.3.0]: https://github.com/AdamXweb/DockerDance/compare/v0.1.0...v0.3.0
[0.1.0]: https://github.com/AdamXweb/DockerDance/releases/tag/v0.1.0
