# Command reference

Run everything from inside your `docker_volumes` folder. `./manage.sh help` prints
the same list from the script itself, and `./manage.sh --version` prints the
script version.

Every command runs against all the apps in the `Apps` setting by default. To
target specific apps, add their folder names after the command, e.g.
`./manage.sh restart linkace` or `./manage.sh update linkace uptime-kuma`.
Apps are processed in the order `Apps` lists them; with `Apps="auto"` the
discovered folders run alphabetically.

## Options

These work with any command, before or after it:

- `--dry-run` — print exactly what would happen (which apps get pulled, stopped,
  backed up, started) without touching anything.
- `-y` / `--yes` — skip confirmation prompts, so `update` and `restore` can run
  unattended.
- `--stopped=keep|start|skip` — what `update` and `backup` do with apps that are
  already stopped. See [Keeping apps as you found them](#keeping-apps-as-you-found-them).
- `--prune` — remove dangling images after an update.
- `--backup-first` — archive each app before it moves to its new image (`update`).
- `--no-color` — turn off coloured output, as does setting `NO_COLOR`.

## Interactive menu

`./manage.sh`

Running the script with no arguments on a terminal opens a menu: pick a command,
then pick the app(s).

- **With [fzf](https://github.com/junegunn/fzf)** the menu is navigable with the
  arrow keys and type-to-filter. On the command list, `Enter` selects and `Esc`
  quits. On the app list, `TAB` multi-selects (with a live container-status
  preview pane), `Enter` confirms and `Esc` goes back to the command list.
- **Without fzf** a numbered menu is shown — type the number *or* the command
  name; on the app list enter a space/comma-separated list like `1 3` (or `0`
  for all), and `b` goes back.

No extra dependencies are required either way. Cron and piped usage are
unaffected: without a terminal the script prints usage instead of waiting for
input. Colours and spinners appear only on capable terminals and respect
[`NO_COLOR`](https://no-color.org). Only one state-changing run is allowed at a
time per folder — a lock directory keeps a cron backup from overlapping a manual
update, and a lock whose recorded process has exited is cleared automatically.

## start

`./manage.sh start`

Starts each app with `docker compose up -d`, then waits for it to come up (see
[Health](#health)).

## stop

`./manage.sh stop`

Stops each app gracefully with `docker compose stop`, giving databases time to
finish writing before shutdown. `STOP_TIMEOUT` (default 30s) is how long docker
waits before forcing it.

## restart

`./manage.sh restart`

Stops the apps, then starts them again.

## update

`./manage.sh update`

Pulls the latest images for all target apps in parallel (keeping
`PARALLEL_PULLS` downloads in flight), then stops and recreates each container
on the new image — so downtime is the stop/start window, not the download. The
pull phase names the apps it is downloading and counts them off, printing a line
per app as it lands.

Apps that are already stopped stay stopped; their image is still pulled, so they
come up current next time (see [Keeping apps as you found them](#keeping-apps-as-you-found-them)).
On a terminal it asks for confirmation first (skip with `-y`). An app whose pull
fails is left running on its current image and reported. Add `--backup-first` to
archive every app on the way through — that flow already restarts each app on
its freshly pulled image — and `--prune` to reclaim the old images afterwards.

## backup

`./manage.sh backup`

An all-in-one, per app: it pulls the latest images while the app is still
running, stops it gracefully, tars its folder into the `backup` folder, then
starts it back up on the new images. Archives are written `chmod 600` (they
contain your `.env` secrets) and store paths relative to `docker_volumes`, so a
`restore` is portable. A second backup on the same day gets a `_HHMMSS` suffix
rather than overwriting the first. Set `BACKUP_KEEP=N` to keep only the newest N
archives per app. A backup whose archive fails still starts the app back up
rather than leaving it stopped.

## restore

```
./manage.sh restore linkace
./manage.sh restore linkace 2026-08-01
```

Puts a backup archive for the app back in place — the newest by default, or the
one for the date you name: stops the app, moves the current folder aside to
`<app>.pre-restore.<timestamp>` (nothing is deleted), extracts the archive, and
starts the app again. Asks for confirmation, which needs a terminal or `-y`.
Older v0.1.0-era archives (absolute paths) are detected and restored too.

Archives are treated as untrusted: extraction happens in an isolated staging
area, any path-traversal (`..`) member is refused, and only the app's own folder
is promoted, so a tampered archive cannot write elsewhere on disk.

## status

`./manage.sh status`

A dashboard with one line per app: a coloured running/stopped dot, container
state (`up` / `N/M up` / `stopped`), the image in use, and health. Read-only.

## Health

After starting an app — via `start`, `restart`, `update`, `backup` or `restore` —
the script waits for its containers to come up rather than assuming they will.
Containers with a healthcheck must report `healthy`; those without just need to
be running. The result line becomes e.g. `linkace started, healthy`, or a
warning if a container is unhealthy or still starting after `HEALTH_TIMEOUT`
(default 60s; set `0` to skip the wait). The wait is best-effort and never fails
the run.

## Keeping apps as you found them

`update` and `backup` check which apps are actually running before they touch
anything, and put each one back the way they found it. An app you deliberately
stopped is **not** started as a side effect of updating — its new image is still
pulled, so it comes up current the next time you start it.

You see the split up front, and on a terminal a single prompt settles the rest:

```
  ● 5 running: authelia, gitea, immich, jellyfin, nextcloud
  ○ 3 stopped: audiobookshelf, larapaper, vaultwarden
Update 5 running app(s). The other 3 are stopped - what should happen to them?
  1) leave them stopped, but pull so they're current next start (recommended)
  2) start them too, so everything ends up running
  3) skip them entirely - no pull, no changes
  n) cancel
Choose [1]:
```

For cron and scripts, `--stopped=keep|start|skip` (or `STOPPED_POLICY` in
`manage.conf`) picks the same three answers without prompting — as does `-y`,
which takes the default. `--stopped=start` is the older behaviour, where
everything ends up running.

`backup` follows the same rule: a stopped app is archived where it lies, without
being started to do it. `stop`, `start` and `restart` are unaffected — those are
explicit instructions rather than a sweep, so `restart` on a stopped app still
starts it.

## When something fails

One bad app does not end the run. If an app's containers will not start, its
folder is missing, or its archive cannot be written, that app is reported and the
run carries on through the rest. The failure is printed where it happens — the
command's own output, plus a `[hint]` line when the cause is a recognisable one
(an image with no build for your architecture, a bind-mount path docker cannot
reach, a port already taken, an image or tag that does not exist, a full disk, a
*folder* named `compose.yaml` shadowing the real compose file).

Every run then closes with a per-app table and a tally:

```
  ● authelia                 updated         4s
  ○ audiobookshelf           failed         12s
  ○ larapaper                skipped         0s
[warn] - Updated 27 of 30 apps in 3m 4s - 1 failed, 2 skipped
  failed:  audiobookshelf, vaultwarden
  skipped: larapaper, pinchflat-X
```

`skipped` means the app was left untouched (its image pull failed, so it stays
on the image it has); `failed` means the command was attempted and did not work;
`unhealthy` means the app started on its new image but never reported healthy
within `HEALTH_TIMEOUT`. The script exits non-zero when any of those buckets is
non-empty, so a cron job or wrapper can tell without parsing the output.

## Smaller commands

`./manage.sh logs` — recent logs for each app. When a single app is targeted
(e.g. `./manage.sh logs linkace`) the log is followed live with `-f`; Ctrl-C
stops.

`./manage.sh version` — the image versions each app is using
(`docker compose images`).

`./manage.sh running` — the running containers (`docker ps`).

`./manage.sh prune` — remove dangling images left behind by updates.

`./manage.sh doctor` — a read-only environment check: docker daemon
reachability, the compose flavour in use, whether `curl`/`wget`/`fzf` are
present, the package manager `system-update` would use, `tar` safety, whether
`DOCKER_VOLUMES` is writable, `manage.conf`, a stale lock, the effective
settings and the discovered app list. Handy for first-run setup and bug reports.

`./manage.sh system-update` — updates the host OS packages with whatever package
manager the system has: `apt-get` (Debian/Ubuntu), `dnf` (Fedora/RHEL), `yum`,
`pacman` (Arch), `zypper` (openSUSE), `apk` (Alpine) or `brew` (macOS), detected
in that order. Distro managers need root and it tells you to `sudo`; Homebrew
refuses root and must run as your normal user. `./manage.sh apt` still works as
an alias.

`./manage.sh update-self` — updates the script itself to the latest
[GitHub release](https://github.com/AdamXweb/DockerDance/releases): downloads
`manage.sh` at the release tag, syntax-checks it, verifies the published
`manage.sh.sha256` when the release has one (v0.4.0 onwards) and the host can
hash, carries your `Apps`/`USERNAME` settings over, and swaps it in place. Use
`manage.conf` for configuration and there is nothing to carry over.
