#!/usr/bin/env bash

set -o errexit

# usage
print_usage () {
  echo ""
  echo "Usage:"
  echo "  $0 [-h|--help] [--platform <architecture>...] image-name dockerfile-path"
  echo "  $0 [-h|--help] [--platform <architecture>...] (-e docker/podman) (-m image-name1 -m image-name2 ...) dockerfile-path"
  echo "    e.g.,; $0 --platform linux/arm64/v8,linux/amd64 ubuntu_jammy /path/to/dockerfile"
  echo "           $0 -e podman --platform linux/arm64/v8,linux/amd64 -m ubuntu_jammy -m ros2_humble /path/to/dockerfile"
  echo ""
  echo "  arguments:"
  echo "    image-name      : Dockerfile.{image-name}"
  echo "    dockerfile-path : path to dockerfile; <path-to-dockerfile>/Dockerfile.{image-name}"
  echo ""
  echo "  options:"
  echo "    -h, --help   : print usage"
  echo "    -e, --engine : container-engine; docker(Default) or podman"
  echo "    -m, --multi  : multiple-images; name of images; Dockerfile.{image-name}"
  echo "    --platform   : Specify one or more target architectures (e.g., linux/arm64/v8, linux/amd64)"
  echo ""

  exit 0
}

echo -e "\033[32;1mDevelopment environment build started\033[0m"

SCRIPT_DIR=$(dirname $(realpath $0))
POSITIONAL_ARGS=()
CONTAINER_ENGINE=docker # Set default container engine

# Handle options
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -h|--help) 
      print_usage
      ;;
    -e|--engine) 
      CONTAINER_ENGINE="$1"
      shift
      ;;
    -m|--multi) 
      multi_images+=("$1")
      shift
      ;;
    --platform)
      shift
      PLATFORMS="$1"
      shift
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

# DEBUGGING - check options
echo "Positional Arguments: ${POSITIONAL_ARGS[@]}"
echo "Platforms: $PLATFORMS"

# Check if Buildx is available
if ! ${CONTAINER_ENGINE} buildx version &>/dev/null; then
  echo "ERROR: Buildx is not available. Please ensure Docker Buildx is installed."
  exit 1
fi

if [ ${#POSITIONAL_ARGS[@]} -lt 2 ]; then
  echo "ERROR: Not enough arguments provided."
  print_usage 1
fi

if [[ -z "$PLATFORMS" ]]; then
  echo "No architecture specified. Using host architecture."
else
  echo "Building environment for platforms: $PLATFORMS"
fi

IMAGE_NAME="${POSITIONAL_ARGS[0]}"
DOCKERFILE_PATH="${POSITIONAL_ARGS[1]}"

IFS=',' read -r -a platforms <<< "$PLATFORMS"

for platform in "${platforms[@]}"; do
  echo "platform : ${platform}"
  PLATFORM_FLAG="--platform=${platform}"
  tag_name="${platform//\//_}"
  ${CONTAINER_ENGINE} buildx build $PLATFORM_FLAG -t "${IMAGE_NAME}:${tag_name}" --load -f "${DOCKERFILE_PATH}/${IMAGE_NAME}/Dockerfile.${IMAGE_NAME}_${tag_name}" "${DOCKERFILE_PATH}"
done