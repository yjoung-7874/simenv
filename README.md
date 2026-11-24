# simenv

시뮬레이션 검증 환경 (Isaac Sim + ROS 2 브리지). **버전 매트릭스**로 관리된다.

- 이미지 정의: `dockerfiles/catalog.yml` (SSoT) + `dockerfiles/isaac-ros2/Dockerfile.template`
- 실행: `scripts/env/run.sh` (gui / stream / headless / shell)
- devsys 의 `verify` 파이프라인에서 서브모듈로 참조된다

## 핵심: ROS 2 를 설치하지 않는다

Isaac Sim 은 **ROS 2 브리지 extension 과 내장 ROS 2 라이브러리**를 이미 포함한다.

```
/isaac-sim/exts/isaacsim.ros2.bridge/
├── humble/{lib,rclpy}
└── jazzy/{lib,rclpy}      ← 5.0 부터 jazzy 내장
```

따라서 이미지에 ROS 2 를 설치/빌드할 필요가 없다. 필요한 것은:

1. `ROS_DISTRO` 에 맞는 내장 라이브러리 경로 설정 (`/usr/local/bin/ros2-env`)
2. 브리지 extension 활성화 (`--/isaac/startup/ros_bridge_extension=isaacsim.ros2.bridge`) — **호출자가 넘긴다**
3. `--network=host` + DDS 설정 → 호스트/다른 컨테이너의 ROS 2 노드와 연결

```
[호스트 / 다른 컨테이너]              [Isaac Sim 컨테이너]
  mos_pub (ros2-jazzy 산출물) ──DDS──▶ isaacsim.ros2.bridge
  ros2 topic echo             ◀──DDS── (내장 jazzy 라이브러리)
```

## 지원 매트릭스

| 이미지 키 | Isaac Sim | ROS 2 브리지 | 베이스 |
|---|---|---|---|
| `isaac-ros2-5.0-jazzy` | 5.0.0 | **jazzy (내장)** | Ubuntu 22.04 / Python 3.11 |
| `isaac-ros2-5.0-humble` | 5.0.0 | humble (내장) | Ubuntu 22.04 / Python 3.11 |

> 기본 조합은 **5.0 × jazzy** — devsys 의 `ros2-jazzy` 빌드 이미지와 ROS 버전이 같아
> jazzy 로 빌드한 산출물을 버전 불일치 없이 시뮬에서 검증할 수 있다.
> Isaac Sim 5.0 부터 Isaac Sim 전용 extension 이 오픈소스로 공개되었다
> (Omniverse Kit 일부는 closed source).

## 빌드

```bash
cd dockerfiles
./build-matrix.sh --list                      # 지원 조합 확인
./build-matrix.sh isaac-ros2-5.0-jazzy        # 기본 조합 빌드
```

새 조합을 추가하려면 `catalog.yml` 만 수정한다 (Dockerfile 수정 불필요).
카탈로그에 없는 조합은 빌드 스크립트가 거부하므로, 지원하지 않는
Isaac/ROS 조합이 실수로 28GB 이미지로 양산되는 일을 막는다.

## 실행

```bash
# 브리지가 설정된 대화형 셸 (디버깅/직접 확인)
./scripts/env/run.sh --image isaac-ros2-5.0-jazzy --mode shell

# 개발자 로컬 (Isaac Sim GUI + 브리지)
./scripts/env/run.sh --image isaac-ros2-5.0-jazzy --mode gui

# 원격 개발자 (WebRTC 스트리밍)
ISAACSIM_HOST=<host-ip> ./scripts/env/run.sh --image isaac-ros2-5.0-jazzy --mode stream

# CI (headless, exit code 로 판정)
./scripts/env/run.sh --image isaac-ros2-5.0-jazzy --mode headless \
    --workspace ./scenarios --script /workspace/smoke.py --timeout 600
```

### 모드별 차이

| | gui | stream | headless | shell |
|---|---|---|---|---|
| 실행 | `isaac-sim.sh` | `runheadless.sh -v` | 스크립트 | bash |
| 디스플레이 | 로컬 X11 | WebRTC | 없음 | 없음 |
| 판정 | 사용자 종료 | 사용자 종료 | **exit code + timeout** | 사용자 종료 |
| 대상 | 로컬 개발자 | 원격 개발자 | **CI** | 디버깅 |

## 경계: simenv 는 런처다

`run.sh` 는 **컨테이너 런처**일 뿐이다. 어떤 시나리오를 실행하고 브리지
extension 을 켤지는 시나리오 소유자(예: `mos/sim/run-sim.sh`)가 `--` 뒤 인자로 넘긴다.

```bash
./scripts/env/run.sh --image isaac-ros2-5.0-jazzy --mode headless \
    --workspace ./sim --script "/isaac-sim/python.sh /workspace/bridge_smoke.py" \
    -- --/isaac/startup/ros_bridge_extension=isaacsim.ros2.bridge
```

브리지가 필요 없으면 `--` 를 생략하면 된다. 이렇게 하면 simenv 는
시나리오 내용을 몰라도 되고, 프로젝트가 자기 토픽/브리지 설정을 스스로 정한다.

### DDS 설정 (다중 NIC 환경)

호스트에 네트워크 인터페이스가 여러 개면 FastDDS 가 잘못된 인터페이스를 골라
**외부 노드와 전혀 통신이 안 되는** 증상이 생긴다 (컨테이너 내부 pub/sub 는 정상).
이미지에는 `/etc/simenv/fastdds.xml` 이 포함되어 있고 `run.sh` 가 기본으로 지정한다.
이 기본 프로필은 화이트리스트가 비어 있어 **모든 인터페이스**를 쓴다 — 단일 NIC
환경에서는 이대로 동작한다.

다중 NIC 환경(검증된 이 호스트: enp5s0 + eno1 + docker bridge 다수)에서는
인터페이스를 명시해야 외부와 통신된다. `dockerfiles/isaac-ros2/fastdds.xml` 의
`interfaceWhiteList` 주석을 풀고 실제 LAN 주소(예: `192.168.0.3`)를 넣은 뒤 재빌드한다.

```bash
# 검증 결과: 화이트리스트 없이는 컨테이너 내부 loopback 만 되고
#           호스트 ↔ 컨테이너 통신이 전혀 안 됨. 화이트리스트를 넣으면 통신됨.
```

### ROS 2 배포판 선택 (ROS_DISTRO)

`run.sh` 는 `ROS_DISTRO` 를 컨테이너에 **넘기지 않는다**. Isaac Sim 의
`setup_ros_env.sh` 가 `ROS_DISTRO` 를 비워둘 때만 내장 라이브러리 경로를 잡기
때문이다(값이 있으면 브리지가 `libament_index_cpp.so` 를 못 찾아 startup 실패).
대신 `run.sh` 가 Isaac Sim 실행 직전에 `/usr/local/bin/ros2-env <distro>` 를
소싱해 `LD_LIBRARY_PATH`/`PYTHONPATH`/`AMENT_PREFIX_PATH` 를 설정한다.

## 세션: Isaac 과 ROS 피어를 분리한다

시뮬레이터와 ROS 2 도구 환경은 **수명주기가 다르므로 컨테이너를 분리**한다.

| | Isaac 컨테이너 | ROS 피어 컨테이너 |
|---|---|---|
| 목적 | 시뮬레이터 런타임 | `ros2` CLI / 빌드 산출물 실행 |
| ROS | 브리지 번들 라이브러리만 | 정식 ROS 2 설치 |
| 이미지 | simenv 카탈로그 키 | **docker 태그** (출처 무관) |
| 런타임 필수 | ✅ | ❌ (없으면 no-ROS 모드) |

`scripts/session/session.sh` 는 두 컨테이너를 하나의 DDS 세션으로 묶는다.
**simenv 는 ROS 이미지의 출처를 모른다** — 태그 문자열만 받는다.

```bash
# Isaac + ROS 피어 (개발/CI)
./scripts/session/session.sh up --ros-image ros:jazzy

# Isaac 만 (no-ROS 모드) — 호스트의 mos dist 바이너리가 DDS 로 붙는다
./scripts/session/session.sh up --no-ros

# 이미 떠 있는 Isaac 에 ROS 피어만 붙인다
./scripts/session/session.sh up --no-sim --ros-image ros:jazzy
./scripts/session/session.sh exec -- ros2 topic list
./scripts/session/session.sh status
./scripts/session/session.sh down
```

DDS 계약(두 컨테이너 공통): `--network=host`, `ROS_DOMAIN_ID`,
`RMW_IMPLEMENTATION`, 선택적 `FASTRTPS_DEFAULT_PROFILES_FILE`.

> devsys 는 `configs/environments.yaml` 에서 역할→이미지를 해석해
> `--sim-image` / `--ros-image` 로 넘긴다. simenv 는 그 파일을 모른다.

## Python 버전 제약 (중요)

Isaac Sim 은 자체 Python 런타임을 쓴다 (5.0=3.11). 시스템 ROS 2 는
Ubuntu 24.04 기준 Python 3.12 이므로, **시스템 ROS 를 source 한 채로 브리지를 쓰면 rclpy 가 깨진다**.

- 기본 메시지 타입(`std_msgs`, `geometry_msgs` 등)만 쓰는 경우
  → Isaac Sim 내장 ROS 라이브러리 + 외부 노드는 시스템 ROS 로 실행. **DDS 가 전송을 담당**하므로 정상.
- 커스텀 메시지/패키지를 브리지에서 쓸 경우
  → Python 3.11 용 워크스페이스를 별도 빌드해야 한다 (후속 작업).

## 디렉토리

```
simenv/
├── dockerfiles/
│   ├── catalog.yml                      # 버전 매트릭스 SSoT
│   ├── isaac-ros2/
│   │   ├── Dockerfile.template          # ARG 기반 공통 템플릿
│   │   └── fastdds.xml                  # DDS 인터페이스 프로필
│   └── build-matrix.sh                  # 지원 조합만 빌드
├── scripts/env/
│   ├── run.sh                           # gui / stream / headless / shell
│   ├── env_enter.sh                     # 실행 중 컨테이너 접속
│   └── entry/                           # 셸 설정 (zsh/oh-my-zsh/tmux)
└── scripts/session/
    └── session.sh                       # Isaac + 선택적 ROS 피어 세션
```