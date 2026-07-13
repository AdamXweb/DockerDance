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


#Add styling (only on a terminal that supports it; NO_COLOR=1 disables colour, see no-color.org)
bold="" normal="" red="" green="" yellow="" cyan="" dim=""
SPINNER=""
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  SPINNER=1
  if [ -z "${NO_COLOR:-}" ] && command -v tput >/dev/null 2>&1; then
    bold=$(tput bold) || bold=""
    normal=$(tput sgr0) || normal=""
    if [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
      red=$(tput setaf 1) || red=""
      green=$(tput setaf 2) || green=""
      yellow=$(tput setaf 3) || yellow=""
      cyan=$(tput setaf 6) || cyan=""
      dim=$(tput dim 2>/dev/null) || dim=""
    fi
  fi
fi

#Unicode niceties with a plain-ASCII fallback for non UTF-8 locales
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8* )
    SPINNER_FRAMES='⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏'
    ARROW='⇒'
    ;;
  * )
    SPINNER_FRAMES='- \ | /'
    ARROW='=>'
    ;;
esac

STEP_LOG="${TMPDIR:-/tmp}/dockerdance-step.$$.log"
cleanup() {
  tput cnorm 2>/dev/null || true
  rm -f "$STEP_LOG"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

actioninfo() {
  echo "${bold}${cyan}[action]${normal} $ARROW $1"
}
ok() {
  echo "${bold}${green}[ok]${normal} - $1"
}
success() {
  echo "${bold}${green}[success]${normal} - $1"
}
warn() {
  echo "${bold}${yellow}[warn]${normal} - $1" >&2
}
error() {
  echo "${bold}${red}[error]${normal} - $1" >&2
}

#Run a command behind a spinner. Output is captured and only shown if the command fails.
#Without a terminal (cron, pipes) the label is printed and the command runs with plain output.
run_step() {
  step_label=$1
  shift
  if [ -z "$SPINNER" ]; then
    echo "$step_label"
    "$@"
    return 0
  fi
  "$@" >"$STEP_LOG" 2>&1 &
  step_pid=$!
  tput civis 2>/dev/null || true
  step_status=0
  while kill -0 "$step_pid" 2>/dev/null; do
    # shellcheck disable=SC2086 # frames are an intentionally space-separated list
    for frame in $SPINNER_FRAMES; do
      kill -0 "$step_pid" 2>/dev/null || break
      printf '\r%s%s%s %s' "$cyan" "$frame" "$normal" "$step_label"
      sleep 0.1 2>/dev/null || sleep 1
    done
  done
  wait "$step_pid" || step_status=$?
  printf '\r'
  tput el 2>/dev/null || printf '%-79s\r' ''
  tput cnorm 2>/dev/null || true
  if [ "$step_status" -ne 0 ]; then
    error "$step_label failed:"
    sed 's/^/    /' "$STEP_LOG" >&2
    rm -f "$STEP_LOG"
    return "$step_status"
  fi
  rm -f "$STEP_LOG"
  return 0
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

#Progress counter shown when more than one app is being processed
APP_NUM="" APP_TOTAL=""
counter() {
  if [ -n "$APP_TOTAL" ] && [ "$APP_TOTAL" -gt 1 ]; then
    printf '%s[%s/%s]%s ' "$dim" "$APP_NUM" "$APP_TOTAL" "$normal"
  fi
}

RUN_START=""
elapsed() {
  [ -z "$RUN_START" ] && return 0
  e=$(( $(date +%s) - RUN_START ))
  if [ "$e" -ge 60 ]; then
    printf '%dm %ds' $((e / 60)) $((e % 60))
  else
    printf '%ds' "$e"
  fi
}

list_apps() {
  for app in "$@"; do
    echo "$cyan$ARROW$normal $app"
  done
  echo "---"
}

start_app() {
  enter_app "$1"
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  ok "$(counter)$1 started"
  cd ..
}

stop_app() {
  enter_app "$1"
  #stop (not kill) shuts containers down gracefully so databases can finish writing
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop
  ok "$(counter)$1 stopped"
  cd ..
}

restart_app() {
  enter_app "$1"
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  ok "$(counter)$1 restarted"
  cd ..
}

update_app() {
  enter_app "$1"
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop
  echo "$(counter)Pulling ${bold}$1${normal} images"
  compose pull
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  ok "$(counter)$1 updated and running"
  cd ..
}

backup_app() {
  enter_app "$1"
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop
  mkdir -p "$TARGET"
  run_step "$(counter)Backing up ${bold}$1${normal}" tar -cjf "${TARGET}${1}$(date '+%Y-%m-%d').tar.bz2" "${DOCKER_VOLUMES}${1}"
  echo "$(counter)Pulling ${bold}$1${normal} images"
  compose pull
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  ok "$(counter)$1 backed up, updated and running"
  cd ..
}

usage() {
  cat <<EOF
${bold}${cyan}DockerDance${normal} - bulk manage docker compose apps

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
  RUN_START=$(date +%s)
  APP_TOTAL=$#
  APP_NUM=0
  case "$menu_command" in
    'backup' )
      checkDefault
      require_docker
      actioninfo "${bold}Backing up${normal} apps including:"
      list_apps "$@"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        backup_app "$app"
      done
      success "Backing up completed in $(elapsed)"
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
        APP_NUM=$((APP_NUM + 1))
        update_app "$app"
      done
      success "Services updated in $(elapsed). Give them a moment to warm up."
      ;;
    'stop' )
      checkDefault
      require_docker
      actioninfo "${bold}Stopping${normal} all services:"
      list_apps "$@"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        stop_app "$app"
      done
      success "Services stopped in $(elapsed)"
      ;;
    'start' )
      checkDefault
      require_docker
      actioninfo "${bold}Starting${normal} all services"
      list_apps "$@"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        start_app "$app"
      done
      success "Services started in $(elapsed). Give them a moment to warm up."
      ;;
    'restart' )
      checkDefault
      require_docker
      actioninfo "${bold}Restarting${normal} all services"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        restart_app "$app"
      done
      success "Services restarted in $(elapsed). Give them a moment to warm up."
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

pick_app() {
  #Sets PICKED_APP to one app name, or "" for all apps. Returns 1 if cancelled.
  PICKED_APP=""
  if command -v fzf >/dev/null 2>&1; then
    PICKED_APP=$(printf '%s\n' "all apps" "$@" | fzf --prompt="app> ") || return 1
    if [ "$PICKED_APP" = "all apps" ]; then
      PICKED_APP=""
    fi
    return 0
  fi
  n=0
  echo "  0) all apps"
  for app in "$@"; do
    n=$((n + 1))
    echo "  $n) $app"
  done
  printf "Select an app [0-%s]: " "$n"
  read -r selection || return 1
  if [ "$selection" = "0" ]; then
    return 0
  fi
  n=0
  for app in "$@"; do
    n=$((n + 1))
    if [ "$n" = "$selection" ]; then
      PICKED_APP=$app
      return 0
    fi
  done
  echo "Not a valid selection."
  return 1
}

interactive() {
  checkDefault
  require_docker
  ALL_APPS=$Apps
  while :; do
    echo ""
    echo "${bold}${cyan}DockerDance${normal} - what would you like to do?"
    echo "  1) start    2) stop     3) restart"
    echo "  4) update   5) backup   6) logs"
    echo "  7) version  8) running  q) quit"
    printf "> "
    read -r choice || break
    case "$choice" in
      1 ) choice="start" ;;
      2 ) choice="stop" ;;
      3 ) choice="restart" ;;
      4 ) choice="update" ;;
      5 ) choice="backup" ;;
      6 ) choice="logs" ;;
      7 ) choice="version" ;;
      8 ) choice="running" ;;
      q | Q | quit | exit ) break ;;
      * ) echo "Not a valid choice."; continue ;;
    esac
    Apps=$ALL_APPS
    if [ "$choice" != "running" ]; then
      # shellcheck disable=SC2086 # Apps is an intentionally space-separated list
      pick_app $Apps || continue
      if [ -n "$PICKED_APP" ]; then
        Apps=$PICKED_APP
      fi
    fi
    run_command "$choice"
  done
}

APPS_OVERRIDDEN=0
if [ $# -eq 0 ]; then
  if [ -t 0 ]; then
    #No arguments on a terminal: offer the interactive menu
    interactive
    exit 0
  fi
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
