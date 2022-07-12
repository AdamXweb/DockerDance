# docker-management
My Docker management scripts and structures from a homelab *enthusiast*.
This script allows you to **bulk manage** services that have been setup by `docker compose` in folders.


## What this does
I wanted a script to help me manage the growing list of apps i've been self-hosting.
There are tools out there that can help with this, however I was unable to find any that were lightweight.
This provides an easier way to update, restart and backup apps/services.

## Getting started

### Prerequisites
- A Unix-like operating system: macOS, Linux, BSD. On Windows: WSL2 is preferred, but cygwin or msys also mostly work.
- Docker, either with old compose or updated compose plugin
- Each service contained in a folder within a `docker_volumes` folder with its own `docker-compose.yml`

### Basic Usage
The folders have been setup for use on a new server to make use of the script's structure.
If you are starting on a new server, you can clone the contents of this repo directly into your user folder with 
`git clone https://github.com/AdamXweb/docker-management.git .`

### Precautions
Please note that this script was designed to work in my environment. The output fit the needs that I face to bulk manage docker apps/services.
It's a good idea to inspect a script from projects you don't yet know. You can do
that by downloading the install script first, looking through it so everything looks normal,
then running it:

#### Downloading the script
Docker management can be used as the script itself by downloading with a method of your choice, either directly or [from the releases](https://github.com/AdamXweb/docker-management/releases)
| Method    | Command                                                                                           |
| :-------- | :------------------------------------------------------------------------------------------------ |
| **curl**  | `sh -c "$(curl -fsSL https://raw.githubusercontent.com/adamxweb/docker-management/master/docker_volumes/manage.sh)"` |
| **wget**  | `sh -c "$(wget -O- https://raw.githubusercontent.com/ohmyzsh/docker-management/master/docker_volumes/manage.sh)"`   |


#### Customise variables
`Apps="example"` - Change to the exact wording of each folder within `docker_volumes` e.g. `Apps="linkace .n8n dashy"`
`USERNAME="systemadmin"` - The user folder that you store the `docker_volumes` in. If you're stuck, type `pwd` to find the path you're in, or `whoami` to get the user name.
`DOCKER_VOLUMES='/home/'$USERNAME'/docker_volumes/'` can be overwritten with `/Users/UserName/docker_volumes/` for MacOS


## Commands
There are a few commands you can use with the script. Be warned, as at this stage its use is to manage multiple apps rather than a single one.
Side note, the script executes commands in the order they are listed as e.g. `Apps="1 2 3"` iterates in that order

First, make sure you are in the `docker_volumes` folder, and execute any of the commands below/

### Stop
`./manage.sh backup`

Stops all the apps by navigating through each folder and stopping the docker process

### Start
`./manage.sh backup`

Starts all the apps by navigating through each folder and starting with `docker compose up -d`

### Update
`./manage.sh backup`
Stops all the apps, pulls the latest version and recreates container

### Restart
`./manage.sh backup`
Stops all the apps, then starts them up again.

### Backup
`./manage.sh backup`
At the moment the script is limited to backing up files in each directory.
Its function acts as an all in one for my use; It stops the container, backs up, updates and starts.

### Restore 
- todo see issue #2

#### Minor commands
`./manage.sh version`
Display versions of images: `docker compose images
`
`./manage.sh apt`
Just `apt update && apt upgrade` & `apt-get update && apt-get upgrade`. Handy for those that don't want to mess with an alias.

`./manage.sh logs`
Docker logs.



## Environment
This script is to be used in a linux system as a user with priveleges to modify files. (i.e. root or if your user is part of a group - to mitigate issues backing up files such as databases.)

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
When backups above are completed, they are placed in a backup folder with the name of the service and the date appended on the end.
The date is designed without a timestamp to be run once a day/week/month. If time is critical, then the `tar` filename can be adjusted for your use.

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
- Non executable scripts may need permissions updated with `chmod +x ./docker_volumes/manage.sh` to ensure permissions are executable
- backups may fail if you run out of space / if this is run on a cron to a local folder.

## Things to improve
- Code could be refactored as there are multiple repeating elements
- Restoring
- More with backups to show processes uploading to external servers.
- Ability to define target as a remote server or path with more storage.

### Cron
TBC - useful to run on a schedule to update, backup etc.

### Adding script as an alias
Depending on your system, you could use something like the below to add the script to your path to just type `appmanage` or whatever command you'd like to nickname it to.

`echo "alias appmanage='home/systemadmin/docker_volumes/manage.sh" > ~/.bashrc`

### example folder
The example folder should be deleted once variables are configured.
When executing `./manage.sh start` nothing will show as it starts the process detached with `-d`.
The compose file pulls alpine to show a version if you run `docker compose up`. Helpful for troubleshooting.
There is a 'test' logic in the script to make sure you change the example variable under `Apps`

## License

docker management is released under the MIT license.