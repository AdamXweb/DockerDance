#!/bin/sh
set -e

VERSION="0.2.0"
#Repo used by update-self; override with DOCKERDANCE_REPO=owner/name
SELF_REPO="${DOCKERDANCE_REPO:-AdamXweb/DockerDance}"

#Set these variables!
#Apps to backup (according to the folder name). Add each one with a space in between e.g. "vaultwarden uptime-kuma"
Apps="example"
USERNAME="systemadmin"

#Optional config file: put Apps/USERNAME (plus DOCKER_VOLUMES, STOP_TIMEOUT,
#BACKUP_KEEP, NOTIFY_WEBHOOK) in a manage.conf next to the script and they
#survive update-self
if [ -f "./manage.conf" ]; then
  # shellcheck source=/dev/null
  . "./manage.conf"
fi

#Specific to Linux. Can change these if needed
#Set folder from root to avoid permission issues if running script as different user. (this would be /home/systemadmin/docker_volumes)
#Can also be overridden from the environment, e.g. for MacOS:
#  DOCKER_VOLUMES="/Users/yourname/docker_volumes/" ./manage.sh start
DOCKER_VOLUMES="${DOCKER_VOLUMES:-/home/$USERNAME/docker_volumes/}"
#Target is the folder within that the tar will save to if running a backup.
TARGET="${DOCKER_VOLUMES}backup/"
#Seconds to wait for containers to shut down gracefully before docker gives up
#(docker's own default of 10s can be too short for busy databases)
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"


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
case "$SPINNER_FRAMES" in
  ⠋* ) DOT_ON='●' DOT_OFF='○' ;;
  * )  DOT_ON='*' DOT_OFF='-' ;;
esac

STEP_LOG="${TMPDIR:-/tmp}/dockerdance-step.$$.log"
#One state-changing run at a time per docker_volumes folder (protects
#against a cron backup overlapping a manual update)
LOCK_DIR="${TMPDIR:-/tmp}/dockerdance$(pwd | tr '/ ' '__').lock"
HAVE_LOCK=""
NOTIFY_CONTEXT=""
cleanup() {
  cleanup_status=$?
  tput cnorm 2>/dev/null || true
  rm -f "$STEP_LOG"
  if [ -n "$HAVE_LOCK" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  if [ "$cleanup_status" -ne 0 ] && [ -n "$NOTIFY_CONTEXT" ]; then
    notify "$NOTIFY_CONTEXT failed (exit $cleanup_status)"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

#NOTIFY_WEBHOOK (optional, set in manage.conf or the environment): URL that
#receives a message when update/backup/restore completes or fails. The JSON
#payload suits Slack ("text") and Discord ("content") webhooks. Issue #3.
notify() {
  [ -z "${NOTIFY_WEBHOOK:-}" ] && return 0
  notify_payload="{\"text\": \"DockerDance: $1\", \"content\": \"DockerDance: $1\"}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m 10 -H 'Content-Type: application/json' -d "$notify_payload" "$NOTIFY_WEBHOOK" >/dev/null 2>&1 || warn "Webhook notification failed"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 10 --header 'Content-Type: application/json' --post-data "$notify_payload" -O /dev/null "$NOTIFY_WEBHOOK" 2>/dev/null || warn "Webhook notification failed"
  fi
  return 0
}

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

acquire_lock() {
  [ -n "$HAVE_LOCK" ] && return 0
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    error "Another manage.sh run appears to be active here (lock: $LOCK_DIR). Remove that folder if it's stale."
    exit 1
  fi
  HAVE_LOCK=1
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

has_compose_file() {
  [ -f "$1/docker-compose.yml" ] || [ -f "$1/docker-compose.yaml" ] || [ -f "$1/compose.yml" ] || [ -f "$1/compose.yaml" ]
}

enter_app() {
  APP_RETURN_DIR=$(pwd)
  if [ ! -d "$1" ]; then
    error "No folder named '$1' here. Run this from the docker_volumes folder and check the Apps variable / arguments."
    exit 1
  fi
  cd "$1"
  if has_compose_file .; then
    return 0
  fi
  #The compose file may sit one folder deeper (issue #6) - follow it when unambiguous
  nested=""
  nested_count=0
  for nested_dir in */; do
    [ -d "$nested_dir" ] || continue
    if has_compose_file "$nested_dir"; then
      nested=$nested_dir
      nested_count=$((nested_count + 1))
    fi
  done
  if [ "$nested_count" -eq 1 ]; then
    cd "$nested"
    return 0
  fi
  if [ "$nested_count" -gt 1 ]; then
    error "'$1' contains several nested folders with compose files - list those folders in Apps directly."
  else
    error "No compose file found in '$1' (or one level below it)."
  fi
  exit 1
}

leave_app() {
  cd "$APP_RETURN_DIR"
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

#Per-app results collected during a run, shown as a closing summary
SUMMARY=""
record() {
  SUMMARY="${SUMMARY}$1|$2|$(( $(date +%s) - app_start ))
"
}
print_summary() {
  if [ -z "$SUMMARY" ] || [ -z "$APP_TOTAL" ] || [ "$APP_TOTAL" -le 1 ]; then
    return 0
  fi
  echo "---"
  printf '%s' "$SUMMARY" | while IFS='|' read -r s_app s_action s_secs; do
    [ -z "$s_app" ] && continue
    printf '  %s%-24s%s %-12s %s%4ss%s\n' "$bold" "$s_app" "$normal" "$s_action" "$dim" "$s_secs" "$normal"
  done
}

list_apps() {
  for app in "$@"; do
    echo "$cyan$ARROW$normal $app"
  done
  echo "---"
}

#Pull with docker's own progress bars on a terminal, quietly otherwise
pull_images() {
  echo "$(counter)Pulling ${bold}$1${normal} images"
  if [ -n "$SPINNER" ]; then
    compose pull
  else
    compose pull --quiet
  fi
}

start_app() {
  app_start=$(date +%s)
  enter_app "$1"
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  ok "$(counter)$1 started"
  record "$1" "started"
  leave_app
}

stop_app() {
  app_start=$(date +%s)
  enter_app "$1"
  #stop (not kill) shuts containers down gracefully so databases can finish writing
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT"
  ok "$(counter)$1 stopped"
  record "$1" "stopped"
  leave_app
}

restart_app() {
  app_start=$(date +%s)
  enter_app "$1"
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT"
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  ok "$(counter)$1 restarted"
  record "$1" "restarted"
  leave_app
}

update_app() {
  app_start=$(date +%s)
  enter_app "$1"
  #Pull while the app is still running so downtime is only the stop/start window
  pull_images "$1"
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT"
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  ok "$(counter)$1 updated and running"
  record "$1" "updated"
  leave_app
}

backup_app() {
  app_start=$(date +%s)
  enter_app "$1"
  #Pull while the app is still running so downtime is only the stop/backup/start window
  pull_images "$1"
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT"
  mkdir -p "$TARGET"
  archive="${TARGET}${1}$(date '+%Y-%m-%d').tar.bz2"
  if [ -e "$archive" ]; then
    warn "${archive##*/} already exists - keeping it and adding a timestamp to this one"
    archive="${TARGET}${1}$(date '+%Y-%m-%d_%H%M%S').tar.bz2"
  fi
  #Relative paths inside the archive make restores portable; 600 keeps the
  #.env secrets inside it private
  run_step "$(counter)Backing up ${bold}$1${normal}" tar -C "$DOCKER_VOLUMES" -cjf "$archive" "$1"
  chmod 600 "$archive"
  if [ -n "${BACKUP_KEEP:-}" ]; then
    # shellcheck disable=SC2012 # archive names are script-generated (no spaces/newlines)
    ls -1t "${TARGET}${1}"[0-9]*.tar.bz2 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | while IFS= read -r old_backup; do
      rm -f "$old_backup"
      warn "Pruned old backup ${old_backup##*/} (BACKUP_KEEP=$BACKUP_KEEP)"
    done
  fi
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  ok "$(counter)$1 backed up, updated and running"
  record "$1" "backed up"
  leave_app
}

#Restore the newest backup for an app (issue #2). Current data is moved
#aside - never deleted - so a bad restore is always reversible by hand.
restore_app() {
  app_start=$(date +%s)
  # shellcheck disable=SC2012 # archive names are script-generated (no spaces/newlines)
  archive=$(ls -1t "${TARGET}${1}"[0-9]*.tar.bz2 2>/dev/null | head -1)
  if [ -z "$archive" ]; then
    error "No backups found for '$1' in $TARGET"
    exit 1
  fi
  #Which layout is inside? New backups hold '<app>/...', pre-v0.2.0 ones held absolute paths
  first_member=$(tar -tjf "$archive" 2>/dev/null | head -1)
  case "$first_member" in
    "$1"/* ) restore_root=$DOCKER_VOLUMES ;;
    *docker_volumes/"$1"/* ) restore_root="/" ;;
    * )
      error "Unrecognised layout in ${archive##*/} - restore it manually with tar."
      exit 1
      ;;
  esac
  echo "$(counter)Restoring ${bold}$1${normal} from ${archive##*/}"
  if [ -t 0 ]; then
    printf '%s' "This replaces ${DOCKER_VOLUMES}${1} (current data is set aside, not deleted). Continue? [y/N] "
    read -r answer || answer=""
    case "$answer" in
      y | Y | yes | YES ) ;;
      * ) echo "Skipped $1."; return 0 ;;
    esac
  else
    error "restore needs a terminal to confirm. Run it interactively."
    exit 1
  fi
  enter_app "$1"
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT"
  leave_app
  aside="${DOCKER_VOLUMES}${1}.pre-restore.$(date '+%Y%m%d%H%M%S')"
  mv "${DOCKER_VOLUMES}${1}" "$aside"
  if ! run_step "$(counter)Extracting ${bold}${archive##*/}${normal}" tar -xjf "$archive" -C "$restore_root"; then
    rm -rf "${DOCKER_VOLUMES:?}${1}"
    mv "$aside" "${DOCKER_VOLUMES}${1}"
    error "Restore failed - the original data was put back."
    exit 1
  fi
  enter_app "$1"
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  leave_app
  ok "$(counter)$1 restored. Previous data kept at ${aside##*/} - delete it once you're happy"
  record "$1" "restored"
}

fetch_url() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    error "curl or wget is required to download updates."
    exit 1
  fi
}

update_self() {
  actioninfo "Checking the latest ${bold}$SELF_REPO${normal} release"
  latest_tag=$(fetch_url "https://api.github.com/repos/$SELF_REPO/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [ -z "$latest_tag" ]; then
    error "Couldn't find a release for $SELF_REPO. Are you online?"
    exit 1
  fi
  new_script="$0.new.$$"
  if ! fetch_url "https://raw.githubusercontent.com/$SELF_REPO/$latest_tag/docker_volumes/manage.sh" > "$new_script"; then
    rm -f "$new_script"
    error "Downloading manage.sh at $latest_tag failed."
    exit 1
  fi
  new_version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$new_script" | head -1)
  if [ -z "$new_version" ]; then
    rm -f "$new_script"
    error "Release $latest_tag predates self-updating (it has no VERSION). Update manually from https://github.com/$SELF_REPO/releases"
    exit 1
  fi
  if [ "$new_version" = "$VERSION" ]; then
    rm -f "$new_script"
    success "Already up to date (v$VERSION, release $latest_tag)."
    return 0
  fi
  if ! sh -n "$new_script" 2>/dev/null; then
    rm -f "$new_script"
    error "The downloaded script failed a syntax check - not installing it."
    exit 1
  fi
  #Carry the Apps/USERNAME configured in this copy across the update
  #(put them in manage.conf to avoid relying on this)
  sed "s|^Apps=\".*\"|Apps=\"$ORIGINAL_APPS\"|; s|^USERNAME=\".*\"|USERNAME=\"$USERNAME\"|" "$new_script" > "$new_script.tmp"
  mv "$new_script.tmp" "$new_script"
  chmod +x "$new_script"
  mv "$new_script" "$0"
  success "Updated v$VERSION -> v$new_version ($latest_tag). Apps/USERNAME configuration carried over."
}

usage() {
  cat <<EOF
${bold}${cyan}DockerDance${normal} v$VERSION - bulk manage docker compose apps

Usage: ./manage.sh <command> [app ...]

Commands:
  start        Start apps (docker compose up -d)
  stop         Stop apps gracefully (docker compose stop)
  restart      Stop apps, then start them again
  update       Pull the latest images, then restart apps on them
  backup       Pull, stop, tar app folders into the backup folder, then start again
  restore      Put the newest backup archive back in place (current data is set aside)
  logs         Show recent logs (follows the log when a single app is targeted)
  version      Show the image versions each app is using
  running      List running containers (docker ps)
  apt          Update the host system with apt-get (Debian/Ubuntu)
  update-self  Update this script to the latest GitHub release
  help         Show this help (--version shows the script version)

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
  SUMMARY=""
  case "$menu_command" in
    'backup' | 'update' | 'stop' | 'start' | 'restart' | 'restore' ) acquire_lock ;;
  esac
  case "$menu_command" in
    'backup' )
      checkDefault
      require_docker
      NOTIFY_CONTEXT="Backup of $*"
      actioninfo "${bold}Backing up${normal} apps including:"
      list_apps "$@"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        backup_app "$app"
      done
      print_summary
      success "Backing up completed in $(elapsed)"
      notify "Backup of $* completed in $(elapsed)"
      NOTIFY_CONTEXT=""
      ;;
    'restore' )
      checkDefault
      require_docker
      NOTIFY_CONTEXT="Restore of $*"
      actioninfo "${bold}Restoring${normal} apps from their latest backups:"
      list_apps "$@"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        restore_app "$app"
      done
      print_summary
      success "Restore completed in $(elapsed)"
      notify "Restore of $* completed in $(elapsed)"
      NOTIFY_CONTEXT=""
      ;;
    'logs' )
      checkDefault
      require_docker
      if [ $# -eq 1 ]; then
        echo "Following ${bold}$1${normal} logs (Ctrl-C to stop)"
        enter_app "$1"
        compose logs -f
        leave_app
      else
        for app in "$@"; do
          echo "Getting ${bold}$app${normal} logs"
          enter_app "$app"
          compose logs --tail=20
          leave_app
        done
      fi
      ;;
    'update' )
      checkDefault
      require_docker
      NOTIFY_CONTEXT="Update of $*"
      actioninfo "${bold}Updating all services.${normal}"
      list_apps "$@"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        update_app "$app"
      done
      print_summary
      success "Services updated in $(elapsed). Give them a moment to warm up."
      notify "Update of $* completed in $(elapsed)"
      NOTIFY_CONTEXT=""
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
      print_summary
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
      print_summary
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
      print_summary
      success "Services restarted in $(elapsed). Give them a moment to warm up."
      ;;
    'version' )
      checkDefault
      require_docker
      for app in "$@"; do
        echo "Getting ${bold}$app${normal} version"
        enter_app "$app"
        compose images
        leave_app
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
    'update-self' | 'updateself' )
      update_self
      ;;
    '--version' | '-V' )
      echo "DockerDance manage.sh v$VERSION"
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

#Green dot when a container whose compose project matches the app folder is up.
#Best-effort: compose lowercases project names and strips leading symbols.
status_dot() {
  sd_proj=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[^a-z0-9]*//')
  if [ -n "$sd_proj" ] && printf '%s\n' "$RUNNING_NAMES" | grep -q "^${sd_proj}[-_]"; then
    printf '%s%s%s' "$green" "$DOT_ON" "$normal"
  else
    printf '%s%s%s' "$dim" "$DOT_OFF" "$normal"
  fi
}

pick_app() {
  #Sets PICKED_APP to one app name, or "" for all apps. Returns 1 if cancelled.
  PICKED_APP=""
  if command -v fzf >/dev/null 2>&1; then
    #The preview pane shows live container status for the highlighted app
    fzf_preview='if [ {} = "all apps" ]; then docker ps; else (cd {} && '"$DOCKER_COMPOSE_COMMAND"' ps) 2>/dev/null || echo "(no status)"; fi'
    PICKED_APP=$(printf '%s\n' "all apps" "$@" | fzf --prompt="app> " --preview "$fzf_preview") || return 1
    if [ "$PICKED_APP" = "all apps" ]; then
      PICKED_APP=""
    fi
    return 0
  fi
  RUNNING_NAMES=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
  n=0
  echo "  0) all apps"
  for app in "$@"; do
    n=$((n + 1))
    echo "  $n) $(status_dot "$app") $app"
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
    echo "${bold}${cyan}DockerDance${normal} ${dim}v$VERSION${normal} - what would you like to do?"
    echo "  1) start    2) stop     3) restart"
    echo "  4) update   5) backup   6) restore"
    echo "  7) logs     8) version  9) running"
    echo "  q) quit"
    printf "> "
    read -r choice || break
    case "$choice" in
      1 ) choice="start" ;;
      2 ) choice="stop" ;;
      3 ) choice="restart" ;;
      4 ) choice="update" ;;
      5 ) choice="backup" ;;
      6 ) choice="restore" ;;
      7 ) choice="logs" ;;
      8 ) choice="version" ;;
      9 ) choice="running" ;;
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
    #Run in a subshell so one failed command reports and returns to the menu
    #instead of ending the whole session under set -e
    set +e
    ( set -e; trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; run_command "$choice" )
    menu_status=$?
    set -e
    if [ "$menu_status" -ne 0 ]; then
      warn "Command finished with errors (exit $menu_status)"
    fi
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
#Remember the configured list: update-self writes it into the new script even
#when this run targeted specific apps
ORIGINAL_APPS=$Apps
if [ $# -gt 0 ]; then
  #Remaining arguments target specific apps, e.g. ./manage.sh restart linkace
  Apps="$*"
  APPS_OVERRIDDEN=1
fi
run_command "$COMMAND"
