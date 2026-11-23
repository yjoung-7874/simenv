#!/usr/bin/env bash
# simenv/scripts/env/run.sh
#
# Isaac Sim 시뮬레이션 환경 실행
#
#   이 스크립트는 **컨테이너 런처**다. Isaac Sim 이미지를 어떻게 띄울지만 안다.
#   어떤 시나리오를 실행하고 ROS 2 브리지 extension 을 켤지는
#   시나리오 소유자(mos 등)가 결정해 넘긴다.
#
#   Isaac Sim 은 내장 ROS 2 브리지 라이브러리를 갖고 있으므로,
#   이미지에 ROS 2 를 설치할 필요가 없다. 통신은 DDS 가 담당하고
#   --network=host 로 호스트/다른 컨테이너와 연결된다.
#
# 모드:
#   gui      : 로컬 디스플레이에 창을 띄운다 (개발자 로컬 검증)
#   stream   : headless + WebRTC livestream (원격 개발자, 브라우저/클라이언트 접속)
#   headless : 창 없이 스크립트만 실행하고 exit code 로 판정 (CI)
#   shell    : 대화형 bash (직접 명령 실행 / 디버깅)
#
# Usage:
#   run.sh [-h] --image <key> [--mode gui|stream|headless|shell]
#          [--workspace <host-dir>] [--script <container-path>] [--name <container-name>]
#          [--cache-dir <host-dir>] [--timeout <sec>] [--] [extra isaac args...]
#
#   --image      : catalog.yml 의 이미지 키 (예: isaac-ros2-5.0-jazzy)
#   --mode       : 실행 모드 (default: gui)
#   --workspace  : 호스트 디렉토리 -> 컨테이너 /workspace (default: $PWD)
#   --script     : headless 모드에서 실행할 명령 (컨테이너 셸 문자열)
#   --cache-dir  : Isaac Sim 캐시 루트 (default: $HOME/docker/isaac-sim)
#   --timeout    : headless 모드 타임아웃 (초, default: 600)
#   --           : 이후 인자는 Isaac Sim 에 그대로 전달된다
#
# Examples:
#   # 시나리오 + 브리지 extension (권장 — 브리지는 호출자가 켠다)
#   run.sh --image isaac-ros2-5.0-jazzy --mode headless \
#          --workspace ./sim --script "/isaac-sim/python.sh /workspace/bridge_smoke.py" \
#          -- --/isaac/startup/ros_bridge_extension=isaacsim.ros2.bridge
#
#   run.sh --image isaac-ros2-5.0-jazzy --mode gui          # GUI (브리지 없이)
#   run.sh --image isaac-ros2-5.0-jazzy --mode shell        # 디버깅 셸

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
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
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
case "$MODE" in gui|stream|headless|shell) ;; *) echo "ERROR: invalid --mode '$MODE'" >&2; exit 1 ;; esac
[[ -d "$WORKSPACE" ]] || { echo "ERROR: workspace not found: $WORKSPACE" >&2; exit 1; }
if [[ "$MODE" == "headless" && -z "$RUN_SCRIPT" ]]; then
  echo "ERROR: --script is required in headless mode" >&2; exit 1
fi

# catalog 에서 이미지 이름과 ROS 배포판 확인 (지원하지 않는 키는 여기서 거부)
read -r IMAGE_NAME ROS_DISTRO <<< "$(python3 - "$CATALOG" "$IMAGE_KEY" <<'PY'
import sys, yaml
cat = yaml.safe_load(open(sys.argv[1]))
img = (cat.get("images") or {}).get(sys.argv[2])
print(f"{img['image_name']} {img['ros']}" if img else "")
PY
)"
if [[ -z "$IMAGE_NAME" ]]; then
  echo "ERROR: unknown image key '$IMAGE_KEY' in ${CATALOG}" >&2
  exit 1
fi

TAG="${IMAGE_NAME}:linux_amd64"
if ! docker image inspect "$TAG" >/dev/null 2>&1; then
  echo "ERROR: image ${TAG} not found. Build it first:" >&2
  echo "  ${REPO_ROOT}/dockerfiles/build-matrix.sh ${IMAGE_KEY}" >&2
  exit 1
fi

WORKSPACE="$(realpath "$WORKSPACE")"
mkdir -p "${CACHE_DIR}"/{cache/main,cache/computecache,cache/kit,config,data,logs,pkg}
chown -R 1234:1234 "${CACHE_DIR}" 2>/dev/null || true

# ROS 2 브리지 extension 활성화 여부는 **시나리오 소유자(mos 등)** 가 정한다.
#   어떤 토픽을 어떻게 연결할지 아는 쪽이 결정할 문제이므로 여기서 강제하지 않는다.
#   예) run.sh ... -- --/isaac/startup/ros_bridge_extension=isaacsim.ros2.bridge

# ---------------------------------------------------------------------------
# 공통 docker run 인자
#   --network=host : DDS 멀티캐스트로 호스트/다른 컨테이너의 ROS 2 노드와 연결
# ---------------------------------------------------------------------------
RUN_ARGS=(
  --rm
  --gpus all
  --network=host
  --privileged
  -e "ACCEPT_EULA=Y"
  -e "PRIVACY_CONSENT=Y"
  # ROS_DISTRO 는 **넘기지 않는다**. Isaac Sim 의 setup_ros_env.sh 는
  # ROS_DISTRO 가 비어 있을 때만 내장 브리지 라이브러리 경로를
  # LD_LIBRARY_PATH 에 넣는다. 값이 있으면 브리지 extension 이
  # libament_index_cpp.so 를 찾지 못해 startup 에 실패한다 (검증됨).
  -e "RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}"
  -e "ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}"
  -e "FASTRTPS_DEFAULT_PROFILES_FILE=${FASTRTPS_DEFAULT_PROFILES_FILE:-/etc/simenv/fastdds.xml}"
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

echo -e "\033[32;1msimenv: ${IMAGE_NAME} (${MODE}, ROS 2 ${ROS_DISTRO} available)\033[0m"

# ---------------------------------------------------------------------------
# ROS 2 배포판 선택
#   run.sh 는 ROS_DISTRO 를 컨테이너에 넘기지 않는다(위 주석 참조).
#   대신 Isaac Sim 실행 **직전**에 ros2-env 를 소싱해 jazzy 경로를 잡는다.
#   ros2-env 는 LD_LIBRARY_PATH/PYTHONPATH/AMENT_PREFIX_PATH 를 설정하며,
#   이 환경에서 Isaac Sim 이 시작되므로 브리지 extension 도 정상 로드된다.
# ---------------------------------------------------------------------------
ROS_ENV="source /usr/local/bin/ros2-env ${ROS_DISTRO}"

case "$MODE" in
  gui)
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
    echo "  starting Isaac Sim (GUI)..."
    docker run -it "${RUN_ARGS[@]}" \
      --entrypoint /bin/bash "$TAG" -lc "${ROS_ENV} && /isaac-sim/isaac-sim.sh $(printf '%q ' "${ISAAC_ARGS[@]}")"
    ;;

  stream)
    RUN_ARGS+=(
      -e "ISAACSIM_HOST=${ISAACSIM_HOST:-127.0.0.1}"
      -e "ISAACSIM_SIGNAL_PORT=${ISAACSIM_SIGNAL_PORT:-49100}"
      -e "ISAACSIM_STREAM_PORT=${ISAACSIM_STREAM_PORT:-47998}"
    )
    echo "  stream: ${ISAACSIM_HOST:-127.0.0.1} (signal 49100 / media 47998)"
    docker run -it "${RUN_ARGS[@]}" \
      --entrypoint /bin/bash "$TAG" -lc "${ROS_ENV} && /isaac-sim/runheadless.sh -v $(printf '%q ' "${ISAAC_ARGS[@]}")"
    ;;

  headless)
    echo "  script: ${RUN_SCRIPT} (timeout ${TIMEOUT}s)"
    # 주의: `bash -lc "<script>" <args...>` 에서 첫 인자는 $0 가 되고 이후는 $1.. 이 된다.
    #       Isaac Sim 인자를 문자열 뒤에 붙이면 $0 로 먹혀 사라지므로
    #       ros2-env 소싱 + 스크립트 + 인자를 하나의 셸 문자열로 합쳐 전달한다.
    CMD="${ROS_ENV} && ${RUN_SCRIPT}"
    if [[ ${#ISAAC_ARGS[@]} -gt 0 ]]; then
      CMD="${CMD} $(printf '%q ' "${ISAAC_ARGS[@]}")"
    fi
    # Isaac Sim 은 Python 예외를 삼키고 종료 코드 0 을 돌려주는 경우가 있다.
    #   CI 판정을 신뢰하려면 로그도 함께 본다. 시나리오가 실패를 알리는
    #   표준 방식은 (a) 0 이 아닌 종료 코드, (b) "FAIL:" / "SMOKE_OK" 출력 중
    #   하나다. 여기서는 (a) 와 치명 오류 패턴만 검사한다.
    LOG="$(mktemp)"
    set +e
    timeout "$TIMEOUT" docker run "${RUN_ARGS[@]}" \
      --entrypoint /bin/bash "$TAG" -lc "$CMD" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    set -e
    if [[ $rc -eq 124 ]]; then
      echo "ERROR: headless run timed out after ${TIMEOUT}s" >&2
      rm -f "$LOG"
      exit 124
    elif [[ $rc -ne 0 ]]; then
      echo "ERROR: headless run failed (rc=${rc})" >&2
      rm -f "$LOG"
      exit $rc
    fi
    # 스크립트가 예외로 죽었는데 Isaac Sim 이 0 을 돌려준 경우를 잡는다.
    if grep -qE '^FAIL:|Traceback \(most recent call last\)|ROS2 Bridge startup failed' "$LOG"; then
      echo "ERROR: headless run reported errors in its output (see above)" >&2
      rm -f "$LOG"
      exit 1
    fi
    rm -f "$LOG"
    echo -e "\033[32;1msimenv: headless run OK\033[0m"
    exit 0
    ;;

  shell)
    echo "  ros   : ROS 2 ${ROS_DISTRO} internal libraries (ros2-env 로 소싱됨)"
    echo "  hint  : /isaac-sim/python.sh -c 'import rclpy; print(rclpy.__file__)'"
    docker run -it "${RUN_ARGS[@]}" --entrypoint /bin/bash "$TAG" \
      -lc "${ROS_ENV} && exec bash $(printf '%q ' "${ISAAC_ARGS[@]}")"
    ;;
esac