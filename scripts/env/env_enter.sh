#!/usr/bin/env bash

if [ $# -ne 1 ]; then
  echo "Usage: $0 container-name"
  echo "  container-name : name of container to be created"
  exit -1
fi

CONTAINER_NAME=$1

xhost +local:docker
docker exec -it ${CONTAINER_NAME} /bin/bash 