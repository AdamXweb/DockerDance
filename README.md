<p align="center">
    <img width="120" src="https://user-images.githubusercontent.com/6800453/178521052-0455c0d3-cf6c-4cea-9633-db0b7853c57b.svg?raw=true">
</p>

<h1 align="center">DockerDance</h1>

<p align="center">A single POSIX shell script that bulk-manages the docker compose apps in your <code>docker_volumes</code> folder — start, stop, update, back up and restore, one folder at a time.</p>

<p align="center">
    <img width="500" src="https://user-images.githubusercontent.com/6800453/178521272-3639e416-8915-4f21-9d7e-4f484852c839.gif?raw=true">
</p>

[![Project status](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FAdamXweb%2F.github%2Fmain%2Fbadges%2FDockerDance.json)](https://github.com/AdamXweb/.github/blob/main/STATUS.md#dockerdance)
[![Release](https://img.shields.io/github/v/release/AdamXweb/DockerDance?sort=semver)](https://github.com/AdamXweb/DockerDance/releases)
[![Lint](https://github.com/AdamXweb/DockerDance/actions/workflows/shellcheck.yml/badge.svg?branch=main)](https://github.com/AdamXweb/DockerDance/actions/workflows/shellcheck.yml)
[![Licence](https://img.shields.io/github/license/AdamXweb/DockerDance)](LICENSE)

<!-- disclosure:start -->
> [!WARNING]
> **Pre-1.0 — no stable release yet.** Anything can change in any release, including a patch: APIs, CLI flags, config keys, file formats, and data already on disk. Keep your own backups.
> **Project status.** The badge above is generated from [my status list](https://github.com/AdamXweb/.github/blob/main/STATUS.md), which says what I promise for this project and every other one.
<!-- disclosure:end -->

---

I self-host a growing list of apps, each in its own folder with its own compose
file, and wanted one command to sweep across all of them. The tools I found were
heavier than the job needed, so this is the lightweight version: one file,
`manage.sh`, that drops into your `docker_volumes` folder and works out the rest.
It is plain POSIX `sh` with no dependencies beyond docker itself;
[fzf](https://github.com/junegunn/fzf) is used for the interactive picker if you
have it, and skipped if you do not.

## What it does

- **Sweeps every app, or the ones you name.** `Apps="auto"` (the default)
  discovers every folder containing a compose file, so there is no list to keep
  up to date. `./manage.sh update linkace uptime-kuma` targets specific ones.
- **Leaves deliberately-stopped apps stopped.** `update` and `backup` check what
  is actually running first and put each app back the way they found it. A
  stopped app still gets its new image pulled, so it comes up current next time
  you start it. `--stopped=keep|start|skip` (or `STOPPED_POLICY`) makes that
  choice explicit for cron.
- **Updates with the downtime you would expect.** Images are pulled in parallel
  while the apps keep running, and only then is each container stopped and
  recreated — so downtime is the stop/start window, not the download.
- **Backs up and restores whole app folders.** `backup` pulls, stops, tars the
  folder into `backup/`, and starts the app again. Archives are `chmod 600`
  because they contain your `.env`, and hold relative paths so they are
  portable. `restore` moves your current folder aside instead of deleting it,
  and refuses archives containing path-traversal members.
- **Carries on when one app breaks.** A failing app is reported, often with a
  `[hint]` at the likely cause, and the run continues. Each run ends with a
  per-app table and a tally, and exits non-zero if anything failed, was skipped
  or came up unhealthy.
- **Waits for health.** After starting an app, containers with a healthcheck
  must report `healthy` and those without must be running, up to
  `HEALTH_TIMEOUT`.
- **Runs fine unattended.** No terminal needed, no colour when it is not wanted,
  a lock so a cron backup cannot overlap a manual update, and an optional
  Slack/Discord webhook when a run finishes or fails.

Full command reference: [docs/commands.md](docs/commands.md). Settings, folder
layout and cron: [docs/configuration.md](docs/configuration.md).

## Get it

DockerDance is the single `manage.sh` file. Download it **into your
`docker_volumes` folder** and make it executable. It is worth reading a script
from a project you do not yet know before you run it, so fetch it, read it, then
run it:

```sh
# run from inside your docker_volumes folder
curl -fsSL https://raw.githubusercontent.com/AdamXweb/DockerDance/main/docker_volumes/manage.sh -o manage.sh && chmod +x manage.sh
```

```sh
wget -O manage.sh https://raw.githubusercontent.com/AdamXweb/DockerDance/main/docker_volumes/manage.sh && chmod +x manage.sh
```

Then `./manage.sh` for the interactive menu, or `./manage.sh help` for the
command list. `./manage.sh doctor` checks your environment without changing
anything.

You can also pin a version [from the releases](https://github.com/AdamXweb/DockerDance/releases) —
releases from v0.4.0 carry `manage.sh` and a `manage.sh.sha256` to check it
against — and `./manage.sh update-self` moves you to the latest release later.
Prefer git? Cloning this repo into your user folder
(`git clone https://github.com/AdamXweb/DockerDance.git .`) gives you the whole
`docker_volumes` layout, including an `example` app to try a first `start`
against.

You need a Unix-like system (macOS, Linux, BSD; on Windows, WSL2), docker with
either `docker compose` or `docker-compose` — the script detects which — and each
service in its own folder under `docker_volumes` with its own compose file. If
docker is missing, the script points you at the
[official installer](https://docs.docker.com/engine/install/). Settings go in a
`manage.conf` next to the script, where they survive `update-self`; see
[docker_volumes/manage.conf.example](docker_volumes/manage.conf.example).

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md)
for the test harness, linting and the release process, and
[docs/troubleshooting.md](docs/troubleshooting.md) when something misbehaves.
[CHANGELOG.md](CHANGELOG.md) records what has landed.

## Licence

Released under the MIT licence. See [LICENSE](LICENSE).
