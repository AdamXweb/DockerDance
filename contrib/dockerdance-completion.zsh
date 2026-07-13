#compdef manage.sh appmanage
# Zsh completion for DockerDance's manage.sh.
# Install: copy this file to a directory on your $fpath named "_manage.sh"
# (e.g. ~/.zsh/completions/_manage.sh) and make sure that directory is added
# before compinit runs in ~/.zshrc:
#   fpath=(~/.zsh/completions $fpath)
#   autoload -Uz compinit && compinit
# Completes commands first, then app folder names in the current directory.

_dockerdance() {
  local -a commands
  commands=(
    'start:Start apps'
    'stop:Stop apps gracefully'
    'restart:Restart apps'
    'update:Pull new images and recreate containers'
    'backup:Archive app folders, then update'
    'restore:Restore the newest backup'
    'status:Dashboard of every app'\''s state'
    'logs:Show recent logs'
    'version:Show image versions'
    'running:List running containers'
    'doctor:Check the environment (read-only)'
    'system-update:Update host OS packages'
    'update-self:Update this script'
    'help:Show help'
  )

  _arguments -C \
    '--dry-run[Show what would happen without doing it]' \
    '(-y --yes)'{-y,--yes}'[Skip confirmation prompts]' \
    '--no-color[Disable coloured output]' \
    '1:command:->command' \
    '*:app:->app'

  case "$state" in
    command) _describe -t commands 'command' commands ;;
    app)     _path_files -/ ;;
  esac
}

_dockerdance "$@"
