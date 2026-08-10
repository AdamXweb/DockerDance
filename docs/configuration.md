# Configuration and layout

## Where settings live

Every setting below can be edited at the top of `manage.sh`, exported in the
environment, or — preferably — put in a `manage.conf` file next to `manage.sh`.
`manage.conf` is sourced at startup, so it is plain shell (`VAR="value"`, one per
line, `#` starts a comment), and settings there survive `./manage.sh update-self`.

```
cp manage.conf.example manage.conf
```

[`docker_volumes/manage.conf.example`](../docker_volumes/manage.conf.example)
ships every option commented out with its default.

## Settings

`Apps` (default `auto`) — with `auto`, the script discovers every folder within
`docker_volumes` that contains a compose file (`docker-compose.yml`/`.yaml` or
`compose.yml`/`.yaml`, or one folder deeper) and manages all of them in
alphabetical order. The `backup` folder and `*.pre-restore.*` folders are
skipped. To pin the set and the order instead, list the folders explicitly, e.g.
`Apps="linkace .n8n dashy"`.

`USERNAME` (default `systemadmin`) — the user whose home holds `docker_volumes`.
It is only used to build the default `DOCKER_VOLUMES` path. If you are stuck,
`pwd` gives the path you are in and `whoami` the user name.

`DOCKER_VOLUMES` (default `/home/$USERNAME/docker_volumes/`) — absolute path to
the folder, trailing slash included. It can be set from the environment without
editing anything, which is handy on macOS:
`DOCKER_VOLUMES="/Users/UserName/docker_volumes/" ./manage.sh start`

`STOPPED_POLICY` (default `keep`) — what `update`/`backup` do with apps that are
already stopped: `keep` leaves them stopped with their new image ready, `start`
brings them up too, `skip` leaves them entirely alone. Same values as
`--stopped=`.

`STOP_TIMEOUT` (default `30`) — seconds to wait for containers to shut down
gracefully before docker gives up. Raise it for databases that take a while to
flush.

`HEALTH_TIMEOUT` (default `60`) — after starting an app, seconds to wait for its
containers to become healthy (or just running, if they have no healthcheck)
before moving on. Set `0` to skip the wait entirely.

`PARALLEL_PULLS` (default `3`) — how many image pulls `update`/`backup` keep in
flight at once; as each one finishes the next app starts straight away. Set `1`
for one-at-a-time pulls.

`BACKUP_KEEP` (unset by default) — when set to a number, only that many
most-recent backup archives are kept per app; older ones are pruned after each
backup.

`PRUNE_AFTER_UPDATE` (unset by default) — set `1` to remove dangling images
after every update, the same as passing `--prune`.

`NOTIFY_WEBHOOK` (unset by default) — a webhook URL that gets a message when an
update, backup or restore completes or fails. The payload carries both a Slack
`text` and a Discord `content` field, so an incoming-webhook URL from either
works as-is. Handy for cron runs. See issue
[#3](https://github.com/AdamXweb/DockerDance/issues/3).

## Folder structure

The default path is `~/docker_volumes`. Each service has its own folder with its
own compose file. Running [LinkAce](https://github.com/Kovah/LinkAce), for
example, with a volume mount to the `data` folder below:

```
userfolder
│
└───docker_volumes
    │   manage.sh
    │   manage.conf
    │
    └───linkace
    │   │   docker-compose.yml
    │   │   .env
    │   └───data
    │
    └───other_app
        └─── docker-compose.yml
```

Backup archives land in the `backup` folder, which is created if it does not
exist, named `<service>_<date>.tar.bz2`. The date is deliberately
day-resolution, so a daily/weekly/monthly cron run produces one archive per
period; more than one backup in a day gets a `_HHMMSS` suffix.

```
    └───backup
        └─── linkace_2026-08-01.tar.bz2
```

Copying archives off-box is outside the script's scope — I use a separate system
that [rsync](https://download.samba.org/pub/rsync/rsync.1)s them elsewhere.

## Permissions and secrets

The script is meant to run on a Unix-like system as a user with privileges to
modify the app files — root, or a user whose group can read the volume data — so
that backing up database files created by root does not fail with a permission
error.

App folders usually contain a `.env` with credentials, so the backup archives do
too. They are written `chmod 600` (owner-only), and the `backup` folder inherits
the permissions of the `docker_volumes` tree. `restore` never deletes your
current data: it moves it aside to `<app>.pre-restore.<timestamp>` and asks for
confirmation before extracting. If you sync backups off-box, treat that copy as
sensitive too.

## Cron

The script gives plain, un-coloured output and needs no terminal when run
non-interactively, so it drops straight into cron. To back up every discovered
app nightly at 3am and log it:

```
0 3 * * * cd /home/systemadmin/docker_volumes && ./manage.sh backup >> /var/log/dockerdance.log 2>&1
```

Set `NOTIFY_WEBHOOK` to get a Slack/Discord ping when a scheduled run finishes or
fails. The lock stops a cron run from overlapping a manual one on the same
folder, so you will not get two `stop`/`start` cycles fighting each other.

## An alias

To reach the script from anywhere as `appmanage`, or whatever you would rather
call it:

```
echo "alias appmanage='$HOME/docker_volumes/manage.sh'" >> ~/.bashrc
```

## Tab completion

Completions for bash, zsh and fish live in [contrib/](../contrib). They complete
the commands first, then app folder names. For bash:

```
echo "source /path/to/DockerDance/contrib/dockerdance-completion.bash" >> ~/.bashrc
```

## The example folder

The repo ships an [`example`](../docker_volumes/example) folder with a tiny
alpine compose file. Because the default `Apps="auto"` discovers any folder
containing a compose file, a fresh clone treats `example` as an app — handy for a
first `./manage.sh start` to confirm everything works. It runs detached with
`-d`, so nothing prints; `docker compose up` in the folder shows the test
message. Delete the folder once you have added your own apps. If you instead pin
`Apps="example"` explicitly, the script refuses to run until you change it.
