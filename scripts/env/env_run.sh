#!/usr/bin/env bash

if [ $# -ne 2 ]; then
  echo "Usage: $0 image-name project-path"
  echo "  image-name: Dockerfile.{image-name}"
  echo "  project-root: path to the project root on the host"
  exit -1
fi

IMAGE=$1
PROJECT_ROOT=$2

if [ ! -d "$PROJECT_ROOT" ]; then
  echo "$PROJECT_ROOT doesn't exist."
  exit -1
fi

get_absolute_path() {
  local relative_path="$1"
  local absolute_path=$(readlink -f "$relative_path" 2>/dev/null || realpath "$relative_path" 2>/dev/null)
  
  if [ -z "$absolute_path" ]; then
    echo "Error: Unable to convert to absolute path."
    exit 1
  fi

  echo "$absolute_path"
}

NOW=$(date +'%Y-%m-%d_%H%M%S')

PROJECT_ROOT=$(get_absolute_path ${PROJECT_ROOT})
ENTRY_PATH=$(get_absolute_path ./entry)

xhost +local:docker

docker run --name="${USER}_${NOW}" --runtime=nvidia --gpus all -e "ACCEPT_EULA=Y" \
  --rm -it --privileged --network="host" \
  -v ${HOME}/nvidia/docker/isaac-sim/cache/kit:/isaac-sim/kit/cache:rw \
  -v ${HOME}/nvidia/docker/isaac-sim/cache/ov:/root/.cache/ov:rw \
  -v ${HOME}/nvidia/docker/isaac-sim/cache/pip:/root/.cache/pip:rw \
  -v ${HOME}/nvidia/docker/isaac-sim/cache/glcache:/root/.cache/nvidia/GLCache:rw \
  -v ${HOME}/nvidia/docker/isaac-sim/cache/computecache:/root/.nv/ComputeCache:rw \
  -v ${HOME}/nvidia/docker/isaac-sim/logs:/root/.nvidia-omniverse/logs:rw \
  -v ${HOME}/nvidia/docker/isaac-sim/data:/root/.local/share/ov/data:rw \
  -v ${HOME}/nvidia/docker/isaac-sim/documents:/root/Documents:rw \
  --env "PRIVACY_CONSENT=Y" \
  -v ${PROJECT_ROOT}:/devenv/projects \
  -v ${ENTRY_PATH}:/entry \
  -v /dev:/dev \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v ${HOME}/.Xauthority:/root/.Xauthority:rw \
  --env="DISPLAY" \
  --env="QT_X11_NO_MITSHM=1" \
  --entrypoint /entry/entry.sh \
    ${IMAGE}

#docker run --name isaac-sim --entrypoint bash -it --rm --network=host \
#  nvcr.io/nvidia/isaac-sim:4.5.0
