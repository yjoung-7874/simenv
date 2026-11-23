# Legacy: isaac_ros2 (단일 Dockerfile)

Isaac Sim 4.5 + ROS 2 Humble 단일 이미지. **더 이상 유지보수하지 않는다.**

대체 경로:

```bash
../build-matrix.sh isaac-ros2-4.5-humble
```

새 환경은 `catalog.yml` 에 추가한다 (버전 매트릭스).
이 디렉토리는 참고용으로만 남긴다 (기존 커스터마이징 — nav2/rviz/gazebo, dynamixel,
colcon-ros-bundle 등 — 이 필요하면 `isaac-ros2/Dockerfile.template` 에 옵션으로 이식한다).
