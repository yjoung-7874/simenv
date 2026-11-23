#!/usr/bin/env bash
# simenv/dockerfiles/build-matrix.sh
#
# catalog.yml 의 지원 조합을 이미지로 빌드한다.
#   - Dockerfile.template 에 catalog 의 버전/ROS 를 build-arg 로 주입
#   - 지원하지 않는 조합은 catalog 에 없으므로 애초에 빌드 대상이 아니다
#
# Usage:
#   build-matrix.sh [-h] [--platform <arch>] [--list] [--all] [image-key ...]
#
#   --platform : linux/amd64 (default) | linux/arm64/v8
#   --list     : 빌드 없이 catalog 의 이미지 목록만 출력
#   --all      : 카탈로그의 모든 이미지 빌드
#   image-key  : 개별 이미지 키 (예: isaac-ros2-5.0-jazzy). 생략 시 --all 필요
#
# Examples:
#   ./build-matrix.sh --list
#   ./build-matrix.sh isaac-ros2-5.0-jazzy
#   ./build-matrix.sh --all --platform linux/amd64

set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
CATALOG="${SCRIPT_DIR}/catalog.yml"
TEMPLATE_DIR="${SCRIPT_DIR}/isaac-ros2"

PLATFORM="linux/amd64"
LIST_ONLY=false
BUILD_ALL=false
KEYS=()

print_usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) print_usage 0 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --list) LIST_ONLY=true; shift ;;
    --all) BUILD_ALL=true; shift ;;
    -*) echo "ERROR: unknown option '$1'" >&2; print_usage 1 ;;
    *) KEYS+=("$1"); shift ;;
  esac
done

if [[ ! -f "$CATALOG" ]]; then
  echo "ERROR: catalog not found: $CATALOG" >&2
  exit 1
fi
if [[ ! -f "${TEMPLATE_DIR}/Dockerfile.template" ]]; then
  echo "ERROR: Dockerfile.template not found in ${TEMPLATE_DIR}" >&2
  exit 1
fi

# catalog.yml -> "key<TAB>image_name<TAB>base<TAB>version<TAB>ros<TAB>cuda"
read_catalog() {
  python3 - "$CATALOG" <<'PY'
import sys, yaml
cat = yaml.safe_load(open(sys.argv[1]))
bases = cat.get("bases", {})
for key, img in (cat.get("images") or {}).items():
    base = bases.get(img.get("base"), {})
    ver = str(img.get("version", ""))
    ver_spec = (base.get("versions") or {}).get(ver, {})
    ros = img.get("ros", "")
    if ver_spec and ros and ros not in ver_spec.get("ros", []):
        print(f"#WARN\t{key}\tROS {ros} not supported by {img.get('base')} {ver}", file=sys.stderr)
        continue
    print("\t".join([
        key,
        img.get("image_name", key),
        img.get("base", ""),
        ver,
        ros,
        str(ver_spec.get("cuda", "")),
    ]))
PY
}

mapfile -t ENTRIES < <(read_catalog)

if [[ "$LIST_ONLY" == true ]]; then
  printf "%-28s %-28s %-10s %-8s %s\n" "KEY" "IMAGE" "BASE" "ROS" "VERSION"
  for e in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r key image base ver ros cuda <<< "$e"
    printf "%-28s %-28s %-10s %-8s %s\n" "$key" "$image" "$base" "$ros" "$ver"
  done
  exit 0
fi

if [[ "$BUILD_ALL" == false && ${#KEYS[@]} -eq 0 ]]; then
  echo "ERROR: specify image keys or --all (see --list)" >&2
  print_usage 1
fi

tag_name="${PLATFORM//\//_}"

build_one() {
  local want="$1"
  local found=false
  for e in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r key image base ver ros cuda <<< "$e"
    [[ "$key" != "$want" ]] && continue
    found=true
    echo -e "\033[32;1m=== building ${image}:${tag_name} (${base} ${ver}, ROS ${ros})\033[0m"
    docker buildx build \
      --platform "$PLATFORM" \
      --build-arg "ISAAC_VERSION=${ver}" \
      --build-arg "ROS_DISTRO=${ros}" \
      -t "${image}:${tag_name}" \
      --load \
      -f "${TEMPLATE_DIR}/Dockerfile.template" \
      "${TEMPLATE_DIR}"
    echo -e "\033[32;1m=== ${image}:${tag_name} done\033[0m"
  done
  if [[ "$found" == false ]]; then
    echo "ERROR: unknown image key '${want}' (see --list)" >&2
    exit 1
  fi
}

if [[ "$BUILD_ALL" == true ]]; then
  for e in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r key _ <<< "$e"
    build_one "$key"
  done
else
  for k in "${KEYS[@]}"; do
    build_one "$k"
  done
fi