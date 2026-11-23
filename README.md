# simenv

시뮬레이션 검증 환경 (Isaac Sim + ROS 2). **버전 매트릭스**로 관리된다.

- 이미지 정의: `dockerfiles/catalog.yml` (SSoT) + `dockerfiles/isaac-ros2/Dockerfile.template`
- 실행: `scripts/env/run.sh` (gui / stream / headless 3모드)
- devsys 의 `verify` 파이프라인에서 서브모듈로 참조된다

## 지원 매트릭스

| 이미지 키 | Isaac Sim | ROS 2 | Ubuntu | 상태 |
|---|---|---|---|---|
| `isaac-ros2-5.0-jazzy` | 5.0.0 | **jazzy** | 24.04 | **기본 권장** |
| `isaac-ros2-5.0-humble` | 5.0.0 | humble | 24.04 | 호환용 |

> 기본 조합은 **5.0 × jazzy** — devsys 의 `ros2-jazzy` 빌드 이미지와 정렬되어,
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
# 개발자 로컬 (창을 띄워 직접 조작)
./scripts/env/run.sh --image isaac-ros2-5.0-jazzy --mode gui

# 원격 개발자 (WebRTC 스트리밍)
ISAACSIM_HOST=<host-ip> ./scripts/env/run.sh --image isaac-ros2-5.0-jazzy --mode stream

# CI (headless, exit code 로 판정)
./scripts/env/run.sh --image isaac-ros2-5.0-jazzy --mode headless \
    --workspace ./scenarios --script /workspace/smoke.py --timeout 600
```

### 모드별 차이

| | gui | stream | headless |
|---|---|---|---|
| 디스플레이 | 로컬 X11 (`DISPLAY`) | 없음 (WebRTC) | 없음 |
| 판정 | 사용자 종료 | 사용자 종료 | **exit code + timeout** |
| 대상 | 로컬 개발자 | 원격 개발자 | **CI** |

> Isaac Sim 공식 문서 기준, 컨테이너 **GUI 모드는 실제 로컬 디스플레이에서만** 동작한다
> (원격/VNC/headless 에서는 Vulkan swapchain 초기화 실패). 원격은 `stream` 또는 `headless` 를 쓴다.

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
│   ├── isaac-ros2/Dockerfile.template   # ARG 기반 공통 템플릿
│   └── build-matrix.sh                  # 지원 조합만 빌드
└── scripts/env/
    ├── run.sh                           # gui / stream / headless
    ├── env_enter.sh                     # 실행 중 컨테이너 접속
    └── entry/                           # 셸 설정 (zsh/oh-my-zsh/tmux)
```