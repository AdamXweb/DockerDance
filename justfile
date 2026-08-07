# List available commands
default:
    @just --list

# Run the POSIX test harness (stub docker, no daemon touched)
[group("dev")]
test:
    sh tests/run-tests.sh

# ShellCheck and POSIX syntax check, same targets as CI
[group("dev")]
lint:
    shellcheck docker_volumes/manage.sh contrib/dockerdance-completion.bash tests/run-tests.sh tests/stub/docker
    sh -n docker_volumes/manage.sh

# Run the management script's interactive menu
[group("dev")]
run:
    sh docker_volumes/manage.sh

# Tag and push a release (release.yml attaches manage.sh and its checksum)
[group("ship")]
release version:
    git tag -a v{{version}} -m v{{version}}
    git push origin v{{version}}
