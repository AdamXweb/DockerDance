#!/bin/sh
set -e

VERSION="0.3.0"
#Repo used by update-self; override with DOCKERDANCE_REPO=owner/name
SELF_REPO="${DOCKERDANCE_REPO:-AdamXweb/DockerDance}"

#Set these variables!
#Apps to manage. "auto" (the default) discovers every folder here that holds a
#compose file (docker-compose.yml/.yaml or compose.yml/.yaml, or one folder
#deeper), skipping backup/ and *.pre-restore.* folders. Or list folder names
#with a space in between e.g. "vaultwarden uptime-kuma" to pin the set/order.
Apps="auto"
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

#mktemp gives an unpredictable, owner-only name so another user can't pre-create
#it as a symlink and have root truncate a file through us. Fall back to the PID.
STEP_LOG=$(mktemp "${TMPDIR:-/tmp}/dockerdance-step.XXXXXX" 2>/dev/null) || STEP_LOG="${TMPDIR:-/tmp}/dockerdance-step.$$.log"
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

#Ask a yes/no question. --yes answers yes; a non-interactive run (cron) also
#proceeds so scheduled jobs aren't blocked. Returns non-zero if the user says no.
confirm() {
  [ -n "${ASSUME_YES:-}" ] && return 0
  [ -t 0 ] || return 0
  printf '%s [y/N] ' "$1"
  read -r cf_ans || cf_ans=""
  case "$cf_ans" in
    y | Y | yes | YES ) return 0 ;;
    * ) return 1 ;;
  esac
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
  if [ -n "${DRY_RUN:-}" ]; then
    echo "${dim}[dry-run]${normal} would: $step_label"
    return 0
  fi
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

#Docker's official install ("convenience") script. Only ever fetched from here.
DOCKER_INSTALL_URL="https://get.docker.com"

#Docker isn't installed: point at the official docs, and - only interactively,
#never in cron - offer to fetch and run Docker's official install script. The
#script uses sudo itself where it needs root. Defaults to no.
offer_docker_install() {
  echo "  Install Docker for your platform: https://docs.docker.com/engine/install/"
  echo "  Or use Docker's official script (review it first; it needs root):"
  echo "    curl -fsSL $DOCKER_INSTALL_URL -o get-docker.sh && sh get-docker.sh"
  #Never auto-install: needs a terminal and a downloader, and dry-run just shows the hint
  [ -n "${DRY_RUN:-}" ] && return 0
  [ -t 0 ] || return 0
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || return 0
  printf 'Download and run the official Docker install script now? [y/N] '
  read -r odi_ans || odi_ans=""
  case "$odi_ans" in
    y | Y | yes | YES ) ;;
    * ) return 0 ;;
  esac
  odi_dir=$(mktemp -d "${TMPDIR:-/tmp}/dockerdance-getdocker.XXXXXX" 2>/dev/null) || { odi_dir="${TMPDIR:-/tmp}/dockerdance-getdocker.$$"; mkdir -p "$odi_dir"; }
  echo "Downloading $DOCKER_INSTALL_URL ..."
  if fetch_url "$DOCKER_INSTALL_URL" >"$odi_dir/get-docker.sh" && [ -s "$odi_dir/get-docker.sh" ]; then
    echo "Running the installer (you may be prompted for a sudo password)..."
    if sh "$odi_dir/get-docker.sh"; then
      success "Docker installed. You may need to log out and back in for group membership to apply, then re-run this command."
    else
      error "The Docker install script exited with an error - see its output above."
    fi
  else
    error "Couldn't download the Docker install script from $DOCKER_INSTALL_URL."
  fi
  rm -rf "$odi_dir"
}

#Check Docker is installed, the daemon is reachable and compose is available
DOCKER_COMPOSE_COMMAND=""
require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    error "Docker isn't installed (or isn't in your PATH)."
    offer_docker_install
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
    error "Please change the 'Apps' variable: list your apps, or set Apps=\"auto\" to manage every folder here with a compose file."
    exit 1
  fi
}

#Apps="auto": build the app list from the folders actually present
discover_apps() {
  found=""
  #the extra patterns pick up hidden apps like .n8n while skipping . and ..
  for d in */ .[!.]*/ ..?*/; do
    [ -d "$d" ] || continue
    d=${d%/}
    case "$d" in
      backup | *.pre-restore.* ) continue ;;
    esac
    if has_compose_file "$d"; then
      found="$found $d"
      continue
    fi
    for sub in "$d"/*/; do
      [ -d "$sub" ] || continue
      if has_compose_file "$sub"; then
        found="$found $d"
        break
      fi
    done
  done
  Apps=${found# }
}

maybe_discover_apps() {
  [ "$APPS_OVERRIDDEN" = "1" ] && return 0
  case "$Apps" in
    'auto' | '' ) ;;
    * ) return 0 ;;
  esac
  discover_apps
  if [ -z "$Apps" ]; then
    error "Apps=\"auto\" found no folders with a compose file in $(pwd). Run this from your docker_volumes folder."
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

#Silent version of enter_app's lookup: echo the folder that holds the compose
#file for app $1 (itself, or one unambiguous level down), or fail quietly.
resolve_dir() {
  if has_compose_file "$1"; then
    echo "$1"
    return 0
  fi
  rd_hit=""
  rd_n=0
  for rd in "$1"/*/; do
    [ -d "$rd" ] || continue
    if has_compose_file "$rd"; then
      rd_hit=${rd%/}
      rd_n=$((rd_n + 1))
    fi
  done
  if [ "$rd_n" -eq 1 ]; then
    echo "$rd_hit"
    return 0
  fi
  return 1
}

#Is $1 one of the space-separated words in $2?
in_list() {
  # shellcheck disable=SC2086 # $2 is an intentionally space-separated list
  for il_x in $2; do
    [ "$il_x" = "$1" ] && return 0
  done
  return 1
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

#How many image pulls to run at once (nala-style). 1 makes pulls sequential.
PARALLEL_PULLS="${PARALLEL_PULLS:-3}"

#Pull one app's images quietly - used by the parallel orchestrator, where
#interleaved progress bars would be unreadable.
_pull_one() {
  enter_app "$1"
  compose pull --quiet
}

#Launch pulls in batches of PARALLEL_PULLS, recording any that fail.
_pull_orchestrate() {
  while [ $# -gt 0 ]; do
    po_pids=""
    po_c=0
    while [ $# -gt 0 ] && [ "$po_c" -lt "$PARALLEL_PULLS" ]; do
      po_app=$1
      shift
      po_c=$((po_c + 1))
      ( _pull_one "$po_app" ) >"$pp_dir/$po_app.log" 2>&1 &
      po_pid=$!
      po_pids="$po_pids $po_pid"
      echo "$po_app" >"$pp_dir/pid.$po_pid"
    done
    # shellcheck disable=SC2086 # pids are numeric, space-separated on purpose
    for po_pid in $po_pids; do
      if ! wait "$po_pid"; then
        cat "$pp_dir/pid.$po_pid" >>"$pp_dir/failed"
      fi
    done
  done
}

#Pull images for several apps concurrently. Sets PULL_FAILED to the apps whose
#pull failed; the caller leaves those on their current image and skips them.
parallel_pull() {
  PULL_FAILED=""
  [ $# -eq 0 ] && return 0
  if [ -n "${DRY_RUN:-}" ]; then
    for pp_app in "$@"; do
      echo "${dim}[dry-run]${normal} would pull ${bold}$pp_app${normal} images"
    done
    return 0
  fi
  pp_total=$#
  pp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dockerdance-pull.XXXXXX" 2>/dev/null) || { pp_dir="${TMPDIR:-/tmp}/dockerdance-pull.$$"; mkdir -p "$pp_dir"; }
  : >"$pp_dir/failed"
  #Run the orchestrator in the background so one spinner can cover the phase.
  ( _pull_orchestrate "$@" ) >"$pp_dir/orch.log" 2>&1 &
  pp_orch=$!
  pp_label="Pulling images for $pp_total app(s), up to $PARALLEL_PULLS at a time"
  if [ -n "$SPINNER" ]; then
    tput civis 2>/dev/null || true
    while kill -0 "$pp_orch" 2>/dev/null; do
      # shellcheck disable=SC2086 # frames are an intentionally space-separated list
      for pp_frame in $SPINNER_FRAMES; do
        kill -0 "$pp_orch" 2>/dev/null || break
        printf '\r%s%s%s %s' "$cyan" "$pp_frame" "$normal" "$pp_label"
        sleep 0.1 2>/dev/null || sleep 1
      done
    done
    printf '\r'
    tput el 2>/dev/null || printf '%-79s\r' ''
    tput cnorm 2>/dev/null || true
    wait "$pp_orch" || true
  else
    echo "$pp_label..."
    wait "$pp_orch" || true
  fi
  PULL_FAILED=$(tr '\n' ' ' <"$pp_dir/failed")
  PULL_FAILED=${PULL_FAILED% }
  for pp_app in $PULL_FAILED; do
    warn "Pull failed for $pp_app - leaving it on its current image"
    [ -s "$pp_dir/$pp_app.log" ] && sed 's/^/    /' "$pp_dir/$pp_app.log" >&2
  done
  rm -rf "$pp_dir"
}

#Wait for an app's containers to come up healthy after starting. Containers
#with a healthcheck must report 'healthy'; those without just need to be
#running. Best-effort and never fails the run - it gives up after
#HEALTH_TIMEOUT seconds (set HEALTH_TIMEOUT=0 to skip the wait entirely).
#Call from inside the app dir. $2 is the verb for the result line, or "" to
#stay quiet unless something is wrong. Uses `docker inspect` rather than
#parsing `compose ps --format json`, whose shape varies across versions.
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
wait_healthy() {
  wh_app=$1
  wh_verb=${2:-}
  [ -n "${DRY_RUN:-}" ] && return 0
  if ! [ "${HEALTH_TIMEOUT:-0}" -gt 0 ] 2>/dev/null; then
    [ -n "$wh_verb" ] && ok "$(counter)$wh_app $wh_verb"
    return 0
  fi
  wh_deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  wh_label="$(counter)Waiting for ${bold}$wh_app${normal} to be healthy"
  [ -n "$SPINNER" ] && { tput civis 2>/dev/null || true; }
  wh_rc=0
  wh_result=""
  wh_hchecks=0
  while :; do
    wh_ids=$(compose ps -q 2>/dev/null)
    if [ -z "$wh_ids" ]; then wh_rc=1; wh_result="no containers came up"; break; fi
    wh_total=0; wh_up=0; wh_unhealthy=0; wh_starting=0; wh_hchecks=0
    # shellcheck disable=SC2086 # ids are one-per-line with no spaces
    for wh_id in $wh_ids; do
      wh_total=$((wh_total + 1))
      wh_st=$(docker inspect -f '{{.State.Status}}' "$wh_id" 2>/dev/null)
      [ "$wh_st" = "running" ] && wh_up=$((wh_up + 1))
      wh_h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$wh_id" 2>/dev/null)
      case "$wh_h" in
        healthy )   wh_hchecks=$((wh_hchecks + 1)) ;;
        unhealthy ) wh_hchecks=$((wh_hchecks + 1)); wh_unhealthy=$((wh_unhealthy + 1)) ;;
        starting )  wh_hchecks=$((wh_hchecks + 1)); wh_starting=$((wh_starting + 1)) ;;
      esac
    done
    if [ "$wh_unhealthy" -gt 0 ]; then wh_rc=1; wh_result="a container is unhealthy"; break; fi
    if [ "$wh_up" -eq "$wh_total" ] && [ "$wh_starting" -eq 0 ]; then wh_rc=0; break; fi
    if [ "$(date +%s)" -ge "$wh_deadline" ]; then wh_rc=1; wh_result="still not healthy after ${HEALTH_TIMEOUT}s"; break; fi
    if [ -n "$SPINNER" ]; then
      # shellcheck disable=SC2086 # frames are an intentionally space-separated list
      for wh_frame in $SPINNER_FRAMES; do
        printf '\r%s%s%s %s' "$cyan" "$wh_frame" "$normal" "$wh_label"
        sleep 0.1 2>/dev/null || sleep 1
      done
    else
      sleep 2
    fi
  done
  if [ -n "$SPINNER" ]; then
    printf '\r'
    tput el 2>/dev/null || printf '%-79s\r' ''
    tput cnorm 2>/dev/null || true
  fi
  if [ "$wh_rc" -eq 0 ]; then
    if [ -n "$wh_verb" ]; then
      if [ "$wh_hchecks" -gt 0 ]; then
        ok "$(counter)$wh_app $wh_verb, healthy"
      else
        ok "$(counter)$wh_app $wh_verb"
      fi
    fi
  else
    if [ -n "$wh_verb" ]; then
      warn "$(counter)$wh_app $wh_verb, but $wh_result"
    else
      warn "$(counter)$wh_app $wh_result"
    fi
  fi
  return 0
}

start_app() {
  app_start=$(date +%s)
  enter_app "$1"
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  wait_healthy "$1" "started"
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
  wait_healthy "$1" "restarted"
  record "$1" "restarted"
  leave_app
}

#Images are pulled up front (in parallel) by the caller, so this just cycles
#the app onto the new image with minimal downtime.
update_app() {
  app_start=$(date +%s)
  enter_app "$1"
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT"
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  wait_healthy "$1" "updated and running"
  record "$1" "updated"
  leave_app
}

#Images are pulled up front (in parallel) by the caller; this stops, archives
#and starts the app back on the new image.
backup_app() {
  app_start=$(date +%s)
  enter_app "$1"
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT"
  archive="${TARGET}${1}$(date '+%Y-%m-%d').tar.bz2"
  if [ -z "${DRY_RUN:-}" ]; then
    mkdir -p "$TARGET"
    if [ -e "$archive" ]; then
      warn "${archive##*/} already exists - keeping it and adding a timestamp to this one"
      archive="${TARGET}${1}$(date '+%Y-%m-%d_%H%M%S').tar.bz2"
    fi
  fi
  #Relative paths inside the archive make restores portable; 600 keeps the
  #.env secrets inside it private
  run_step "$(counter)Backing up ${bold}$1${normal}" tar -C "$DOCKER_VOLUMES" -cjf "$archive" "$1"
  if [ -z "${DRY_RUN:-}" ]; then
    chmod 600 "$archive"
    if [ -n "${BACKUP_KEEP:-}" ]; then
      # shellcheck disable=SC2012 # archive names are script-generated (no spaces/newlines)
      ls -1t "${TARGET}${1}"[0-9]*.tar.bz2 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | while IFS= read -r old_backup; do
        rm -f "$old_backup"
        warn "Pruned old backup ${old_backup##*/} (BACKUP_KEEP=$BACKUP_KEEP)"
      done
    fi
  fi
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  wait_healthy "$1" "backed up, updated and running"
  record "$1" "backed up"
  leave_app
}

tar_is_busybox() {
  case "$(tar --version 2>&1 | head -1)" in
    *[Bb]usy[Bb]ox* ) return 0 ;;
    * ) return 1 ;;
  esac
}

#Restore the newest backup for an app (issue #2). Current data is moved
#aside - never deleted - so a bad restore is always reversible by hand.
#Archives are treated as untrusted: extraction happens into an isolated
#staging dir (never straight onto the filesystem root), every member is
#checked for path-traversal, and only the '<app>/' subtree is promoted.
restore_app() {
  app_start=$(date +%s)
  # shellcheck disable=SC2012 # archive names are script-generated (no spaces/newlines)
  archive=$(ls -1t "${TARGET}${1}"[0-9]*.tar.bz2 2>/dev/null | head -1)
  if [ -z "$archive" ]; then
    error "No backups found for '$1' in $TARGET"
    exit 1
  fi
  #Which layout is inside? New backups hold '<app>/...'; older (v0.1.0-era)
  #ones held absolute paths like '/home/x/docker_volumes/<app>/...'. Work out how many
  #leading components to strip so the app folder lands at the top of staging.
  first_member=$(tar -tjf "$archive" 2>/dev/null | head -1)
  first_rel=${first_member#/}
  case "$first_rel" in
    "$1"/* )
      strip_count=0 ; layout="relative" ;;
    */"$1"/* )
      legacy_prefix=${first_rel%%/"$1"/*}
      strip_count=$(printf '%s\n' "$legacy_prefix" | awk -F/ '{print NF}')
      layout="legacy" ;;
    * )
      error "Unrecognised layout in ${archive##*/} - restore it manually with tar."
      exit 1 ;;
  esac
  #Legacy absolute archives rely on GNU/bsdtar stripping the leading '/';
  #busybox tar does not, so refuse that one combination rather than risk a
  #write outside the staging dir.
  if [ "$layout" = "legacy" ] && tar_is_busybox; then
    error "${archive##*/} is a legacy absolute-path backup and your tar is busybox, which can't extract it safely. Restore it on a host with GNU tar."
    exit 1
  fi
  #Reject any member with a '..' component (all layouts) or an absolute path
  #(relative layout only - legacy members are absolute by design and stripped).
  member_list=$(mktemp "${TMPDIR:-/tmp}/dockerdance-members.XXXXXX" 2>/dev/null) || member_list="${TMPDIR:-/tmp}/dockerdance-members.$$"
  tar -tjf "$archive" 2>/dev/null > "$member_list"
  bad_member=""
  while IFS= read -r m; do
    case "/$m/" in
      */../* ) bad_member=$m; break ;;
    esac
    if [ "$layout" = "relative" ]; then
      case "$m" in
        /* ) bad_member=$m; break ;;
      esac
    fi
  done < "$member_list"
  rm -f "$member_list"
  if [ -n "$bad_member" ]; then
    error "Refusing to restore ${archive##*/}: unsafe path in archive ('$bad_member')."
    exit 1
  fi

  echo "$(counter)Restoring ${bold}$1${normal} from ${archive##*/}"
  if [ -n "${DRY_RUN:-}" ]; then
    echo "${dim}[dry-run]${normal} would replace ${DOCKER_VOLUMES}${1} with the contents of ${archive##*/} (current data set aside)"
    record "$1" "restored"
    return 0
  fi
  if [ -z "${ASSUME_YES:-}" ]; then
    if [ -t 0 ]; then
      printf '%s' "This replaces ${DOCKER_VOLUMES}${1} (current data is set aside, not deleted). Continue? [y/N] "
      read -r answer || answer=""
      case "$answer" in
        y | Y | yes | YES ) ;;
        * ) echo "Skipped $1."; return 0 ;;
      esac
    else
      error "restore needs a terminal to confirm (or pass --yes). Run it interactively."
      exit 1
    fi
  fi

  enter_app "$1"
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT"
  leave_app

  #Stage under backup/ (same filesystem as the app folders, so the promote is
  #an atomic rename) and extract there - never onto the host root.
  mkdir -p "$TARGET"
  staging=$(mktemp -d "${TARGET}restore.XXXXXX") || { error "Couldn't create a staging dir in $TARGET"; exit 1; }
  aside="${DOCKER_VOLUMES}${1}.pre-restore.$(date '+%Y%m%d%H%M%S')"
  mv "${DOCKER_VOLUMES}${1}" "$aside"
  extract_ok=1
  if [ "$strip_count" -gt 0 ]; then
    run_step "$(counter)Extracting ${bold}${archive##*/}${normal}" tar -xjf "$archive" -C "$staging" --strip-components="$strip_count" || extract_ok=0
  else
    run_step "$(counter)Extracting ${bold}${archive##*/}${normal}" tar -xjf "$archive" -C "$staging" || extract_ok=0
  fi
  [ -d "$staging/$1" ] || extract_ok=0
  if [ "$extract_ok" -ne 1 ]; then
    rm -rf "$staging"
    [ -e "${DOCKER_VOLUMES}${1}" ] || mv "$aside" "${DOCKER_VOLUMES}${1}"
    error "Restore failed - the original data was put back."
    exit 1
  fi
  mv "$staging/$1" "${DOCKER_VOLUMES}${1}"
  rm -rf "$staging"

  enter_app "$1"
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d
  wait_healthy "$1" ""
  leave_app
  ok "$(counter)$1 restored. Previous data kept at ${aside##*/} - delete it once you're happy"
  record "$1" "restored"
}

#Update the host OS packages with whatever package manager is present.
#Checked in order; the first hit wins, so distro managers beat homebrew.
system_update() {
  pm=""
  for candidate in apt-get dnf yum pacman zypper apk brew; do
    if command -v "$candidate" >/dev/null 2>&1; then
      pm=$candidate
      break
    fi
  done
  if [ -z "$pm" ]; then
    error "No supported package manager found (apt-get, dnf, yum, pacman, zypper, apk or brew)."
    exit 1
  fi
  if [ "$pm" != "brew" ] && [ "$(id -u)" -ne 0 ]; then
    error "System updates with $pm need root. Try: sudo ./manage.sh system-update"
    exit 1
  fi
  if [ "$pm" = "brew" ] && [ "$(id -u)" -eq 0 ]; then
    error "Homebrew refuses to run as root. Run this as your normal user."
    exit 1
  fi
  actioninfo "Updating the system with ${bold}$pm${normal}"
  case "$pm" in
    apt-get ) apt-get update && apt-get upgrade -y ;;
    dnf )     dnf upgrade --refresh -y ;;
    yum )     yum update -y ;;
    pacman )  pacman -Syu --noconfirm ;;
    zypper )  zypper --non-interactive refresh && zypper --non-interactive update ;;
    apk )     apk update && apk upgrade ;;
    brew )    brew update && brew upgrade ;;
  esac
  success "System updated with $pm"
}

#One dashboard row per app: a coloured up/stopped dot, container state,
#primary image and health. Read-only, and resilient to missing folders.
status_row() {
  sr_app=$1
  sr_dir=$(resolve_dir "$sr_app") || sr_dir=""
  sr_dot="$dim$DOT_OFF$normal"
  sr_state="stopped"
  sr_img="-"
  sr_health="-"
  if [ -z "$sr_dir" ]; then
    printf '%s %-18s %-9s %-30s %s\n' "$dim?$normal" "$sr_app" "?" "(no compose file)" "-"
    return 0
  fi
  sr_ids=$(cd "$sr_dir" && compose ps -q 2>/dev/null)
  if [ -n "$sr_ids" ]; then
    sr_total=0; sr_up=0; sr_unhealthy=0; sr_starting=0; sr_hchecks=0
    # shellcheck disable=SC2086 # ids are one-per-line without spaces
    for sr_id in $sr_ids; do
      sr_total=$((sr_total + 1))
      [ "$(docker inspect -f '{{.State.Status}}' "$sr_id" 2>/dev/null)" = "running" ] && sr_up=$((sr_up + 1))
      sr_h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$sr_id" 2>/dev/null)
      case "$sr_h" in
        healthy )   sr_hchecks=$((sr_hchecks + 1)) ;;
        unhealthy ) sr_hchecks=$((sr_hchecks + 1)); sr_unhealthy=$((sr_unhealthy + 1)) ;;
        starting )  sr_hchecks=$((sr_hchecks + 1)); sr_starting=$((sr_starting + 1)) ;;
      esac
      [ "$sr_img" = "-" ] && sr_img=$(docker inspect -f '{{.Config.Image}}' "$sr_id" 2>/dev/null)
    done
    if [ "$sr_up" -eq 0 ]; then
      sr_state="stopped"; sr_dot="$dim$DOT_OFF$normal"
    elif [ "$sr_up" -eq "$sr_total" ]; then
      sr_state="up"; sr_dot="$green$DOT_ON$normal"
    else
      sr_state="$sr_up/$sr_total up"; sr_dot="$yellow$DOT_ON$normal"
    fi
    if [ "$sr_unhealthy" -gt 0 ]; then
      sr_health="${red}unhealthy${normal}"
    elif [ "$sr_starting" -gt 0 ]; then
      sr_health="${yellow}starting${normal}"
    elif [ "$sr_hchecks" -gt 0 ]; then
      sr_health="${green}healthy${normal}"
    fi
  fi
  [ -z "$sr_img" ] && sr_img="-"
  sr_img=${sr_img%%,*}
  if [ "${#sr_img}" -gt 30 ]; then
    sr_img="$(printf '%.27s' "$sr_img")..."
  fi
  #dot (leading) and health (trailing) carry the only colour, so the padded
  #plain columns in between still line up.
  printf '%s %-18s %-9s %-30s %s\n' "$sr_dot" "$sr_app" "$sr_state" "$sr_img" "$sr_health"
}

show_status() {
  echo "${bold}${cyan}DockerDance${normal} status - $(pwd)"
  printf '  %-18s %-9s %-30s %s\n' "APP" "STATE" "IMAGE" "HEALTH"
  for ss_app in "$@"; do
    status_row "$ss_app"
  done
}

#Diagnostics: check the environment and configuration without changing anything.
run_doctor() {
  dok()   { echo "  ${green}[ok]${normal}   $1"; }
  dwarn() { echo "  ${yellow}[warn]${normal} $1"; }
  dbad()  { echo "  ${red}[FAIL]${normal} $1"; }
  echo "${bold}${cyan}DockerDance doctor${normal} - v$VERSION"
  echo "  script:      $0"
  echo "  working dir: $(pwd)"
  echo "  OS:          $(uname -s) $(uname -r)"
  echo "---"
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      dok "Docker daemon reachable ($(docker --version 2>/dev/null))"
    else
      dbad "Docker is installed but the daemon isn't reachable (start it, or add your user to the docker group)"
    fi
  else
    dbad "Docker not found in PATH - install it from $DOCKER_INSTALL_URL (any app command will also offer to run the installer)"
  fi
  if docker compose version >/dev/null 2>&1; then
    dok "Compose plugin: docker compose ($(docker compose version --short 2>/dev/null))"
  elif command -v docker-compose >/dev/null 2>&1; then
    dwarn "Using legacy docker-compose ($(docker-compose version --short 2>/dev/null))"
  else
    dbad "No 'docker compose' plugin or 'docker-compose' found"
  fi
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    dok "curl/wget present (needed for update-self and NOTIFY_WEBHOOK)"
  else
    dwarn "Neither curl nor wget found - update-self and webhooks won't work"
  fi
  if command -v fzf >/dev/null 2>&1; then
    dok "fzf present (fuzzy app picker in the menu)"
  else
    dwarn "fzf not found - the menu falls back to a numbered list"
  fi
  dr_pm=""
  for dr_c in apt-get dnf yum pacman zypper apk brew; do
    command -v "$dr_c" >/dev/null 2>&1 && { dr_pm=$dr_c; break; }
  done
  if [ -n "$dr_pm" ]; then
    dok "Package manager for system-update: $dr_pm"
  else
    dwarn "No supported package manager found for system-update"
  fi
  if tar_is_busybox; then
    dwarn "tar is busybox - legacy absolute-path backups can't be restored on this host"
  else
    dok "tar supports safe extraction"
  fi
  if [ -d "$DOCKER_VOLUMES" ]; then
    if [ -w "$DOCKER_VOLUMES" ]; then
      dok "DOCKER_VOLUMES writable: $DOCKER_VOLUMES"
    else
      dwarn "DOCKER_VOLUMES not writable by this user: $DOCKER_VOLUMES"
    fi
  else
    dwarn "DOCKER_VOLUMES does not exist: $DOCKER_VOLUMES"
  fi
  if [ -f "./manage.conf" ]; then
    dok "manage.conf found and loaded"
  else
    echo "  manage.conf: not present (using script defaults / environment)"
  fi
  if [ -d "$LOCK_DIR" ]; then
    dwarn "A run lock exists ($LOCK_DIR) - another run is active, or it's stale (remove it if so)"
  else
    dok "No stale run lock"
  fi
  echo "---"
  echo "  settings: STOP_TIMEOUT=$STOP_TIMEOUT  HEALTH_TIMEOUT=$HEALTH_TIMEOUT  PARALLEL_PULLS=$PARALLEL_PULLS  BACKUP_KEEP=${BACKUP_KEEP:-unset}  NOTIFY_WEBHOOK=$([ -n "${NOTIFY_WEBHOOK:-}" ] && echo set || echo unset)"
  if [ "$Apps" = "auto" ] || [ -z "$Apps" ]; then
    dr_saved=$Apps
    discover_apps
    dr_found=$Apps
    Apps=$dr_saved
    if [ -n "$dr_found" ]; then
      dok "Apps=auto discovers:$dr_found"
    else
      dwarn "Apps=auto found no folders with a compose file here"
    fi
  else
    echo "  Apps (pinned): $Apps"
  fi
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
  status       Dashboard: each app's state, image and health at a glance
  logs         Show recent logs (follows the log when a single app is targeted)
  version      Show the image versions each app is using
  running      List running containers (docker ps)
  doctor       Check the environment and configuration (read-only)
  system-update  Update the host OS packages (detects apt/dnf/yum/pacman/zypper/apk/brew; 'apt' still works as an alias)
  update-self  Update this script to the latest GitHub release
  help         Show this help (--version shows the script version)

Options:
  --dry-run    Show what each command would do without touching anything
  -y, --yes    Don't prompt for confirmation (update / restore)
  --no-color   Disable coloured output

Commands run against every app in the Apps variable. The default, "auto",
discovers every folder here that contains a compose file. Pass one or more
folder names to target specific apps instead, e.g. ./manage.sh restart linkace
EOF
}

run_command() {
  menu_command=$1
  case "$menu_command" in
    'backup' | 'restore' | 'update' | 'stop' | 'start' | 'restart' | 'logs' | 'version' | 'status' ) maybe_discover_apps ;;
  esac
  # shellcheck disable=SC2086 # Apps is an intentionally space-separated list
  set -- $Apps
  RUN_START=$(date +%s)
  APP_TOTAL=$#
  APP_NUM=0
  SUMMARY=""
  case "$menu_command" in
    'backup' | 'update' | 'stop' | 'start' | 'restart' | 'restore' )
      [ -z "${DRY_RUN:-}" ] && acquire_lock ;;
  esac
  case "$menu_command" in
    'backup' )
      checkDefault
      require_docker
      NOTIFY_CONTEXT="Backup of $*"
      actioninfo "${bold}Backing up${normal} apps including:"
      list_apps "$@"
      parallel_pull "$@"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        if in_list "$app" "$PULL_FAILED"; then
          app_start=$(date +%s)
          warn "$(counter)Skipping $app (its pull failed)"
          record "$app" "skipped"
          continue
        fi
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
      if [ -z "${DRY_RUN:-}" ] && ! confirm "Update $# app(s)? This pulls new images and recreates their containers."; then
        echo "Cancelled."
        return 0
      fi
      NOTIFY_CONTEXT="Update of $*"
      actioninfo "${bold}Updating all services.${normal}"
      list_apps "$@"
      parallel_pull "$@"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        if in_list "$app" "$PULL_FAILED"; then
          app_start=$(date +%s)
          warn "$(counter)Skipping $app (its pull failed)"
          record "$app" "skipped"
          continue
        fi
        update_app "$app"
      done
      print_summary
      success "Services updated in $(elapsed)."
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
    'status' )
      checkDefault
      require_docker
      show_status "$@"
      ;;
    'doctor' )
      run_doctor
      ;;
    'running' )
      require_docker
      echo "Getting all running services"
      docker ps
      ;;
    'system-update' | 'apt' )
      system_update
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

#Commands offered in the interactive menu, and the ones that don't take an app.
MENU_COMMANDS="start stop restart update backup restore status logs version running system-update update-self doctor"
NO_APP_COMMANDS="status running doctor system-update update-self"

#Pick a command for the interactive menu. Sets PICKED_COMMAND ("" = reprompt,
#"quit" = leave). With fzf you get arrow-key navigation and type-to-filter and
#Esc to quit; otherwise a numbered menu that also accepts a typed command name.
pick_command() {
  PICKED_COMMAND=""
  if command -v fzf >/dev/null 2>&1; then
    # shellcheck disable=SC2086 # the command list is intentionally word-split
    PICKED_COMMAND=$(printf '%s\n' $MENU_COMMANDS quit \
      | fzf --prompt="DockerDance> " --reverse --height="~65%" \
            --header="up/down move | type to filter | Enter select | Esc quit") \
      || PICKED_COMMAND="quit"
    return 0
  fi
  echo ""
  echo "${bold}${cyan}DockerDance${normal} ${dim}v$VERSION${normal} - what would you like to do?"
  echo "   1) start     2) stop      3) restart       4) update"
  echo "   5) backup    6) restore   7) status        8) logs"
  echo "   9) version  10) running  11) doctor       12) system-update"
  echo "  13) update-self                             q) quit"
  echo "  ${dim}tip: install fzf for arrow-key navigation and filtering${normal}"
  printf "> "
  read -r choice || { PICKED_COMMAND="quit"; return 0; }
  case "$choice" in
    1 ) PICKED_COMMAND="start" ;;
    2 ) PICKED_COMMAND="stop" ;;
    3 ) PICKED_COMMAND="restart" ;;
    4 ) PICKED_COMMAND="update" ;;
    5 ) PICKED_COMMAND="backup" ;;
    6 ) PICKED_COMMAND="restore" ;;
    7 ) PICKED_COMMAND="status" ;;
    8 ) PICKED_COMMAND="logs" ;;
    9 ) PICKED_COMMAND="version" ;;
    10 ) PICKED_COMMAND="running" ;;
    11 ) PICKED_COMMAND="doctor" ;;
    12 ) PICKED_COMMAND="system-update" ;;
    13 ) PICKED_COMMAND="update-self" ;;
    q | Q | quit | exit ) PICKED_COMMAND="quit" ;;
    start | stop | restart | update | backup | restore | status | logs | version | running | doctor | system-update | update-self ) PICKED_COMMAND="$choice" ;;
    * ) echo "Not a valid choice." ;;
  esac
}

pick_app() {
  #Sets PICKED_APPS to a space-separated list of chosen apps, or "" for all
  #apps. Returns 1 if the user cancelled or picked nothing valid.
  PICKED_APPS=""
  if command -v fzf >/dev/null 2>&1; then
    #The preview pane shows live container status for the highlighted app
    fzf_preview='if [ {} = "all apps" ]; then docker ps; else (cd {} && '"$DOCKER_COMPOSE_COMMAND"' ps) 2>/dev/null || echo "(no status)"; fi'
    pa_sel=$(printf '%s\n' "all apps" "$@" | fzf --multi --prompt="apps> " --header="TAB multi-select | Enter confirm | Esc to go back" --preview "$fzf_preview") || return 1
    #'all apps' anywhere in the selection means everything
    if printf '%s\n' "$pa_sel" | grep -qx "all apps"; then
      PICKED_APPS=""
    else
      PICKED_APPS=$(printf '%s' "$pa_sel" | tr '\n' ' ')
      PICKED_APPS=${PICKED_APPS% }
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
  echo "  b) back"
  printf "Select app(s) [0-%s, space/comma separated, or b to go back]: " "$n"
  read -r selection || return 1
  case "$selection" in
    b | B | back ) return 1 ;;
  esac
  selection=$(printf '%s' "$selection" | tr ',' ' ')
  pa_out=""
  # shellcheck disable=SC2086 # selection is an intentionally space-separated list
  for sel in $selection; do
    if [ "$sel" = "0" ]; then
      PICKED_APPS=""
      return 0
    fi
    n=0
    hit=""
    for app in "$@"; do
      n=$((n + 1))
      if [ "$n" = "$sel" ]; then
        hit=$app
        break
      fi
    done
    if [ -z "$hit" ]; then
      echo "Not a valid selection: $sel"
      return 1
    fi
    pa_out="$pa_out $hit"
  done
  if [ -z "$pa_out" ]; then
    echo "Nothing selected."
    return 1
  fi
  PICKED_APPS=${pa_out# }
  return 0
}

interactive() {
  checkDefault
  require_docker
  maybe_discover_apps
  ALL_APPS=$Apps
  while :; do
    pick_command
    choice=$PICKED_COMMAND
    [ -z "$choice" ] && continue
    [ "$choice" = "quit" ] && break
    Apps=$ALL_APPS
    #Commands that act on everything (or nothing) skip the app picker; the rest
    #let you pick app(s), where Esc (fzf) or 'b' (numbered) goes back to here.
    case " $NO_APP_COMMANDS " in
      *" $choice "* ) : ;;
      * )
        # shellcheck disable=SC2086 # Apps is an intentionally space-separated list
        pick_app $Apps || continue
        if [ -n "$PICKED_APPS" ]; then
          Apps=$PICKED_APPS
        fi
        ;;
    esac
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

#Pull global options out of the arguments (they may appear before or after the
#command); everything else stays as the command and its app names.
ASSUME_YES=""
DRY_RUN=""
positional=""
for arg in "$@"; do
  case "$arg" in
    -y | --yes ) ASSUME_YES=1 ;;
    --dry-run ) DRY_RUN=1 ;;
    --no-color ) bold=""; normal=""; red=""; green=""; yellow=""; cyan=""; dim="" ;;
    * ) positional="$positional $arg" ;;
  esac
done
# shellcheck disable=SC2086 # app names are space-separated with no embedded spaces
set -- $positional

APPS_OVERRIDDEN=0
if [ $# -eq 0 ]; then
  if [ -t 0 ] && [ -z "$DRY_RUN" ]; then
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
