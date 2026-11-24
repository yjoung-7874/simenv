#!/usr/bin/env bash
# simenv/scripts/session/session.sh
#
# 시뮬레이션 **세션** 런처.
#
#   이 스크립트는 "환경 분리" 원칙을 구현한다.
#     - Isaac Sim 컨테이너 : 시뮬레이터 + ROS 2 브리지 번들 (simenv 소유)
#     - ROS 2 컨테이너     : 빌드/도구용 정식 ROS 2 (devenv 소유, 태그로만 참조)
#   두 컨테이너는 DDS 로만 연결된다. simenv 는 ROS 이미지의 출처를 모른다
#   (docker 태그 문자열만 받는다). 어떤 이미지를 쓸지는 devsys 가 결정한다.
#
#   --no-ros 로 띄우면 ROS 컨테이너 없이 Isaac Sim 만 남는다 (no-ROS 모드).
#   이때 호스트의 mos dist 바이너리 등이 DDS 로 붙는다.
#
# Usage:
#   session.sh <command> [options]
#
# Commands:
#   plan      해석된 이미지/이름/DDS 계약만 출력 (부작용 없음)
#   up        세션 컨테이너를 백그라운드로 시작
#   down      세션 컨테이너를 중지/제거
#   status    세션 컨테이너 + (ROS 가 있으면) 토픽 확인
#   exec      ROS 컨테이너에서 명령 실행 (--in sim 이면 Isaac 컨테이너)
#
# Options:
#   --name <base>        세션 이름 (default: simenv). 컨테이너: <base>-sim, <base>-ros
#   --sim-image <key>    Isaac Sim 이미지 **카탈로그 키** (default: isaac-ros2-5.0-jazzy)
#   --sim-mode <m>       stream | gui | shell (default: stream)
#   --sim-script <path>  시뮬 내부에서 실행할 스크립트 (컨테이너 경로, 선택)
#   --ros-image <tag>    ROS 2 피어 **docker 태그** (default: ros:jazzy)
#   --ros-distro <d>     ROS 2 배포판 (default: jazzy)
#   --no-sim             Isaac Sim 을 띄우지 않는다
#   --no-ros             ROS 피어를 띄우지 않는다 (no-ROS 모드)
#   --workspace <dir>    Isaac 컨테이너에 /workspace 로 마운트 (default: $PWD)
#   --domain <n>         ROS_DOMAIN_ID (default: 0)
#   --rmw <impl>         RMW_IMPLEMENTATION (default: rmw_fastrtps_cpp)
#   --dds-profile <file> FastDDS 프로필 XML (호스트 경로, 선택)
#   --wait-topic <t>     up 후 이 토픽을 기다린다 (default: /sim_pose)
#   --wait-timeout <s>   대기 시간 (default: 60)
#   --no-wait            up 후 토픽 대기를 건너뛴다
#   --                   이후 인자는 Isaac Sim 에 그대로 전달
#
# Examples:
#   # Isaac + ROS 피어 (개발/CI)
#   ./session.sh up --ros-image ros2-jazzy:linux_amd64
#
#   # Isaac 만 (no-ROS 모드) — 호스트 dist 바이너리가 붙는다
#   ./session.sh up --no-ros
#
#   # 이미 떠 있는 Isaac 에 ROS 피어만 붙인다 (검증/디버깅)
#   ./session.sh up --no-sim --ros-image ros:jazzy
#   ./session.sh exec -- ros2 topic list
#   ./session.sh down

set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
RUN_SH="${SCRIPT_DIR}/../env/run.sh"

CMD="${1:-}"
shift || true

NAME="simenv"
SIM_IMAGE="isaac-ros2-5.0-jazzy"
SIM_MODE="stream"
SIM_SCRIPT=""
ROS_IMAGE="ros:jazzy"
ROS_DISTRO="jazzy"
START_SIM=1
START_ROS=1
WORKSPACE="$PWD"
DOMAIN="0"
RMW="rmw_fastrtps_cpp"
DDS_PROFILE=""
WAIT_TOPIC="/sim_pose"
WAIT_TIMEOUT=60
DO_WAIT=1
EXEC_IN="ros"
EXTRA=()

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --name) NAME="$2"; shift 2 ;;
    --sim-image) SIM_IMAGE="$2"; shift 2 ;;
    --sim-mode) SIM_MODE="$2"; shift 2 ;;
    --sim-script) SIM_SCRIPT="$2"; shift 2 ;;
    --ros-image) ROS_IMAGE="$2"; shift 2 ;;
    --ros-distro) ROS_DISTRO="$2"; shift 2 ;;
    --no-sim) START_SIM=0; shift ;;
    --no-ros) START_ROS=0; shift ;;
    --ros-only) START_SIM=0; START_ROS=1; shift ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --rmw) RMW="$2"; shift 2 ;;
    --dds-profile) DDS_PROFILE="$2"; shift 2 ;;
    --wait-topic) WAIT_TOPIC="$2"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
    --no-wait) DO_WAIT=0; shift ;;
    --in) EXEC_IN="$2"; shift 2 ;;
    --) shift; EXTRA+=("$@"); break ;;
    -*) echo "ERROR: unknown option '$1'" >&2; usage 1 ;;
    *) echo "ERROR: unexpected argument '$1'" >&2; usage 1 ;;
  esac
done

SIM_CTR="${NAME}-sim"
ROS_CTR="${NAME}-ros"

# 세션 컨테이너에 공통으로 넘기는 DDS 계약
DDS_ARGS=()
build_dds_args() {
  DDS_ARGS=(
    -e "ROS_DOMAIN_ID=${DOMAIN}"
    -e "RMW_IMPLEMENTATION=${RMW}"
  )
  if [[ -n "$DDS_PROFILE" ]]; then
    [[ -f "$DDS_PROFILE" ]] || { echo "ERROR: DDS profile not found: $DDS_PROFILE" >&2; exit 1; }
    DDS_ARGS+=(
      -v "$(realpath "$DDS_PROFILE"):/etc/simenv/fastdds.xml:ro"
      -e "FASTRTPS_DEFAULT_PROFILES_FILE=/etc/simenv/fastdds.xml"
    )
  fi
}

container_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "absent"
}

ros_exec_body() {
  local body="$1"
  local pre="source /opt/ros/${ROS_DISTRO}/setup.bash 2>/dev/null || true"
  pre="${pre}; export ROS_DOMAIN_ID=${DOMAIN} RMW_IMPLEMENTATION=${RMW}"
  if [[ -n "$DDS_PROFILE" ]]; then
    pre="${pre}; export FASTRTPS_DEFAULT_PROFILES_FILE=/etc/simenv/fastdds.xml"
  fi
  docker exec "$ROS_CTR" bash -lc "${pre}; ${body}"
}

cmd_plan() {
  echo "=== simenv session: ${NAME} ==="
  if [[ "$START_SIM" -eq 1 ]]; then
    echo "  sim : ${SIM_CTR}"
    echo "        image   : ${SIM_IMAGE} (simenv catalog)"
    echo "        mode    : ${SIM_MODE}"
    [[ -n "$SIM_SCRIPT" ]] && echo "        script  : ${SIM_SCRIPT}"
    echo "        workspace: ${WORKSPACE} -> /workspace"
  else
    echo "  sim : (disabled)"
  fi
  if [[ "$START_ROS" -eq 1 ]]; then
    echo "  ros : ${ROS_CTR}"
    echo "        image   : ${ROS_IMAGE} (docker tag; 출처 무관)"
    echo "        distro  : ${ROS_DISTRO}"
  else
    echo "  ros : (disabled, no-ROS 모드)"
  fi
  echo "  dds : domain=${DOMAIN} rmw=${RMW}"
  [[ -n "$DDS_PROFILE" ]] && echo "        profile=${DDS_PROFILE}"
  echo "  net : --network=host (두 컨테이너가 DDS 로 직접 연결)"
}

cmd_up() {
  [[ "$START_SIM" -eq 1 || "$START_ROS" -eq 1 ]] || {
    echo "ERROR: --no-sim 과 --no-ros 를 동시에 줄 수 없습니다" >&2; exit 1; }

  # 이전 세션 정리 (같은 이름)
  docker rm -f "$SIM_CTR" "$ROS_CTR" >/dev/null 2>&1 || true

  if [[ "$START_SIM" -eq 1 ]]; then
    [[ -x "$RUN_SH" ]] || { echo "ERROR: run.sh not found: $RUN_SH" >&2; exit 1; }
    local -a sim_args=(
      --image "$SIM_IMAGE"
      --mode "$SIM_MODE"
      --workspace "$WORKSPACE"
      --name "$SIM_CTR"
      --detach
    )
    [[ -n "$SIM_SCRIPT" ]] && sim_args+=(--script "$SIM_SCRIPT")
    if [[ ${#EXTRA[@]} -gt 0 ]]; then
      sim_args+=(-- "${EXTRA[@]}")
    fi
    echo "simenv: starting sim (${SIM_CTR}, ${SIM_IMAGE}, ${SIM_MODE})..."
    # DDS 계약은 run.sh 가 자체 기본값을 쓰므로 여기서 환경변수로 넘긴다.
    ROS_DOMAIN_ID="$DOMAIN" RMW_IMPLEMENTATION="$RMW" \
      FASTRTPS_DEFAULT_PROFILES_FILE="" \
      bash "$RUN_SH" "${sim_args[@]}"
    echo "simenv: sim started (${SIM_CTR})"
  fi

  if [[ "$START_ROS" -eq 1 ]]; then
    if ! docker image inspect "$ROS_IMAGE" >/dev/null 2>&1; then
      echo "ERROR: ROS image not found: ${ROS_IMAGE}" >&2
      echo "  빌드: devenv 의 ros2-jazzy 등. 또는 --ros-image ros:jazzy" >&2
      exit 1
    fi
    local -a ros_args=(
      -d --name "$ROS_CTR" --network=host
    )
    build_dds_args
    ros_args+=("${DDS_ARGS[@]}")
    echo "simenv: starting ros peer (${ROS_CTR}, ${ROS_IMAGE})..."
    docker run "${ros_args[@]}" "$ROS_IMAGE" \
      bash -lc 'trap : TERM INT; sleep infinity & wait' >/dev/null
    echo "simenv: ros peer started (${ROS_CTR})"
  fi

  if [[ "$START_ROS" -eq 1 && "$DO_WAIT" -eq 1 ]]; then
    echo "simenv: waiting for topic ${WAIT_TOPIC} (timeout ${WAIT_TIMEOUT}s)..."
    local waited=0
    while (( waited < WAIT_TIMEOUT )); do
      if ros_exec_body "ros2 topic list 2>/dev/null | grep -qx '${WAIT_TOPIC}'"; then
        echo "simenv: ${WAIT_TOPIC} ready"
        break
      fi
      sleep 2
      waited=$((waited + 2))
    done
    if (( waited >= WAIT_TIMEOUT )); then
      echo "WARN: ${WAIT_TOPIC} not seen within ${WAIT_TIMEOUT}s" >&2
    fi
  fi

  echo "simenv: session '${NAME}' up"
  cmd_status || true
}

cmd_down() {
  docker rm -f "$SIM_CTR" "$ROS_CTR" >/dev/null 2>&1 || true
  echo "simenv: session '${NAME}' down"
}

cmd_status() {
  echo "=== session: ${NAME} ==="
  local found=0
  for c in "$SIM_CTR" "$ROS_CTR"; do
    local st
    st="$(container_state "$c")"
    if [[ "$st" != "absent" ]]; then
      found=1
      printf "  %-24s %-10s %s\n" "$c" "$st" "$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)"
    fi
  done
  [[ "$found" -eq 0 ]] && echo "  (없음)"
  if [[ "$(container_state "$ROS_CTR")" == "running" ]]; then
    echo ""
    echo "=== topics (via ${ROS_CTR}) ==="
    ros_exec_body "ros2 topic list 2>/dev/null" || echo "  (ros2 실패)"
  fi
}

cmd_exec() {
  [[ ${#EXTRA[@]} -gt 0 ]] || { echo "ERROR: exec 에 명령이 필요합니다: session.sh exec -- <cmd>" >&2; exit 1; }
  local body="${EXTRA[*]}"
  if [[ "$EXEC_IN" == "sim" ]]; then
    [[ "$(container_state "$SIM_CTR")" == "running" ]] || { echo "ERROR: sim container not running: $SIM_CTR" >&2; exit 1; }
    docker exec "$SIM_CTR" bash -lc "$body"
  else
    [[ "$(container_state "$ROS_CTR")" == "running" ]] || { echo "ERROR: ros container not running: $ROS_CTR" >&2; exit 1; }
    ros_exec_body "$body"
  fi
}

case "$CMD" in
  ""|-h|--help|help) usage 0 ;;
  plan) cmd_plan ;;
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  exec) cmd_exec ;;
  *) echo "ERROR: unknown command '$CMD'" >&2; usage 1 ;;
esac