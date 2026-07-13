# shellcheck shell=bash
# Bash completion for DockerDance's manage.sh
# Install: source this file from ~/.bashrc, pointing at wherever you placed it, e.g.
#   echo "source /path/to/DockerDance/contrib/dockerdance-completion.bash" >> ~/.bashrc
# Completes commands first, then app folder names in the current directory.

_dockerdance() {
  local cur commands flags
  cur=${COMP_WORDS[COMP_CWORD]}
  commands="start stop restart update backup restore status logs version running doctor system-update update-self help"
  flags="--dry-run --yes --no-color --version --help"
  if [[ "$cur" == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$flags" -- "$cur")
  elif [ "$COMP_CWORD" -eq 1 ]; then
    mapfile -t COMPREPLY < <(compgen -W "$commands" -- "$cur")
  else
    # App folders live alongside manage.sh; skip the backup folder itself
    mapfile -t COMPREPLY < <(compgen -d -X 'backup' -- "$cur")
  fi
}

complete -F _dockerdance manage.sh ./manage.sh appmanage
