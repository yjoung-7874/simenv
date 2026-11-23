#!/usr/bin/env bash
# simenv/scripts/env/run.sh
#
# Isaac Sim 시뮬레이션 환경 실행 (3가지 모드)
#
#   gui      : 로컬 디스플레이에 창을 띄운다 (개발자 로컬 검증)
#   stream   : headless + WebRTC livestream (원격 개발자, 브라우저/클라이언트 접속)
#   headless : 창 없이 스크립트만 실행하고 exit code 로 판정 (CI)
#
# Usage:
#   run.sh [-h] --image <key> [--mode gui|stream|headless]
#          [--workspace <host-dir>] [--script <container-path>] [--name <container-name>]
#          [--cache-dir <host-dir>] [--timeout <sec>] [--] [extra isaac args...]
#
#   --image      : catalog.yml 의 이미지 키 (예: isaac-ros2-5.0-jazzy)
#   --mode       : 실행 모드 (default: gui)
#   --workspace  : 호스트 디렉토리 -> 컨테이너 /workspace (default: $PWD)
#   --script     : headless 모드에서 실행할 스크립트 (컨테이너 경로)
#   --cache-dir  : Isaac Sim 캐시 루트 (default: $HOME/docker/isaac-sim)
#   --timeout    : headless 모드 타임아웃 (초, default: 600)
#
# Examples:
#   run.sh --image isaac-ros2-5.0-jazzy --mode gui
#   run.sh --image isaac-ros2-5.0-jazzy --mode headless \
#          --workspace ./scenarios --script /workspace/smoke.py

set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CATALOG="${REPO_ROOT}/dockerfiles/catalog.yml"

IMAGE_KEY=""
MODE="gui"
WORKSPACE="$PWD"
RUN_SCRIPT=""
CONTAINER_NAME=""
CACHE_DIR="${HOME}/docker/isaac-sim"
TIMEOUT=600
ISAAC_ARGS=()

print_usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) print_usage 0 ;;
    --image) IMAGE_KEY="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --script) RUN_SCRIPT="$2"; shift 2 ;;
    --name) CONTAINER_NAME="$2"; shift 2 ;;
    --cache-dir) CACHE_DIR="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --) shift; ISAAC_ARGS+=("$@"); break ;;
    -*) echo "ERROR: unknown option '$1'" >&2; print_usage 1 ;;
    *) ISAAC_ARGS+=("$1"); shift ;;
  esac
done

[[ -z "$IMAGE_KEY" ]] && { echo "ERROR: --image is required (see build-matrix.sh --list)" >&2; print_usage 1; }
case "$MODE" in gui|stream|headless) ;; *) echo "ERROR: invalid --mode '$MODE'" >&2; exit 1 ;; esac
[[ -d "$WORKSPACE" ]] || { echo "ERROR: workspace not found: $WORKSPACE" >&2; exit 1; }
if [[ "$MODE" == "headless" && -z "$RUN_SCRIPT" ]]; then
  echo "ERROR: --script is required in headless mode" >&2; exit 1
fi

# catalog 에서 이미지 이름 확인 (지원하지 않는 키는 여기서 거부)
IMAGE_NAME="$(python3 - "$CATALOG" "$IMAGE_KEY" <<'PY'
import sys, yaml
cat = yaml.safe_load(open(sys.argv[1]))
img = (cat.get("images") or {}).get(sys.argv[2])
print(img["image_name"] if img else "")
PY
)"
if [[ -z "$IMAGE_NAME" ]]; then
  echo "ERROR: unknown image key '$IMAGE_KEY' in ${CATALOG}" >&2
  exit 1
fi

# Isaac Sim 은 linux/amd64 전용
PLATFORM="linux/amd64"
TAG="${IMAGE_NAME}:linux_amd64"
if ! docker image inspect "$TAG" >/dev/null 2>&1; then
  echo "ERROR: image ${TAG} not found. Build it first:" >&2
  echo "  ${REPO_ROOT}/dockerfiles/build-matrix.sh ${IMAGE_KEY}" >&2
  exit 1
fi

WORKSPACE="$(realpath "$WORKSPACE")"
mkdir -p "${CACHE_DIR}"/{cache/main,cache/computecache,cache/kit,config,data,logs,pkg}
# 컨테이너 사용자는 1234. 캐시 디렉토리 쓰기 권한을 맞춘다 (sudo 없이 가능한 경우만).
chown -R 1234:1234 "${CACHE_DIR}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 공통 docker run 인자
# ---------------------------------------------------------------------------
RUN_ARGS=(
  --rm
  --gpus all
  --network=host
  --privileged
  -e "ACCEPT_EULA=Y"
  -e "PRIVACY_CONSENT=Y"
  -e "ROS_DISTRO=${ROS_DISTRO:-}"
  -v "${CACHE_DIR}/cache/main:/isaac-sim/.cache:rw"
  -v "${CACHE_DIR}/cache/computecache:/isaac-sim/.nv/ComputeCache:rw"
  -v "${CACHE_DIR}/cache/kit:/isaac-sim/kit/cache:rw"
  -v "${CACHE_DIR}/logs:/isaac-sim/.nvidia-omniverse/logs:rw"
  -v "${CACHE_DIR}/config:/isaac-sim/.nvidia-omniverse/config:rw"
  -v "${CACHE_DIR}/data:/isaac-sim/.local/share/ov/data:rw"
  -v "${CACHE_DIR}/pkg:/isaac-sim/.local/share/ov/pkg:rw"
  -v "${WORKSPACE}:/workspace:rw"
)

[[ -n "$CONTAINER_NAME" ]] && RUN_ARGS+=(--name "$CONTAINER_NAME")

echo -e "\033[32;1msimenv: ${IMAGE_NAME} (${MODE})\033[0m"

case "$MODE" in
  gui)
    # 로컬 디스플레이 전용. 원격/VNC 에서는 stream 모드를 쓴다.
    if [[ -z "${DISPLAY:-}" ]]; then
      echo "ERROR: DISPLAY is not set; use --mode stream for remote/headless hosts" >&2
      exit 1
    fi
    if command -v xhost >/dev/null 2>&1; then xhost +local:docker >/dev/null 2>&1 || true; fi
    RUN_ARGS+=(
      -v /tmp/.X11-unix:/tmp/.X11-unix:rw
      -v "${HOME}/.Xauthority:/isaac-sim/.Xauthority:rw"
      -e "DISPLAY=${DISPLAY}"
      -e "QT_X11_NO_MITSHM=1"
    )
    docker run -it "${RUN_ARGS[@]}" --entrypoint /bin/bash "$TAG" "${ISAAC_ARGS[@]}"
    ;;

  stream)
    # headless + WebRTC. 브라우저(웹 뷰어) 또는 Isaac Sim Streaming Client 로 접속.
    RUN_ARGS+=(
      -e "ISAACSIM_HOST=${ISAACSIM_HOST:-127.0.0.1}"
      -e "ISAACSIM_SIGNAL_PORT=${ISAACSIM_SIGNAL_PORT:-49100}"
      -e "ISAACSIM_STREAM_PORT=${ISAACSIM_STREAM_PORT:-47998}"
    )
    echo "  stream: ${ISAACSIM_HOST:-127.0.0.1} (signal 49100 / media 47998)"
    docker run -it "${RUN_ARGS[@]}" --entrypoint /bin/bash "$TAG" "${ISAAC_ARGS[@]}"
    ;;

  headless)
    echo "  script: ${RUN_SCRIPT} (timeout ${TIMEOUT}s)"
    set +e
    timeout "$TIMEOUT" docker run "${RUN_ARGS[@]}" \
      --entrypoint /bin/bash "$TAG" -lc "$RUN_SCRIPT" "${ISAAC_ARGS[@]}"
    rc=$?
    set -e
    if [[ $rc -eq 124 ]]; then
      echo "ERROR: headless run timed out after ${TIMEOUT}s" >&2
    elif [[ $rc -ne 0 ]]; then
      echo "ERROR: headless run failed (rc=${rc})" >&2
    else
      echo -e "\033[32;1msimenv: headless run OK\033[0m"
    fi
    exit $rc
    ;;
esac