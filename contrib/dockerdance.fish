# Fish completion for DockerDance's manage.sh.
# Install: copy to ~/.config/fish/completions/manage.sh.fish
# (works when the tool is invoked as `manage.sh` or an `appmanage` alias).
# Completes commands first, then app folder names in the current directory.

set -l dd_cmds start stop restart update backup restore status logs version running doctor system-update update-self help

for cmd in manage.sh appmanage
    # Commands (only as the first argument)
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a start         -d 'Start apps'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a stop          -d 'Stop apps gracefully'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a restart       -d 'Restart apps'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a update        -d 'Pull new images and recreate'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a backup        -d 'Archive app folders, then update'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a restore       -d 'Restore the newest backup'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a status        -d 'Dashboard of app state'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a logs          -d 'Show recent logs'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a version       -d 'Show image versions'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a running       -d 'List running containers'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a doctor        -d 'Check the environment'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a system-update -d 'Update host OS packages'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a update-self   -d 'Update this script'
    complete -c $cmd -f -n "not __fish_seen_subcommand_from $dd_cmds" -a help          -d 'Show help'

    # Options
    complete -c $cmd -l dry-run  -d 'Show what would happen without doing it'
    complete -c $cmd -s y -l yes -d 'Skip confirmation prompts'
    complete -c $cmd -l no-color -d 'Disable coloured output'

    # App folder names once a command is present
    complete -c $cmd -f -n "__fish_seen_subcommand_from $dd_cmds" -a '(__fish_complete_directories)'
end
