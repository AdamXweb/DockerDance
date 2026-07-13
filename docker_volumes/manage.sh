#!/bin/sh
set -e

#Set these variables!
#Apps to backup (according to the folder name). Add each one with a space in between e.g. "vaultwarden uptime-kuma"
Apps="example"
USERNAME="systemadmin"

#Specific to Linux. Can change these if needed
#Set folder from root to avoid permission issues if running script as different user. (this would be /home/systemadmin/docker_volumes)
#Can also be overridden from the environment, e.g. for MacOS:
#  DOCKER_VOLUMES="/Users/yourname/docker_volumes/" ./manage.sh start
DOCKER_VOLUMES="${DOCKER_VOLUMES:-/home/$USERNAME/docker_volumes/}"
#Target is the folder within that the tar will save to if running a backup.
TARGET="${DOCKER_VOLUMES}backup/"


#Add styling (only when writing to a terminal that supports it)
bold="" normal=""
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ] && command -v tput >/dev/null 2>&1; then
  bold=$(tput bold) || bold=""
  normal=$(tput sgr0) || normal=""
fi

actioninfo() {
  echo "${bold}[action]:${normal} ⇒ $1"
}
ok() {
  echo "${bold}[ok]${normal} - $1"
}
success() {
  echo "${bold}[success]${normal} - $1"
}
error() {
  echo "${bold}[error]${normal} - $1" >&2
}

#Check Docker is installed, the daemon is reachable and compose is available
DOCKER_COMPOSE_COMMAND=""
require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    error "Please install Docker before proceeding."
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    error "Docker is installed but not reachable. Is the daemon running, and does your user have permission to use it?"
    exit 1
  fi
  #Check which docker compose command to use
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_COMMAND="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_COMMAND="docker-compose"
  else
    error "Neither the 'docker compose' plugin nor 'docker-compose' was found."
    exit 1
  fi
}

compose() {
  # shellcheck disable=SC2086 # intentionally unquoted: may be the two words 'docker compose'
  $DOCKER_COMPOSE_COMMAND "$@"
}

#Check to see if variables have been set above.
checkDefault() {
  #Apps passed on the command line don't need the variable configured
  if [ "$APPS_OVERRIDDEN" = "1" ]; then
    return 0
  fi
  if [ "$Apps" = "example" ]; then
    error "Please change the default 'Apps' variable to include your apps (or pass app names after the command)."
    exit 1
  fi
}

enter_app() {
  if [ ! -d "$1" ]; then
    error "No folder named '$1' here. Run this from the docker_volumes folder and check the Apps variable / arguments."
    exit 1
  fi
  cd "$1"
}

list_apps() {
  for app in "$@"; do
    echo "⇒ $app"
  done
  echo "---"
}

start_app() {
  echo "Starting ${bold}$1${normal}"
  enter_app "$1"
  compose up -d
  ok "$1 started"
  cd ..
}

stop_app() {
  echo "Stopping ${bold}$1${normal}"
  enter_app "$1"
  #stop (not kill) shuts containers down gracefully so databases can finish writing
  compose stop
  ok "$1 stopped"
  cd ..
}

restart_app() {
  echo "Restarting ${bold}$1${normal}"
  enter_app "$1"
  compose stop
  ok "$1 stopped"
  compose up -d
  ok "$1 restarted"
  cd ..
}

update_app() {
  echo "Stopping ${bold}$1${normal}"
  enter_app "$1"
  compose stop
  ok "$1 stopped"
  echo "Updating $1"
  compose pull
  ok "Images up to date. Starting all services."
  compose up -d
  ok "$1 updated and running"
  cd ..
}

backup_app() {
  echo "Stopping ${bold}$1${normal}"
  enter_app "$1"
  compose stop
  ok "$1 stopped"
  echo "Backing up $1"
  mkdir -p "$TARGET"
  tar -cjf "${TARGET}${1}$(date '+%Y-%m-%d').tar.bz2" "${DOCKER_VOLUMES}${1}"
  ok "$1 is backed up"
  echo "Updating $1"
  compose pull
  ok "Images up to date. Starting all services."
  compose up -d
  ok "$1 backed up, updated and running"
  cd ..
}

usage() {
  cat <<EOF
${bold}DockerDance${normal} - bulk manage docker compose apps

Usage: ./manage.sh <command> [app ...]

Commands:
  start     Start apps (docker compose up -d)
  stop      Stop apps gracefully (docker compose stop)
  restart   Stop apps, then start them again
  update    Stop apps, pull the latest images and start them again
  backup    Stop apps, tar their folders into the backup folder, then update and start them
  logs      Show recent logs (follows the log when a single app is targeted)
  version   Show the image versions each app is using
  running   List running containers (docker ps)
  apt       Update the host system with apt-get (Debian/Ubuntu)
  help      Show this help

Commands run against every app in the Apps variable. Pass one or more
folder names to target specific apps instead, e.g. ./manage.sh restart linkace
EOF
}

run_command() {
  menu_command=$1
  # shellcheck disable=SC2086 # Apps is an intentionally space-separated list
  set -- $Apps
  case "$menu_command" in
    'backup' )
      checkDefault
      require_docker
      actioninfo "${bold}Backing up${normal} apps including:"
      list_apps "$@"
      for app in "$@"; do
        backup_app "$app"
      done
      success "Backing up completed"
      ;;
    'restore' )
      echo "Coming soon:"
      ;;
    'logs' )
      checkDefault
      require_docker
      if [ $# -eq 1 ]; then
        echo "Following ${bold}$1${normal} logs (Ctrl-C to stop)"
        enter_app "$1"
        compose logs -f
        cd ..
      else
        for app in "$@"; do
          echo "Getting ${bold}$app${normal} logs"
          enter_app "$app"
          compose logs --tail=20
          cd ..
        done
      fi
      ;;
    'update' )
      checkDefault
      require_docker
      actioninfo "${bold}Updating all services.${normal}"
      list_apps "$@"
      for app in "$@"; do
        update_app "$app"
      done
      success "Services updated. Give them a moment to warm up."
      ;;
    'stop' )
      checkDefault
      require_docker
      actioninfo "${bold}Stopping${normal} all services:"
      list_apps "$@"
      for app in "$@"; do
        stop_app "$app"
      done
      success "Services stopped"
      ;;
    'start' )
      checkDefault
      require_docker
      actioninfo "${bold}Starting${normal} all services"
      list_apps "$@"
      for app in "$@"; do
        start_app "$app"
      done
      success "Services started. Give them a moment to warm up."
      ;;
    'restart' )
      checkDefault
      require_docker
      actioninfo "${bold}Restarting${normal} all services"
      for app in "$@"; do
        restart_app "$app"
      done
      success "Services restarted. Give them a moment to warm up."
      ;;
    'version' )
      checkDefault
      require_docker
      for app in "$@"; do
        echo "Getting ${bold}$app${normal} version"
        enter_app "$app"
        compose images
        cd ..
      done
      ;;
    'running' )
      require_docker
      echo "Getting all running services"
      docker ps
      ;;
    'apt' )
      if ! command -v apt-get >/dev/null 2>&1; then
        error "apt-get not found. This command is only for Debian/Ubuntu systems."
        exit 1
      fi
      echo "Updating system with apt."
      apt-get update && apt-get upgrade -y
      success "System updated"
      ;;
    'help' | '-h' | '--help' )
      usage
      ;;
    * )
      error "Unknown command '$menu_command'"
      usage
      exit 1
      ;;
  esac
}

APPS_OVERRIDDEN=0
if [ $# -eq 0 ]; then
  usage
  exit 1
fi

COMMAND=$1
shift
if [ $# -gt 0 ]; then
  #Remaining arguments target specific apps, e.g. ./manage.sh restart linkace
  Apps="$*"
  APPS_OVERRIDDEN=1
fi
run_command "$COMMAND"
