# Troubleshooting

Start with `./manage.sh doctor` — it is read-only and reports the docker daemon,
the compose flavour in use, which of `curl`/`wget`/`fzf` are present, the
package manager `system-update` would use, `tar` safety, whether
`DOCKER_VOLUMES` is writable, whether a `manage.conf` was read, a stale lock,
the effective settings and the discovered app list. Its output is also the most
useful thing to paste into a bug report.

## Notes collected along the way

- Running as a local user caused permission errors when tarring files created by
  root, which ended the run early. Run as root, or as a user whose group can
  read the volume data.
- Folder names in `Apps` can start with a dot (`.n8n`) or contain special
  characters (`uptime-kuma`), as long as entries are separated by spaces:
  `Apps=".n8n uptime-kuma linkace"`.
- If an app's compose file sits one folder deeper (e.g.
  `myapp/src/docker-compose.yml`), the script follows it automatically as long
  as there is only one such folder (issue
  [#6](https://github.com/AdamXweb/DockerDance/issues/6)).
- A non-executable script needs `chmod +x ./docker_volumes/manage.sh`.
- Backups can fail if you run out of space — worth watching if a cron job writes
  archives to a local folder.
- The `backup` folder is created automatically if it is not there yet.
- To see what `tar` is doing during a backup, change the `tar` command in
  `manage.sh` to `tar -cvjf` — the `v` makes it print each file, so you can see
  where it stops.

## A lock is in the way

Only one state-changing run happens at a time per `docker_volumes` folder, using
a `.dockerdance.lock` directory. A lock whose recorded process has exited is
cleared automatically on the next run. A lock with no readable pid is not
cleared for you — remove it by hand once you are sure no run is active.

## Ideas not yet built

- Defining the backup target as a remote server or path with more storage.

See the [CHANGELOG](../CHANGELOG.md) for what has landed recently.
