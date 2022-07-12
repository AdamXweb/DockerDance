#!/bin/sh
set -e

#Set these variables!
#Apps to backup (according to the folder name). Add each one with a space in between e.g. "vaultwarden uptime-kuma"
Apps="example"
USERNAME="systemadmin"

#Specific to Linux. Can change these if needed
#Set folder from root to avoid permission issues if running script as different user. (this would be /home/systemadmin/docker_volumes)
DOCKER_VOLUMES='/home/'$USERNAME'/docker_volumes/'
#Target is the folder within that the tar will save to if running a backup.
TARGET=$DOCKER_VOLUMES'backup/'


#Check Docker is installed
DOCKER_VERSION=`docker --version`
if [ "$?" -ne "0" ]; then
  echo "Please install Docker before proceeding."
  exit 1
fi

#Check which docker command to use
DOCKER_COMPOSE_COMMAND="docker compose"
if ! $DOCKER_COMPOSE_COMMAND > /dev/null 2>&1; then
  DOCKER_COMPOSE_COMMAND="docker-compose"
fi

#Check to see if variables have been set above.
checkDefault() {
  if [ $Apps == "example" ]; then echo "Please change the default app to include your apps" && exit 1; fi
}


# TODO use getopt at some stage to make a flag -a set variable to $apps
COMMAND=$1 && shift 1

case "$COMMAND" in
  'backup' )
    checkDefault
    echo "Backing up apps including:"
    for i in $Apps
    do
      echo "$i"
    done
    for i in $Apps
    do
        echo "Stopping $i"
        cd $i
        $DOCKER_COMPOSE_COMMAND kill
        echo "$i stopped"
        echo "Backing up $i"
        tar -cjf $TARGET$i$(date '+%Y-%m-%d').tar.bz2 $DOCKER_VOLUMES$i
        echo "$i is backed up"
        echo "Updating $i"
        $DOCKER_COMPOSE_COMMAND pull
        echo "Images up to date. Starting all services."
        $DOCKER_COMPOSE_COMMAND up -d
        echo "$i backed up, updated and running"
        cd ..
    done
    echo "Backing up completed"
    ;;
  'restore' )
    echo "Coming soon:"
    ;;
  'logs' )
    for i in $Apps
    do
      echo "Getting $i logs"
      cd $i
      $DOCKER_COMPOSE_COMMAND logs -f
      cd ..
    done
    ;;
  'update' )
    checkDefault
    echo "Updating all services."
    for i in $Apps
    do
      echo "$i"
    done
    echo "---"
    for i in $Apps
    do
        echo "Stopping $i"
        cd $i
        $DOCKER_COMPOSE_COMMAND kill
        echo "$i stopped"
        echo "Updating $i"
        $DOCKER_COMPOSE_COMMAND pull
        echo "Images up to date. Starting all services."
        $DOCKER_COMPOSE_COMMAND up -d
        echo "$i Updated and running"
        cd ..
    done
    echo "Services updated. Give them a moment to warm up."
    ;;
  'stop' )
    checkDefault
    echo "Stopping all services:"
    for i in $Apps
    do
      echo "$i"
    done
    echo "---"
    for i in $Apps
    do
        echo "Stopping $i"
        cd $i
        $DOCKER_COMPOSE_COMMAND kill
        echo "$i stopped"
        cd ..
    done
    echo "Services stopped"
    ;;
  'start' )
    checkDefault
    echo "Starting all services"
    for i in $Apps
    do
      echo "$i"
    done
    echo "---"
    for i in $Apps
    do
        echo "Starting $i"
        cd $i
        $DOCKER_COMPOSE_COMMAND up -d
        echo "$i started"
        cd ..
    done
    echo "Services started. Give them a moment to warm up."
    ;;
  'restart' )
    checkDefault
    echo "Restarting all services"
    for i in $Apps
    do
        echo "Stopping $i"
        cd $i
        $DOCKER_COMPOSE_COMMAND kill
        echo "$i stopped"
        $DOCKER_COMPOSE_COMMAND up -d
        echo "$i restarted"
        cd ..
    done
    echo "Services restarted. Give them a moment to warm up."
    ;;
  'version' )
    for i in $Apps
      do
          echo "Getting $i version"
          cd $i
          $DOCKER_COMPOSE_COMMAND images
          cd ..
      done
    ;;
    'running' )
    echo "Getting all running services"
    docker ps
    ;;
    'apt' )
    echo "Updating system with apt."
    apt update && apt upgrade -y
    apt-get update && apt upgrade -y
    ;;
  * )
    echo "Unknown command"
    ;;
esac

exec "$@"
