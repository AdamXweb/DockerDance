#!/bin/sh
set -e

VERSION="0.4.0"
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

#All scratch files live in one owner-only (0700) directory, so no other user
#can pre-create, replace or even see them. A single mktemp'd *file* wasn't
#enough: the interactive menu deletes it after each command, freeing a name
#another user had already seen - a symlink planted there would then have a
#root-run step truncate whatever it pointed at.
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dockerdance.XXXXXX" 2>/dev/null) || {
  RUN_DIR="${TMPDIR:-/tmp}/dockerdance.$$"
  #No -p: if this predictable name already exists it isn't ours - stop.
  mkdir -m 700 "$RUN_DIR" || { echo "Couldn't create a private temp dir at $RUN_DIR" >&2; exit 1; }
}
STEP_LOG="$RUN_DIR/step.log"
#One state-changing run at a time per docker_volumes folder. The lock lives
#in the (user-owned) folder being managed itself, not world-writable /tmp,
#where any other local user could squat the predictable name and lock us out
#for good. The pid inside lets a crashed run's lock clear itself.
LOCK_DIR="$(pwd)/.dockerdance.lock"
HAVE_LOCK=""
NOTIFY_CONTEXT=""
#Set (only) by the interactive menu's per-command subshell: its cleanup must
#release the lock and restore the cursor, but the run dir belongs to the
#session and has to survive into the next menu command.
RUN_DIR_KEEP=""
cleanup() {
  cleanup_status=$?
  tput cnorm 2>/dev/null || true
  rm -f "$STEP_LOG"
  [ -z "$RUN_DIR_KEEP" ] && rm -rf "$RUN_DIR"
  if [ -n "$HAVE_LOCK" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
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
hint() {
  echo "${bold}${cyan}[hint]${normal} - $1" >&2
}

#Docker's failures can be cryptic. Where the cause is recognisable, add one
#line saying what to do about it. Anything unrecognised gets no hint - the
#command's own output above is always the source of truth.
explain_failure() {
  [ -s "$1" ] || return 0
  if grep -q 'no matching manifest for' "$1"; then
    hint "that image has no build for this machine ($(uname -m)) - check which platforms the image publishes, or pin a tag that covers yours"
  elif grep -q ': is a directory' "$1"; then
    hint "something the compose file reads is a directory where a file was expected - a *folder* named compose.yaml/compose.yml beside the real compose file will do this"
  elif grep -q 'mount source path' "$1" && grep -q 'permission denied' "$1"; then
    hint "docker couldn't create or reach a bind-mount path on the host - check those volume paths exist and are readable (an external or network drive has to be mounted first)"
  elif grep -q 'port is already allocated\|address already in use' "$1"; then
    hint "another container or process already holds that port - free it, or change the published port in the compose file"
  elif grep -q 'manifest unknown\|not found: manifest\|repository does not exist\|pull access denied\|unauthorized' "$1"; then
    hint "the image or tag doesn't exist, or it's private - check the name and tag, and 'docker login' first for a private registry"
  elif grep -q 'no space left on device' "$1"; then
    hint "the disk is full - 'docker system df' shows what's using it"
  fi
  return 0
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
  step_status=0
  if [ -z "$SPINNER" ]; then
    #No terminal: capture rather than stream, so a failure gets the same
    #labelled report and hint it would get on a terminal
    echo "$step_label"
    "$@" >"$STEP_LOG" 2>&1 || step_status=$?
    #Success still shows what the command said, keeping cron logs detailed;
    #a failure is printed by the shared branch below instead
    [ "$step_status" -eq 0 ] && [ -s "$STEP_LOG" ] && sed 's/^/    /' "$STEP_LOG"
  else
    "$@" >"$STEP_LOG" 2>&1 &
    step_pid=$!
    tput civis 2>/dev/null || true
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
  fi
  if [ "$step_status" -ne 0 ]; then
    error "$step_label failed:"
    [ -s "$STEP_LOG" ] && sed 's/^/    /' "$STEP_LOG" >&2
    explain_failure "$STEP_LOG"
    rm -f "$STEP_LOG"
    return "$step_status"
  fi
  rm -f "$STEP_LOG"
  return 0
}

acquire_lock() {
  [ -n "$HAVE_LOCK" ] && return 0
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    #A lock whose recorded process is gone is left over from a crash or a
    #reboot - clear it and try once more. (kill -0 can't tell a foreign
    #user's live process from a dead one, but the lock sits inside this
    #user's own docker_volumes folder, so that ambiguity doesn't arise.)
    al_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$al_pid" ] && ! kill -0 "$al_pid" 2>/dev/null; then
      warn "Clearing a stale lock left by exited run (pid $al_pid)"
      rm -rf "$LOCK_DIR"
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      error "Another manage.sh run is active here (lock: $LOCK_DIR, pid ${al_pid:-unknown})."
      exit 1
    fi
  fi
  echo "$$" >"$LOCK_DIR/pid"
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

#Returns non-zero rather than exiting, so one unusable app folder is reported
#and skipped instead of ending a run over the other apps.
enter_app() {
  APP_RETURN_DIR=$(pwd)
  if [ ! -d "$1" ]; then
    error "No folder named '$1' here. Run this from the docker_volumes folder and check the Apps variable / arguments."
    return 1
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
  leave_app
  return 1
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

#What update/backup do with an app that is already stopped:
#  keep  - bring its new image down but leave the app stopped (the default:
#          an app you deliberately stopped shouldn't come back up on its own)
#  start - update it and start it, so everything ends up running
#  skip  - don't touch it at all, not even a pull
#Set when the choice came from --stopped, manage.conf or the environment, so
#the interactive prompt doesn't second-guess a preference already expressed
STOPPED_SET=""
[ -n "${STOPPED_POLICY:-}" ] && STOPPED_SET=1
STOPPED_POLICY="${STOPPED_POLICY:-keep}"
valid_stopped_policy() {
  case "$1" in
    keep | start | skip ) return 0 ;;
    * ) return 1 ;;
  esac
}

#Every running container id, fetched once so the state scan below costs one
#docker call plus a compose ps per app, rather than an inspect per container.
RUNNING_IDS=""
load_running_ids() {
  RUNNING_IDS=$(docker ps -q --no-trunc 2>/dev/null || true)
}

#True when at least one of the app's containers is running right now
app_is_up() {
  ai_dir=$(resolve_dir "$1") || return 1
  ai_ids=$(cd "$ai_dir" && compose ps -q 2>/dev/null) || return 1
  [ -n "$ai_ids" ] || return 1
  # shellcheck disable=SC2086 # ids are one per line with no spaces
  for ai_id in $ai_ids; do
    printf '%s\n' "$RUNNING_IDS" | grep -qx "$ai_id" && return 0
  done
  return 1
}

#Split the apps into APPS_UP / APPS_DOWN before anything is changed, so the
#run can put each one back the way it found it.
APPS_UP=""
APPS_DOWN=""
scan_state() {
  APPS_UP=""
  APPS_DOWN=""
  #Read-only, so it runs for --dry-run too and reports the real state
  load_running_ids
  for sc_app in "$@"; do
    if app_is_up "$sc_app"; then
      APPS_UP="$APPS_UP $sc_app"
    else
      APPS_DOWN="$APPS_DOWN $sc_app"
    fi
  done
  APPS_UP=${APPS_UP# }
  APPS_DOWN=${APPS_DOWN# }
}

#Show what's running before anything is touched - the state half of "see the
#state, then put it back".
print_state() {
  count_list "$APPS_UP";   ps_up=$COUNTED
  count_list "$APPS_DOWN"; ps_down=$COUNTED
  [ "$ps_up" -gt 0 ]   && echo "  ${green}${DOT_ON}${normal} $ps_up running: $(join_list "$APPS_UP")"
  [ "$ps_down" -gt 0 ] && echo "  ${dim}${DOT_OFF}${normal} $ps_down stopped: $(join_list "$APPS_DOWN")"
  return 0
}

#Settle what happens to any stopped apps and, for commands that ask before
#acting, confirm the run - one prompt does both jobs. $1 is the verb, $2 the
#explanation for the plain y/N form, $3 is "always" to confirm even when
#nothing is stopped (update does; backup never has), then the apps. Returns
#non-zero if the user backs out. Without a terminal (or with -y / --stopped)
#STOPPED_POLICY is taken as given and nothing is asked.
confirm_run() {
  cr_verb=$1
  cr_detail=$2
  cr_always=$3
  shift 3
  count_list "$APPS_DOWN"; cr_down=$COUNTED
  if [ "$cr_down" -eq 0 ]; then
    [ "$cr_always" = "always" ] || return 0
    confirm "$cr_verb $# app(s)? $cr_detail" || return 1
    return 0
  fi
  if [ -n "${ASSUME_YES:-}" ] || [ -n "$STOPPED_SET" ] || [ ! -t 0 ]; then
    return 0
  fi
  count_list "$APPS_UP"; cr_up=$COUNTED
  echo "$cr_verb $cr_up running app(s). The other $cr_down are stopped - what should happen to them?"
  echo "  1) leave them stopped, but pull so they're current next start ${dim}(recommended)${normal}"
  echo "  2) start them too, so everything ends up running"
  echo "  3) skip them entirely - no pull, no changes"
  echo "  n) cancel"
  printf 'Choose [1]: '
  read -r cr_ans || cr_ans=""
  case "$cr_ans" in
    '' | 1 | keep )  STOPPED_POLICY="keep" ;;
    2 | start )      STOPPED_POLICY="start" ;;
    3 | skip )       STOPPED_POLICY="skip" ;;
    * )              return 1 ;;
  esac
  return 0
}

#The apps worth pulling images for: everything, minus the stopped ones when
#the policy is to leave those completely alone.
pull_target_list() {
  pt_out=""
  for pt_app in "$@"; do
    if [ "$STOPPED_POLICY" = "skip" ] && in_list "$pt_app" "$APPS_DOWN"; then
      continue
    fi
    pt_out="$pt_out $pt_app"
  done
  printf '%s' "${pt_out# }"
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

#Seconds as "45s" or "3m 20s"
human_secs() {
  if [ "$1" -ge 60 ]; then
    printf '%dm %ds' $(($1 / 60)) $(($1 % 60))
  else
    printf '%ds' "$1"
  fi
}

RUN_START=""
elapsed() {
  [ -z "$RUN_START" ] && return 0
  human_secs $(( $(date +%s) - RUN_START ))
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
    case "$s_action" in
      failed )  s_mark="$red$DOT_OFF$normal" ;;
      skipped ) s_mark="$yellow$DOT_OFF$normal" ;;
      * )       s_mark="$green$DOT_ON$normal" ;;
    esac
    printf '  %s %s%-24s%s %-12s %s%4ss%s\n' "$s_mark" "$bold" "$s_app" "$normal" "$s_action" "$dim" "$s_secs" "$normal"
  done
}

#Apps that couldn't be completed this run. A broken app is reported and the
#run carries on through the rest - the closing tally and the exit status say
#what went wrong, rather than the run stopping dead on the first failure.
RUN_FAILED=""
RUN_SKIPPED=""
RUN_KEPT=""
RUN_RESULT=""
#$2 is the step that failed, used for the summary row
fail_app() {
  RUN_FAILED="$RUN_FAILED $1"
  record "$1" "failed"
  #The app function returns as soon as a step fails, so put the shell back in
  #the docker_volumes folder for the next app
  leave_app
  return 0
}
skip_app() {
  RUN_SKIPPED="$RUN_SKIPPED $1"
  app_start=$(date +%s)
  warn "$(counter)Skipping $1 ($2)"
  record "$1" "skipped"
  return 0
}

#The app was already stopped and the policy is to leave it that way. Its new
#image has been pulled, and compose recreates a stopped container on the new
#image the next time the app is started, so there's nothing else to do.
keep_stopped_app() {
  RUN_KEPT="$RUN_KEPT $1"
  app_start=$(date +%s)
  if [ -n "${DRY_RUN:-}" ]; then
    echo "${dim}[dry-run]${normal} would leave ${bold}$1${normal} stopped, with its new image pulled and ready"
  else
    ok "$(counter)$1 left stopped - new image ready for its next start"
  fi
  record "$1" "image ready"
  return 0
}

#Count the words in a space-separated list into COUNTED
COUNTED=0
count_list() {
  COUNTED=0
  # shellcheck disable=SC2086,SC2034 # a space-separated list; the loop counts, it doesn't read cl_x
  for cl_x in $1; do
    COUNTED=$((COUNTED + 1))
  done
}

#Space-separated list to "a, b, c" for reading
join_list() {
  jl_out=""
  # shellcheck disable=SC2086 # $1 is an intentionally space-separated list
  for jl_x in $1; do
    jl_out="${jl_out:+$jl_out, }$jl_x"
  done
  printf '%s' "$jl_out"
}

#Closing report for a run: the per-app table, then a plain-language tally of
#how many apps actually made it. Returns non-zero when anything failed or was
#skipped, so cron and scripts can tell without reading the output. $1 is the
#past-tense verb ("Updated"), $2 an optional note shown when all went well.
finish_run() {
  print_summary
  count_list "$RUN_FAILED";  fr_failed=$COUNTED
  count_list "$RUN_SKIPPED"; fr_skipped=$COUNTED
  count_list "$RUN_KEPT";    fr_kept=$COUNTED
  #Apps left stopped on purpose were handled as asked, so they count as done
  fr_done=$((APP_TOTAL - fr_failed - fr_skipped))
  fr_word="apps"
  [ "$APP_TOTAL" -eq 1 ] && fr_word="app"
  fr_kept_note=""
  [ "$fr_kept" -gt 0 ] && fr_kept_note=" ($fr_kept left stopped)"
  if [ "$fr_failed" -eq 0 ] && [ "$fr_skipped" -eq 0 ]; then
    if [ "$APP_TOTAL" -eq 1 ]; then
      RUN_RESULT="$1 1 app in $(elapsed)$fr_kept_note"
    else
      RUN_RESULT="$1 all $APP_TOTAL apps in $(elapsed)$fr_kept_note"
    fi
    success "$RUN_RESULT.${2:+ $2}"
    return 0
  fi
  fr_note=""
  [ "$fr_failed" -gt 0 ]  && fr_note="$fr_failed failed"
  [ "$fr_skipped" -gt 0 ] && fr_note="${fr_note:+$fr_note, }$fr_skipped skipped"
  RUN_RESULT="$1 $fr_done of $APP_TOTAL $fr_word in $(elapsed) - $fr_note$fr_kept_note"
  warn "$RUN_RESULT"
  [ "$fr_failed" -gt 0 ]  && echo "  ${red}failed:${normal}  $(join_list "$RUN_FAILED")" >&2
  [ "$fr_skipped" -gt 0 ] && echo "  ${yellow}skipped:${normal} $(join_list "$RUN_SKIPPED")" >&2
  return 1
}

list_apps() {
  for app in "$@"; do
    echo "$cyan$ARROW$normal $app"
  done
  echo "---"
}

#How many image pulls to run at once (nala-style). 1 makes pulls sequential.
PARALLEL_PULLS="${PARALLEL_PULLS:-3}"
#0, a negative or a typo would leave the orchestrator with no slot it can ever
#fill, so fall back to the default rather than spinning forever
[ "$PARALLEL_PULLS" -ge 1 ] 2>/dev/null || PARALLEL_PULLS=3

#Pull one app's images quietly - used by the parallel orchestrator, where
#interleaved progress bars would be unreadable. Writes an event line when it's
#done and then drops its slot marker, so the foreground can report progress
#instead of sitting behind a bare spinner for the whole phase. The marker is
#created by the orchestrator before the fork, so slot accounting can't race.
_pull_one() {
  po_app=$1
  po_start=$(date +%s)
  if ( enter_app "$po_app" && compose pull --quiet ) >"$pp_dir/$po_app.log" 2>&1; then
    po_state="pulled"
  else
    po_state="failed"
    echo "$po_app" >>"$pp_dir/failed"
  fi
  echo "$po_app|$po_state|$(( $(date +%s) - po_start ))" >>"$pp_dir/events"
  rm -f "$pp_dir/active.$po_app"
}

#Count the pulls in flight into PULL_BUSY. A plain glob rather than a $(...)
#so the polling loop below doesn't fork on every pass.
PULL_BUSY=0
_pull_count_active() {
  PULL_BUSY=0
  for pc_f in "$pp_dir"/active.*; do
    [ -e "$pc_f" ] || continue
    PULL_BUSY=$((PULL_BUSY + 1))
  done
}

#Keep PARALLEL_PULLS pulls in flight: start a new app the moment any one
#finishes, rather than waiting for a whole batch. `wait -n` would do this
#directly but isn't POSIX, so slots are tracked with the marker files and
#polled - a pull runs for seconds at least, so half a second of slack costs
#nothing next to leaving a download slot idle.
_pull_orchestrate() {
  while [ $# -gt 0 ]; do
    _pull_count_active
    while [ $# -gt 0 ] && [ "$PULL_BUSY" -lt "$PARALLEL_PULLS" ]; do
      : >"$pp_dir/active.$1"
      PULL_BUSY=$((PULL_BUSY + 1))
      _pull_one "$1" &
      shift
    done
    [ $# -gt 0 ] && { sleep 0.5 2>/dev/null || sleep 1; }
  done
  wait
}

#The apps whose pull is in flight right now, as a readable list
_pull_active() {
  pa_list=""
  for pa_f in "$pp_dir"/active.*; do
    [ -e "$pa_f" ] || continue
    pa_name=${pa_f##*/active.}
    if [ -z "$pa_list" ]; then pa_list=$pa_name; else pa_list="$pa_list, $pa_name"; fi
  done
  printf '%s' "$pa_list"
}

#Print a line for every pull that has finished since the last call. Called from
#the foreground while the orchestrator runs, so a long pull phase scrolls a
#record of what landed rather than showing nothing until it's all over.
pp_seen=0
_pull_drain() {
  [ -s "$pp_dir/events" ] || return 0
  pd_new=$(tail -n +"$((pp_seen + 1))" "$pp_dir/events" 2>/dev/null) || pd_new=""
  [ -z "$pd_new" ] && return 0
  pp_seen=$(( pp_seen + $(printf '%s\n' "$pd_new" | wc -l) ))
  #wipe the spinner line so the results land on a clean row
  [ -n "$SPINNER" ] && { printf '\r'; tput el 2>/dev/null || printf '%-79s\r' ''; }
  printf '%s\n' "$pd_new" | while IFS='|' read -r pd_app pd_state pd_secs; do
    [ -z "$pd_app" ] && continue
    if [ "$pd_state" = "pulled" ]; then
      printf '  %s%s%s %s%-24s%s %spulled in %s%s\n' "$green" "$DOT_ON" "$normal" \
        "$bold" "$pd_app" "$normal" "$dim" "$(human_secs "$pd_secs")" "$normal"
    else
      printf '  %s%s%s %s%-24s%s %sfailed after %s%s\n' "$red" "$DOT_OFF" "$normal" \
        "$bold" "$pd_app" "$normal" "$dim" "$(human_secs "$pd_secs")" "$normal"
    fi
  done
  return 0
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
  pp_seen=0
  pp_start=$(date +%s)
  pp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dockerdance-pull.XXXXXX" 2>/dev/null) || { pp_dir="${TMPDIR:-/tmp}/dockerdance-pull.$$"; mkdir -p "$pp_dir"; }
  : >"$pp_dir/failed"
  : >"$pp_dir/events"
  #Run the orchestrator in the background so one spinner can cover the phase.
  ( _pull_orchestrate "$@" ) >"$pp_dir/orch.log" 2>&1 &
  pp_orch=$!
  echo "Pulling images for $pp_total app(s), up to $PARALLEL_PULLS at a time"
  if [ -n "$SPINNER" ]; then
    #Pad the status to the terminal width so a shrinking app list leaves no debris
    pp_w=$(tput cols 2>/dev/null || echo 80)
    [ "$pp_w" -ge 24 ] 2>/dev/null || pp_w=80
    pp_w=$((pp_w - 4))
    tput civis 2>/dev/null || true
    pp_tick=0
    pp_status="starting"
    while kill -0 "$pp_orch" 2>/dev/null; do
      # shellcheck disable=SC2086 # frames are an intentionally space-separated list
      for pp_frame in $SPINNER_FRAMES; do
        kill -0 "$pp_orch" 2>/dev/null || break
        #Refresh the wording about once a second; the frames spin ten times faster
        if [ "$pp_tick" -le 0 ]; then
          _pull_drain
          pp_busy=$(_pull_active)
          [ -z "$pp_busy" ] && pp_busy="starting"
          pp_status="[$pp_seen/$pp_total] pulling $pp_busy"
          pp_tick=10
        fi
        pp_tick=$((pp_tick - 1))
        # shellcheck disable=SC2059 # the width is computed, the rest of the format is fixed
        printf "\r%s%s%s %-${pp_w}.${pp_w}s" "$cyan" "$pp_frame" "$normal" "$pp_status"
        sleep 0.1 2>/dev/null || sleep 1
      done
    done
    printf '\r'
    tput el 2>/dev/null || printf '%-79s\r' ''
    tput cnorm 2>/dev/null || true
    wait "$pp_orch" || true
  else
    #No terminal (cron, pipes): still report each pull as it lands
    while kill -0 "$pp_orch" 2>/dev/null; do
      _pull_drain
      sleep 1
    done
    wait "$pp_orch" || true
  fi
  _pull_drain
  PULL_FAILED=$(tr '\n' ' ' <"$pp_dir/failed")
  PULL_FAILED=${PULL_FAILED% }
  pp_fails=0
  for pp_app in $PULL_FAILED; do
    pp_fails=$((pp_fails + 1))
    warn "Pull failed for $pp_app - leaving it on its current image"
    [ -s "$pp_dir/$pp_app.log" ] && sed 's/^/    /' "$pp_dir/$pp_app.log" >&2
    explain_failure "$pp_dir/$pp_app.log"
  done
  pp_took=$(human_secs $(( $(date +%s) - pp_start )))
  if [ "$pp_fails" -gt 0 ]; then
    warn "Pulled $((pp_total - pp_fails)) of $pp_total app(s) in $pp_took - $pp_fails failed: $(join_list "$PULL_FAILED")"
  else
    ok "Pulled images for $pp_total app(s) in $pp_took"
  fi
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

#Each step is guarded rather than left to `set -e`: a failure returns here so
#the caller can record this app and move on to the next one.
start_app() {
  app_start=$(date +%s)
  enter_app "$1" || return 1
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d || return 1
  wait_healthy "$1" "started"
  record "$1" "started"
  leave_app
}

stop_app() {
  app_start=$(date +%s)
  enter_app "$1" || return 1
  #stop (not kill) shuts containers down gracefully so databases can finish writing
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT" || return 1
  ok "$(counter)$1 stopped"
  record "$1" "stopped"
  leave_app
}

restart_app() {
  app_start=$(date +%s)
  enter_app "$1" || return 1
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT" || return 1
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d || return 1
  wait_healthy "$1" "restarted"
  record "$1" "restarted"
  leave_app
}

#Images are pulled up front (in parallel) by the caller, so this just cycles
#the app onto the new image with minimal downtime.
update_app() {
  app_start=$(date +%s)
  enter_app "$1" || return 1
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT" || return 1
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d || return 1
  wait_healthy "$1" "updated and running"
  record "$1" "updated"
  leave_app
}

#Images are pulled up front (in parallel) by the caller; this stops, archives
#and starts the app back on the new image.
backup_app() {
  app_start=$(date +%s)
  enter_app "$1" || return 1
  #An app that was already stopped is archived where it lies and left that way
  #(unless the policy says to start everything), so a backup doesn't quietly
  #bring up something that was deliberately down.
  was_up=0
  if in_list "$1" "$APPS_UP" || [ "$STOPPED_POLICY" = "start" ]; then
    was_up=1
  fi
  if [ "$was_up" -eq 1 ] && in_list "$1" "$APPS_UP"; then
    run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT" || return 1
  fi
  archive="${TARGET}${1}_$(date '+%Y-%m-%d').tar.bz2"
  if [ -z "${DRY_RUN:-}" ]; then
    mkdir -p "$TARGET"
    if [ -e "$archive" ]; then
      warn "${archive##*/} already exists - keeping it and adding a timestamp to this one"
      archive="${TARGET}${1}_$(date '+%Y-%m-%d_%H%M%S').tar.bz2"
    fi
  fi
  #Relative paths inside the archive make restores portable; 600 keeps the
  #.env secrets inside it private
  archive_status=0
  run_step "$(counter)Backing up ${bold}$1${normal}" tar -C "$DOCKER_VOLUMES" -cjf "$archive" "$1" || archive_status=1
  if [ "$archive_status" -eq 0 ] && [ -z "${DRY_RUN:-}" ]; then
    chmod 600 "$archive"
    if [ -n "${BACKUP_KEEP:-}" ]; then
      list_archives "$1" | tail -n +"$((BACKUP_KEEP + 1))" | while IFS= read -r old_backup; do
        rm -f "$old_backup"
        warn "Pruned old backup ${old_backup##*/} (BACKUP_KEEP=$BACKUP_KEEP)"
      done
    fi
  fi
  #Put the app back the way it was found. Starting happens even when the
  #archive failed - a bad backup mustn't leave a running app stopped.
  if [ "$was_up" -eq 1 ]; then
    run_step "$(counter)Starting ${bold}$1${normal}" compose up -d || return 1
  fi
  if [ "$archive_status" -ne 0 ]; then
    rm -f "$archive"
    warn "$(counter)$1 is back as it was, but it has no new backup"
    return 1
  fi
  if [ "$was_up" -eq 1 ]; then
    wait_healthy "$1" "backed up, updated and running"
    record "$1" "backed up"
  else
    #wait_healthy would normally carry this line, but there's nothing to wait for
    [ -z "${DRY_RUN:-}" ] && ok "$(counter)$1 backed up, left stopped"
    RUN_KEPT="$RUN_KEPT $1"
    record "$1" "backed up"
  fi
  leave_app
}

#Newest-first list of $1's own backup archives. The name after the app part
#must be exactly a date (with an optional _HHMMSS), in either the current
#'app_YYYY-MM-DD' form or the pre-0.4.1 'appYYYY-MM-DD' form - so an app
#whose name extends another's (vault / vault2) never matches its neighbour's
#archives. A bare glob did, which let BACKUP_KEEP prune the wrong app's
#backups and restore pick the wrong archive.
list_archives() {
  # shellcheck disable=SC2012 # archive names are script-generated (no newlines); ls -t sorts newest first
  ls -1t "${TARGET}${1}"*.tar.bz2 2>/dev/null | while IFS= read -r la_f; do
    la_s=${la_f##*/}
    la_s=${la_s#"$1"}
    case "$la_s" in
      _[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].tar.bz2 | \
      _[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].tar.bz2 | \
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].tar.bz2 | \
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].tar.bz2 )
        printf '%s\n' "$la_f" ;;
    esac
  done
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
  archive=$(list_archives "$1" | head -1)
  if [ -z "$archive" ]; then
    error "No backups found for '$1' in $TARGET"
    return 1
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
      return 1 ;;
  esac
  #Legacy absolute archives rely on GNU/bsdtar stripping the leading '/';
  #busybox tar does not, so refuse that one combination rather than risk a
  #write outside the staging dir.
  if [ "$layout" = "legacy" ] && tar_is_busybox; then
    error "${archive##*/} is a legacy absolute-path backup and your tar is busybox, which can't extract it safely. Restore it on a host with GNU tar."
    return 1
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
    return 1
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
        * ) skip_app "$1" "you declined"; return 0 ;;
      esac
    else
      error "restore needs a terminal to confirm (or pass --yes). Run it interactively."
      exit 1
    fi
  fi

  enter_app "$1" || return 1
  run_step "$(counter)Stopping ${bold}$1${normal}" compose stop -t "$STOP_TIMEOUT" || return 1
  leave_app

  #Stage under backup/ (same filesystem as the app folders, so the promote is
  #an atomic rename) and extract there - never onto the host root.
  mkdir -p "$TARGET"
  staging=$(mktemp -d "${TARGET}restore.XXXXXX") || { error "Couldn't create a staging dir in $TARGET"; return 1; }
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
    return 1
  fi
  mv "$staging/$1" "${DOCKER_VOLUMES}${1}"
  rm -rf "$staging"

  enter_app "$1" || return 1
  run_step "$(counter)Starting ${bold}$1${normal}" compose up -d || return 1
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
    dr_lockpid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$dr_lockpid" ] && kill -0 "$dr_lockpid" 2>/dev/null; then
      dwarn "A run lock is held by an active run (pid $dr_lockpid)"
    else
      dwarn "A stale run lock exists ($LOCK_DIR) - the next state-changing command will clear it"
    fi
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
  --stopped=X  What update/backup do with apps that are already stopped:
               keep (default) leaves them stopped with their new image ready,
               start brings them up too, skip leaves them entirely alone
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
  RUN_FAILED=""
  RUN_SKIPPED=""
  RUN_KEPT=""
  RUN_RESULT=""
  run_status=0
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
      scan_state "$@"
      print_state
      if [ -z "${DRY_RUN:-}" ] && ! confirm_run "Back up" "" stopped-only "$@"; then
        echo "Cancelled."
        return 0
      fi
      pull_targets=$(pull_target_list "$@")
      # shellcheck disable=SC2086 # app names are space-separated with no embedded spaces
      parallel_pull $pull_targets
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        if [ "$STOPPED_POLICY" = "skip" ] && in_list "$app" "$APPS_DOWN"; then
          skip_app "$app" "it's stopped"
          continue
        fi
        if in_list "$app" "$PULL_FAILED"; then
          skip_app "$app" "its pull failed"
          continue
        fi
        backup_app "$app" || fail_app "$app"
      done
      finish_run "Backed up" || run_status=1
      notify "Backup of $*: $RUN_RESULT"
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
        restore_app "$app" || fail_app "$app"
      done
      finish_run "Restored" || run_status=1
      notify "Restore of $*: $RUN_RESULT"
      NOTIFY_CONTEXT=""
      ;;
    'logs' )
      checkDefault
      require_docker
      if [ $# -eq 1 ]; then
        echo "Following ${bold}$1${normal} logs (Ctrl-C to stop)"
        enter_app "$1" || return 1
        compose logs -f
        leave_app
      else
        for app in "$@"; do
          echo "Getting ${bold}$app${normal} logs"
          enter_app "$app" || continue
          compose logs --tail=20
          leave_app
        done
      fi
      ;;
    'update' )
      checkDefault
      require_docker
      NOTIFY_CONTEXT="Update of $*"
      actioninfo "${bold}Updating${normal} apps:"
      list_apps "$@"
      scan_state "$@"
      print_state
      if [ -z "${DRY_RUN:-}" ] && ! confirm_run "Update" "This pulls new images and recreates their containers." always "$@"; then
        echo "Cancelled."
        return 0
      fi
      pull_targets=$(pull_target_list "$@")
      # shellcheck disable=SC2086 # app names are space-separated with no embedded spaces
      parallel_pull $pull_targets
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        if [ "$STOPPED_POLICY" = "skip" ] && in_list "$app" "$APPS_DOWN"; then
          skip_app "$app" "it's stopped"
          continue
        fi
        if in_list "$app" "$PULL_FAILED"; then
          skip_app "$app" "its pull failed"
          continue
        fi
        if [ "$STOPPED_POLICY" = "keep" ] && in_list "$app" "$APPS_DOWN"; then
          keep_stopped_app "$app"
          continue
        fi
        update_app "$app" || fail_app "$app"
      done
      finish_run "Updated" || run_status=1
      notify "Update of $*: $RUN_RESULT"
      NOTIFY_CONTEXT=""
      ;;
    'stop' )
      checkDefault
      require_docker
      actioninfo "${bold}Stopping${normal} all services:"
      list_apps "$@"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        stop_app "$app" || fail_app "$app"
      done
      finish_run "Stopped" || run_status=1
      ;;
    'start' )
      checkDefault
      require_docker
      actioninfo "${bold}Starting${normal} all services"
      list_apps "$@"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        start_app "$app" || fail_app "$app"
      done
      finish_run "Started" "Give them a moment to warm up." || run_status=1
      ;;
    'restart' )
      checkDefault
      require_docker
      actioninfo "${bold}Restarting${normal} all services"
      for app in "$@"; do
        APP_NUM=$((APP_NUM + 1))
        restart_app "$app" || fail_app "$app"
      done
      finish_run "Restarted" "Give them a moment to warm up." || run_status=1
      ;;
    'version' )
      checkDefault
      require_docker
      for app in "$@"; do
        echo "Getting ${bold}$app${normal} version"
        enter_app "$app" || continue
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
  #Non-zero when any app failed or was skipped, so cron and scripts can tell
  #without parsing the output
  return "$run_status"
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
    ( set -e; RUN_DIR_KEEP=1; trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; run_command "$choice" )
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
    --stopped=* ) STOPPED_POLICY=${arg#--stopped=}; STOPPED_SET=1 ;;
    --no-color ) bold=""; normal=""; red=""; green=""; yellow=""; cyan=""; dim="" ;;
    * ) positional="$positional $arg" ;;
  esac
done
if ! valid_stopped_policy "$STOPPED_POLICY"; then
  error "--stopped must be one of: keep, start, skip (got '$STOPPED_POLICY')"
  exit 1
fi
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
