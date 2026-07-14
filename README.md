<p align="center">
    <img width="120" src="https://user-images.githubusercontent.com/6800453/178521052-0455c0d3-cf6c-4cea-9633-db0b7853c57b.svg?raw=true">
    <h1 align="center">Docker Dance</h1>
</p>
<p align="center">
    <img width="500" src="https://user-images.githubusercontent.com/6800453/178521272-3639e416-8915-4f21-9d7e-4f484852c839.gif?raw=true">
</p>



My Docker management scripts and structures from a homelab *enthusiast*.
This script allows you to **bulk manage** services that have been setup by `docker compose` in folders.


## What this does
I wanted a script to help me manage the growing list of apps i've been self-hosting.
There are tools out there that can help with this, however I was unable to find any that were lightweight.
This provides an easier way to update, restart and backup apps/services.

## Getting started

### Prerequisites
- A Unix-like operating system: macOS, Linux, BSD. On Windows: WSL2 is preferred, but cygwin or msys also mostly work.
- Docker, either with old compose (`docker-compose`) or the updated compose plugin (`docker compose`) — the script detects which you have. If Docker isn't installed, running any command points you to the [official installer](https://docs.docker.com/engine/install/) and can fetch and run Docker's `get.docker.com` script for you (after you confirm)
- Each service contained in a folder within a `docker_volumes` folder, with its own compose file (`docker-compose.yml`/`.yaml` or `compose.yml`/`.yaml`). The script finds these folders for you (see `Apps="auto"` below)
- Optional: [fzf](https://github.com/junegunn/fzf) for a fuzzy app-picker in the interactive menu — the menu works without it

### Basic Usage
The folders have been setup for use on a new server to make use of the script's structure.
If you are starting on a new server, you can clone the contents of this repo directly into your user folder with 
`git clone https://github.com/AdamXweb/DockerDance.git .`

### Installing the script
DockerDance is just the single `manage.sh` file. Download it **into your `docker_volumes` folder** and make it executable — it's a good idea to inspect a script from a project you don't yet know first, so grab it, read through it, then run it:

| Method    | Command (run from inside your `docker_volumes` folder)                                            |
| :-------- | :------------------------------------------------------------------------------------------------ |
| **curl**  | `curl -fsSL https://raw.githubusercontent.com/AdamXweb/DockerDance/main/docker_volumes/manage.sh -o manage.sh && chmod +x manage.sh` |
| **wget**  | `wget -O manage.sh https://raw.githubusercontent.com/AdamXweb/DockerDance/main/docker_volumes/manage.sh && chmod +x manage.sh` |

Then run `./manage.sh` for the interactive menu, or `./manage.sh help` for the command list. You can also pin a specific version [from the releases](https://github.com/AdamXweb/DockerDance/releases); `./manage.sh update-self` updates it to the latest release later. (Prefer git? `git clone https://github.com/AdamXweb/DockerDance.git .` into your user folder gives you the whole `docker_volumes` layout.)


#### Customise variables
`Apps="auto"` (the default) - the script discovers every folder within `docker_volumes` that contains a compose file (`docker-compose.yml`/`.yaml` or `compose.yml`/`.yaml`, or one folder deeper) and manages all of them, in alphabetical order. The `backup` folder and `*.pre-restore.*` folders are skipped. Just drop `manage.sh` into your `docker_volumes` folder and it works.
To pin the set or the order instead, list the folders explicitly e.g. `Apps="linkace .n8n dashy"`
`USERNAME="systemadmin"` - The user folder that you store the `docker_volumes` in. If you're stuck, type `pwd` to find the path you're in, or `whoami` to get the user name.
`DOCKER_VOLUMES` defaults to `/home/$USERNAME/docker_volumes/` and can be overwritten in the script, or from the environment without editing anything — handy for MacOS: `DOCKER_VOLUMES="/Users/UserName/docker_volumes/" ./manage.sh start`
`STOP_TIMEOUT` (default `30`) - seconds to wait for containers to shut down gracefully before docker gives up. Raise it for databases that take a while to flush.
`HEALTH_TIMEOUT` (default `60`) - after starting an app, seconds to wait for its containers to become healthy (or just running, if they have no healthcheck) before moving on. Set `0` to skip the wait entirely.
`PARALLEL_PULLS` (default `3`) - how many image pulls `update`/`backup` run at once. Set `1` for the old one-at-a-time behaviour.
`BACKUP_KEEP` (unset by default) - when set to a number, only that many most-recent backup archives are kept per app; older ones are pruned after each backup.

`NOTIFY_WEBHOOK` (unset by default) - a webhook URL (Slack and Discord formats both work) that gets a message when an update, backup or restore completes or fails. Handy for cron runs. See issue [#3](https://github.com/AdamXweb/DockerDance/issues/3).

Instead of editing the script, all of the above can live in a `manage.conf` file next to `manage.sh` (plain shell assignments, e.g. `Apps="linkace n8n"`). Settings there survive `update-self`.


## Commands
There are a few commands you can use with the script.
Side note, the script executes commands in the order they are listed as e.g. `Apps="1 2 3"` iterates in that order (with `Apps="auto"` the discovered folders run alphabetically)

First, make sure you are in the `docker_volumes` folder, and execute any of the commands below.

Every command runs against all the apps in the `Apps` variable by default. To target one or more specific apps, add their folder names after the command, e.g. `./manage.sh restart linkace` or `./manage.sh update linkace uptime-kuma`.

Two options work with any command (before or after it):
- `--dry-run` prints exactly what would happen — which apps get pulled, stopped, backed up, started — without touching anything.
- `-y` / `--yes` skips confirmation prompts (so `update` and `restore` can run unattended).
- `--no-color` turns off coloured output (as does setting `NO_COLOR`).

### Interactive menu
`./manage.sh`

Running the script with no arguments on a terminal opens a menu: pick a command (including `status`, `doctor`, `system-update` and `update-self`), then pick the app(s).

- **With [fzf](https://github.com/junegunn/fzf)** the whole menu is navigable with the **arrow keys** and type-to-filter. On the command list, `Enter` selects and `Esc` quits. On the app list, `TAB` multi-selects (with a live container-status preview pane), `Enter` confirms and `Esc` goes back to the command list.
- **Without fzf** a numbered menu is shown — type the number *or* the command name; on the app list enter a space/comma-separated list like `1 3` (or `0` for all), and `b` goes back. (Arrow-key navigation needs fzf; a `brew install fzf` / `apt install fzf` .)

No extra dependencies are required either way. Cron and piped usage are unaffected: without a terminal the script prints usage instead of waiting for input.

Colours and spinners appear only on capable terminals and respect [`NO_COLOR`](https://no-color.org). Only one state-changing run is allowed at a time per folder (a lock protects a cron backup from overlapping a manual update). Tab-completion is available for bash, zsh and fish in [contrib/](contrib/).

### Stop
`./manage.sh stop`

Stops all the apps by navigating through each folder and stopping them gracefully with `docker compose stop`, giving databases time to finish writing before shutdown

### Start
`./manage.sh start`

Starts all the apps by navigating through each folder and starting with `docker compose up -d`

### Update
`./manage.sh update`
Pulls the latest images for all target apps **in parallel** (up to `PARALLEL_PULLS` at once), then stops and recreates each container on the new image — so downtime is just the stop/start window, not the download. On a terminal it asks for confirmation first (skip with `-y`); an app whose pull fails is left running on its current image and reported. After starting, it waits for each app to report healthy (see [Health](#health) below).

### Restart
`./manage.sh restart`
Stops all the apps, then starts them up again.

### Backup
`./manage.sh backup`
An all-in-one per app: it pulls the latest images **while the app is still running**, stops it gracefully, tars its folder into the `backup` folder, then starts it back up on the new images. Archives are written with `chmod 600` (they contain your `.env` secrets) and store paths relative to `docker_volumes`, so a `restore` is portable. A second backup gets a `_HHMMSS` suffix. Set `BACKUP_KEEP=N` to keep only the newest N archives per app.

### Restore
`./manage.sh restore linkace`

Puts the newest backup archive for the app back in place: stops the app, moves the current folder aside to `<app>.pre-restore.<timestamp>` (nothing is deleted), extracts the archive, and starts the app again. Asks for confirmation (needs a terminal, or pass `-y`). Older v0.1.0-era archives (absolute paths) are detected and restored too. Archives are treated as untrusted: extraction happens in an isolated staging area, any path-traversal (`..`) member is refused, and only the app's own folder is promoted — a tampered archive can't write elsewhere on disk.

### Status
`./manage.sh status`

A dashboard with one line per app: a coloured running/stopped dot, container state (`up` / `N/M up` / `stopped`), the image in use, and health. Read-only — a quick "is everything OK?" at a glance.

<a name="health"></a>
### Health
After starting an app (via `start`, `restart`, `update`, `backup` or `restore`), the script waits for its containers to come up rather than just assuming they will. Containers with a healthcheck must report `healthy`; those without just need to be running. The result line becomes e.g. `linkace started, healthy`, or a warning if a container is unhealthy or still starting after `HEALTH_TIMEOUT` (default 60s; set `0` to skip the wait). The wait is best-effort and never fails the run.

#### Minor commands
`./manage.sh version`
Display versions of images: `docker compose images`

`./manage.sh doctor`
A read-only environment check: docker daemon reachability, the compose flavour in use, whether `curl`/`wget`/`fzf` are present, the package manager `system-update` would use, `tar` safety, whether `DOCKER_VOLUMES` is writable, `manage.conf`, a stale lock, the effective settings and the discovered app list. Handy for first-run setup and bug reports.

`./manage.sh system-update`
Updates the host OS packages with whatever package manager the system has — `apt-get` (Debian/Ubuntu), `dnf` (Fedora/RHEL), `yum`, `pacman` (Arch), `zypper` (openSUSE), `apk` (Alpine) or `brew` (macOS) — detected in that order. Distro managers need root (it tells you to `sudo`); Homebrew refuses root and must run as your normal user. `./manage.sh apt` still works as an alias.

`./manage.sh logs`
Shows the recent logs for each app. When a single app is targeted (e.g. `./manage.sh logs linkace`) the log is followed live with `-f` — press Ctrl-C to stop.

`./manage.sh help`
Show usage and the full list of commands. `./manage.sh --version` prints the script version.

`./manage.sh update-self`
Updates the script itself to the latest [GitHub release](https://github.com/AdamXweb/DockerDance/releases): downloads `manage.sh` at the release tag, syntax-checks it, carries your `Apps`/`USERNAME` settings over, and swaps it in place. (Use `manage.conf` for configuration and there's nothing to carry over.)



## Environment
This script is meant to run on a Unix-like system as a user with privileges to modify the app files — i.e. root, or a user whose group can read the volume data — so that backing up database files created by root doesn't fail with a permission error.

> **A note on secrets and safety.** App folders usually contain a `.env` with credentials, so the backup archives do too — they're written `chmod 600` (owner-only), and the `backup` folder inherits the permissions of the root-owned `docker_volumes` tree. `restore` never deletes your current data: it moves it aside to `<app>.pre-restore.<timestamp>` and asks for confirmation before extracting. If you sync backups off-box (see below), treat that copy as sensitive too.

### Folder structure
The default path is set to `~/docker_volumes` (userhome/docker_volumes).
Each service/app has its own folder and `docker-compose.yml` to go with it.
For example: If i'm running [LinkAce](https://github.com/Kovah/LinkAce) I'd have the following folder structure:
I'd also have a volume mount to the folder `data` below. `./data:/app
```
userfolder
│
└───docker_volumes
    │   manage.sh
    │   caddy.json
    │
    └───linkace
    │   │   docker-compose.yml
    │   │   .env
    │   └───data
    │
    └───other_app
        └─── docker-compose.yml

```

### Backups
When a backup completes, the archive is placed in the `backup` folder named `<service><date>.tar.bz2`. The date is deliberately day-resolution so a daily/weekly/monthly cron run produces one archive per period. If you back up more than once in a day, the extra runs get a `_HHMMSS` suffix instead of overwriting the first. Set `BACKUP_KEEP=N` to prune automatically to the newest N archives per app after each run.

```
userfolder
│
└───docker_volumes
    │   manage.sh
    │   caddy.json
    │
    └───linkace
    │   │   docker-compose.yml
    │   │   .env
    │   └───data
    │
    └───backup
        └─── linkace2022-07-12.tar.bz2

```
I have another system that connects and executes an [rsync](https://download.samba.org/pub/rsync/rsync.1) to copy files to another location. This is outside the scope of the script however.


## Things learnt
### Backups
#### Troubleshooting
- If you'd like to see what's going on with your backups, you can change the `tar` command to `tar -cvjf` adding a v for verbose output to see what files it stops on
- Running as a local user prompted permission issues when trying to tar the files that were created with root. This led to an early exit of the script.
- Folder names identified under Apps can have a dot e.g `.n8n` at the front or special characters `uptime-kuma` as long as each entry is separated by a space e.g. `Apps=".n8n uptime-kuma linkace"`.
- If an app's compose file sits one folder deeper (e.g. `myapp/src/docker-compose.yml`), the script follows it automatically as long as there's only one such folder (issue [#6](https://github.com/AdamXweb/DockerDance/issues/6)).
- Non executable scripts may need permissions updated with `chmod +x ./docker_volumes/manage.sh` to ensure permissions are executable
- backups may fail if you run out of space / if this is run on a cron to a local folder.
- the backup folder is created automatically if it doesn't exist yet.

## Things to improve
- Ability to define the backup target as a remote server or path with more storage
- A `status` / dashboard view showing every app's state at a glance
- Health-aware start (wait until containers report healthy before moving on)

See the [CHANGELOG](CHANGELOG.md) for what's landed recently.

### Cron
The script gives plain, un-coloured output and needs no terminal when run non-interactively, so it drops straight into cron. For example, back up every discovered app nightly at 3am and log it:

`0 3 * * * cd /home/systemadmin/docker_volumes && ./manage.sh backup >> /var/log/dockerdance.log 2>&1`

Set `NOTIFY_WEBHOOK` (easiest in `manage.conf`) to get a Slack/Discord ping when a scheduled run finishes or fails. A lock stops a cron run from overlapping a manual one on the same folder, so you won't get two `stop`/`start` cycles fighting each other.

### Adding script as an alias
Depending on your system, you could use something like the below to add the script to your path to just type `appmanage` or whatever command you'd like to nickname it to.

`echo "alias appmanage='$HOME/docker_volumes/manage.sh'" >> ~/.bashrc`

### Tab completion
A bash completion is included in [contrib/dockerdance-completion.bash](contrib/dockerdance-completion.bash). Source it from your shell startup, pointing at wherever you put the file:

`echo "source /path/to/DockerDance/contrib/dockerdance-completion.bash" >> ~/.bashrc`

It completes the commands first, then app folder names.

### example folder
The repo ships an `example` folder with a tiny alpine compose file. Because the default `Apps="auto"` discovers any folder containing a compose file, a fresh clone treats `example` as an app — handy for a first `./manage.sh start` to confirm everything works (it runs detached with `-d`, so nothing prints; `docker compose up` in the folder shows the test message). Delete the folder once you've added your own apps. If you instead pin `Apps="example"` explicitly, the script refuses to run until you change it.

## License

Docker Dance is released under the MIT license.
