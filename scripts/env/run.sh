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
#          [--cache-dir <host-dir>] [--timeout <sec>] [--mount <host:container[:ro]>]...
#
#   --image      : catalog.yml 의 이미지 키 (예: isaac-ros2-5.0-jazzy)
#   --mode       : 실행 모드 (default: gui)
#   --workspace  : 호스트 디렉토리 -> 컨테이너 /workspace (default: $PWD)
#   --script     : headless 모드에서 실행할 명령 (컨테이너 셸 문자열)
#   --cache-dir  : Isaac Sim 캐시 루트 (default: $HOME/docker/isaac-sim)
#   --timeout    : headless 안전장치 (초, default: 0 = 제한 없음).
#                  스크립트 종료가 정상 종료 조건이고, 이 값은 멈춤(hang) 방지용이다.
#   --mount      : 추가 볼륨 마운트. 반복 가능. 예: --mount /data/scene:/data:ro
#   --detach     : 백그라운드로 띄운다 (gui/stream/shell). --name 필요.
#                  세션 런처(scripts/session/session.sh)가 사용한다.
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
TIMEOUT=0
DETACH=0
ISAAC_ARGS=()
EXTRA_MOUNTS=()

print_usage() {
  sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
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
    --mount) EXTRA_MOUNTS+=("$2"); shift 2 ;;
    --detach) DETACH=1; shift ;;
    --) shift; ISAAC_ARGS+=("$@"); break ;;
    -*) echo "ERROR: unknown option '$1'" >&2; print_usage 1 ;;
    *) ISAAC_ARGS+=("$1"); shift ;;
  esac
done

[[ -z "$IMAGE_KEY" ]] && { echo "ERROR: --image is required (see build-matrix.sh --list)" >&2; print_usage 1; }
case "$MODE" in gui|stream|headless|shell) ;; *) echo "ERROR: invalid --mode '$MODE'" >&2; exit 1 ;; esac
[[ -d "$WORKSPACE" ]] || { echo "ERROR: workspace not found: $WORKSPACE" >&2; exit 1; }
# 추가 마운트는 host:container[:opts] 형식이며 host 경로가 존재해야 한다.
for m in "${EXTRA_MOUNTS[@]}"; do
  host_path="${m%%:*}"
  [[ -e "$host_path" ]] || { echo "ERROR: mount host path not found: $host_path" >&2; exit 1; }
done
if [[ "$MODE" == "headless" && -z "$RUN_SCRIPT" ]]; then
  echo "ERROR: --script is required in headless mode" >&2; exit 1
fi
if [[ "$DETACH" -eq 1 ]]; then
  [[ "$MODE" == "headless" ]] && { echo "ERROR: --detach is not supported in headless mode" >&2; exit 1; }
  [[ -n "$CONTAINER_NAME" ]] || { echo "ERROR: --detach requires --name" >&2; exit 1; }
fi
# -it for foreground, -d for detached
if [[ "$DETACH" -eq 1 ]]; then RUN_IT=(-d); else RUN_IT=(-it); fi

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
for m in "${EXTRA_MOUNTS[@]}"; do
  RUN_ARGS+=(-v "$m")
done

[[ -n "$CONTAINER_NAME" ]] && RUN_ARGS+=(--name "$CONTAINER_NAME")
# 포그라운드 실행은 종료 시 자동 제거, 백그라운드(--detach)는 세션이 관리한다.
[[ "$DETACH" -eq 0 ]] && RUN_ARGS+=(--rm)

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
    if command -v xhost >/dev/null 2>&1; then
      xhost +local:docker >/dev/null 2>&1 || true
      xhost +local:root >/dev/null 2>&1 || true
    fi
    XAUTH="${XAUTHORITY:-${HOME}/.Xauthority}"
    RUN_ARGS+=(
      -v /tmp/.X11-unix:/tmp/.X11-unix:rw
      -v "${XAUTH}:/isaac-sim/.Xauthority:rw"
      -e "DISPLAY=${DISPLAY}"
      -e "XAUTHORITY=/isaac-sim/.Xauthority"
      -e "QT_X11_NO_MITSHM=1"
    )
    echo "  starting Isaac Sim (GUI)..."
    # --script 가 있으면 그 파이썬 시나리오를 창을 띄운 채로 실행한다
    #   (시나리오가 SimulationApp({"headless": False}) 를 생성).
    #   없으면 Isaac Sim 에디터 전체를 띄운다.
    if [[ -n "$RUN_SCRIPT" ]]; then
      docker run "${RUN_IT[@]}" "${RUN_ARGS[@]}" \
        --entrypoint /bin/bash "$TAG" -lc "${ROS_ENV} && ${RUN_SCRIPT} $(printf '%q ' "${ISAAC_ARGS[@]}")"
    else
      docker run "${RUN_IT[@]}" "${RUN_ARGS[@]}" \
        --entrypoint /bin/bash "$TAG" -lc "${ROS_ENV} && /isaac-sim/isaac-sim.sh $(printf '%q ' "${ISAAC_ARGS[@]}")"
    fi
    ;;

  stream)
    # Isaac Sim livestream(WebRTC) 설정.
    #   ISAACSIM_HOST 는 simenv 의 편의 변수다. 실제로 Isaac 이 읽는 것은
    #   /app/livestream/* 설정이다.
    #   - signal 포트: /app/livestream/port (기본 49100)
    #   - media 포트: 기본적으로 min/maxHostPort 범위에서 하나를 고른다.
    #     여러 인스턴스를 띄울 수 있도록 **전역 고정하지 않는다**.
    #     특정 포트로 고정하려면 ISAACSIM_STREAM_PORT 를 준다(fixedHostPort).
    #   - ICE 가 광고할 주소: publicEndpointAddress (LAN IP)
    #   미지정 시 백엔드가 임의 포트를 잡아 클라이언트와 어긋날 수 있다.
    signal_port="${ISAACSIM_SIGNAL_PORT:-49100}"
    stream_host="${ISAACSIM_HOST:-127.0.0.1}"
    RUN_ARGS+=(
      -e "ISAACSIM_HOST=${stream_host}"
      -e "ISAACSIM_SIGNAL_PORT=${signal_port}"
      -e "MOS_STREAM_WIDTH=${MOS_STREAM_WIDTH:-1920}"
      -e "MOS_STREAM_HEIGHT=${MOS_STREAM_HEIGHT:-1080}"
    )
    ISAAC_ARGS+=(
      "--/app/livestream/port=${signal_port}"
      "--/app/livestream/publicEndpointAddress=${stream_host}"
      "--/app/livestream/publicEndpointPort=${signal_port}"
    )
    if [[ -n "${ISAACSIM_STREAM_PORT:-}" ]]; then
      # 명시 포트: 이 인스턴스만 해당 포트를 쓴다 (다중 인스턴스는 서로 다른 값).
      ISAAC_ARGS+=("--/app/livestream/fixedHostPort=${ISAACSIM_STREAM_PORT}")
      stream_desc="${ISAACSIM_STREAM_PORT} (fixed)"
    else
      # 범위에서 자동 선택: 여러 인스턴스가 같은 호스트에서 공존할 수 있다.
      #   단, 클라이언트의 Stream 포트는 실제 선택된 값과 같아야 한다.
      stream_min="${ISAACSIM_STREAM_PORT_MIN:-47998}"
      stream_max="${ISAACSIM_STREAM_PORT_MAX:-48020}"
      ISAAC_ARGS+=(
        "--/app/livestream/minHostPort=${stream_min}"
        "--/app/livestream/maxHostPort=${stream_max}"
      )
      stream_desc="auto ${stream_min}-${stream_max}"
    fi
    [[ "${SIM_STREAM_DEBUG:-0}" == "1" ]] && ISAAC_ARGS+=("--/app/livestream/logLevel=info")
    echo "  stream: ${stream_host} (signal ${signal_port} / media ${stream_desc}) ${MOS_STREAM_WIDTH:-1920}x${MOS_STREAM_HEIGHT:-1080}"
    # --script 가 있으면 그 시나리오를 headless 로 실행하면서 livestream 을 켠다.
    #   시나리오는 MOS_STREAM=1 을 보고 omni.kit.livestream.webrtc 를 활성화한다.
    #   없으면 빈 스트리밍 에디터(runheadless.sh)를 띄운다.
    if [[ -n "$RUN_SCRIPT" ]]; then
      docker run "${RUN_IT[@]}" "${RUN_ARGS[@]}" \
        --entrypoint /bin/bash "$TAG" -lc "export MOS_STREAM=1 && ${ROS_ENV} && ${RUN_SCRIPT} $(printf '%q ' "${ISAAC_ARGS[@]}")"
    else
      docker run "${RUN_IT[@]}" "${RUN_ARGS[@]}" \
        --entrypoint /bin/bash "$TAG" -lc "${ROS_ENV} && /isaac-sim/runheadless.sh -v $(printf '%q ' "${ISAAC_ARGS[@]}")"
    fi
    ;;

  headless)
    if [[ "$TIMEOUT" -gt 0 ]]; then
      echo "  script: ${RUN_SCRIPT} (safety timeout ${TIMEOUT}s)"
    else
      echo "  script: ${RUN_SCRIPT} (no timeout — runs until the script exits)"
    fi
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
    if [[ "$TIMEOUT" -gt 0 ]]; then
      # 안전장치: 지정 시간을 넘기면 강제 종료한다. 정상 종료는 스크립트 exit code.
      timeout "$TIMEOUT" docker run "${RUN_ARGS[@]}" \
        --entrypoint /bin/bash "$TAG" -lc "$CMD" 2>&1 | tee "$LOG"
      rc=${PIPESTATUS[0]}
    else
      # 제한 없음: 스크립트가 끝나거나 사용자가 멈출 때까지 실행한다.
      docker run "${RUN_ARGS[@]}" \
        --entrypoint /bin/bash "$TAG" -lc "$CMD" 2>&1 | tee "$LOG"
      rc=${PIPESTATUS[0]}
    fi
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
    # 주의: extension teardown 등에서 나오는 비치명 Traceback 까지 잡으면 오탐이 난다.
    #       시나리오의 실패 신호(FAIL:)와 실제 크래시/브리지 실패만 본다.
    if grep -qE '^FAIL:|ROS2 Bridge startup failed|Segmentation fault|Crash detected in pid' "$LOG"; then
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
    # --detach: TTY 가 없으므로 대화형 bash 대신 계속 살아있는 셸 컨테이너로 둔다
    #           (session.sh 가 docker exec 로 접속한다).
    if [[ "$DETACH" -eq 1 ]]; then
      SHELL_CMD="${ROS_ENV} && trap : TERM INT; sleep infinity & wait"
    else
      SHELL_CMD="${ROS_ENV} && exec bash $(printf '%q ' "${ISAAC_ARGS[@]}")"
    fi
    docker run "${RUN_IT[@]}" "${RUN_ARGS[@]}" --entrypoint /bin/bash "$TAG" \
      -lc "$SHELL_CMD"
    ;;
esac