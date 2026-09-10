#!/bin/bash
# 컨테이너 생성/재생성 스크립트
# 인자 없음 : 전체 생성 (CONTAINER_COUNT 기준)
# 인자 있음 : 지정한 ID만 생성  예) bash create-containers.sh 0 3 7
set -euo pipefail

CONTAINER_COUNT="${CONTAINER_COUNT:-10}"
CONTAINER_IP_OFFSET="${CONTAINER_IP_OFFSET:-10}"
LXD_BRIDGE_IP="${LXD_BRIDGE_IP:-10.10.0.1}"
CONTAINER_IP_PREFIX="${CONTAINER_IP_PREFIX:-${LXD_BRIDGE_IP%.*}}"
CONTAINER_MEMORY="${CONTAINER_MEMORY:-1536MB}"
CONTAINER_SWAP="${CONTAINER_SWAP:-true}"

# 컨테이너 런타임: lxd (기본) 또는 incus
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-lxd}"
LXD_BRIDGE_NAME="${LXD_BRIDGE_NAME:-}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-}"
STORAGE_CONTAINERS_PATH="${STORAGE_CONTAINERS_PATH:-}"

case "$CONTAINER_RUNTIME" in
  incus)
    RUNTIME_CLIENT="${RUNTIME_CLIENT:-incus}"
    RUNTIME_DAEMON="${RUNTIME_DAEMON:-incusd}"
    LXD_BRIDGE_NAME="${LXD_BRIDGE_NAME:-incusbr0}"
    CONTAINER_IMAGE="${CONTAINER_IMAGE:-images:ubuntu/noble}"
    STORAGE_CONTAINERS_PATH="${STORAGE_CONTAINERS_PATH:-/var/lib/incus/storage-pools/default/containers}"
    ;;
  lxd)
    RUNTIME_CLIENT="${RUNTIME_CLIENT:-lxc}"
    RUNTIME_DAEMON="${RUNTIME_DAEMON:-lxd}"
    LXD_BRIDGE_NAME="${LXD_BRIDGE_NAME:-lxdbr0}"
    CONTAINER_IMAGE="${CONTAINER_IMAGE:-ubuntu:24.04}"
    STORAGE_CONTAINERS_PATH="${STORAGE_CONTAINERS_PATH:-/var/snap/lxd/common/lxd/storage-pools/default/containers}"
    ;;
  *)
    echo "오류: CONTAINER_RUNTIME은 lxd 또는 incus 여야 합니다."
    exit 1
    ;;
esac

# Incus(cgroup2 + 하드 메모리 제한)에서만 boolean true를 바이트 값으로 변환한다.
# LXD는 limits.memory.swap을 bool로만 검증하므로 변환하면 설정이 실패한다.
if [[ "$CONTAINER_RUNTIME" == "incus" && "$CONTAINER_SWAP" == "true" ]]; then
  CONTAINER_SWAP="$CONTAINER_MEMORY"
fi

PATH="$PATH:/snap/bin"
CLIENT_BIN="$(command -v "$RUNTIME_CLIENT" 2>/dev/null || true)"
DAEMON_BIN="$(command -v "$RUNTIME_DAEMON" 2>/dev/null || true)"

if [[ -z "$CLIENT_BIN" && -x "/snap/bin/$RUNTIME_CLIENT" ]]; then
  CLIENT_BIN="/snap/bin/$RUNTIME_CLIENT"
fi

if [[ -z "$DAEMON_BIN" && -x "/snap/bin/$RUNTIME_DAEMON" ]]; then
  DAEMON_BIN="/snap/bin/$RUNTIME_DAEMON"
fi

if [[ -z "$CLIENT_BIN" ]]; then
  echo "오류: $RUNTIME_CLIENT 명령을 찾을 수 없습니다."
  exit 1
fi

# 생성할 컨테이너 ID 목록 결정
if [[ $# -gt 0 ]]; then
  IDS=("$@")
else
  IDS=()
  for i in $(seq 0 $((CONTAINER_COUNT - 1))); do
    IDS+=("$i")
  done
fi

setup_container() {
  local i="$1"
  local IP="${CONTAINER_IP_PREFIX}.$((CONTAINER_IP_OFFSET + i))"
  local PASS="server$i"

  echo "--- server$i 생성 중 (IP: $IP) ---"

  # 기존 컨테이너 및 고아 볼륨 정리
  # 1) CLI 방식 (정상 케이스)
  "$CLIENT_BIN" stop "server$i" --force 2>/dev/null < /dev/null || true
  "$CLIENT_BIN" delete "server$i" --force 2>/dev/null < /dev/null || true
  # 2) REST API 방식 (CLI가 부분 생성 상태를 인식 못할 때 대비)
  "$CLIENT_BIN" query -X DELETE "/1.0/instances/server$i" 2>/dev/null < /dev/null || true
  "$CLIENT_BIN" query -X DELETE "/1.0/storage-pools/default/volumes/container/server$i" 2>/dev/null < /dev/null || true
  # 3) 파일시스템 정리
  sudo rm -rf "${STORAGE_CONTAINERS_PATH}/server$i" 2>/dev/null || true
  # 4) DB 고아 레코드 직접 삭제 (type=0 은 container 볼륨)
  if [[ "$CONTAINER_RUNTIME" == "incus" ]]; then
    "$CLIENT_BIN" admin sql global \
      "DELETE FROM storage_volumes WHERE name='server$i' AND type=0 \
       AND storage_pool_id=(SELECT id FROM storage_pools WHERE name='default')" \
      2>/dev/null < /dev/null || true
  else
    "$DAEMON_BIN" sql global \
      "DELETE FROM storage_volumes WHERE name='server$i' AND type=0 \
       AND storage_pool_id=(SELECT id FROM storage_pools WHERE name='default')" \
      2>/dev/null < /dev/null || true
  fi

  # 컨테이너 생성 및 기본 설정
  "$CLIENT_BIN" launch "$CONTAINER_IMAGE" "server$i" --quiet < /dev/null
  "$CLIENT_BIN" config set "server$i" boot.autostart=true < /dev/null
  "$CLIENT_BIN" config set "server$i" boot.autostart.delay=3 < /dev/null
  "$CLIENT_BIN" config set "server$i" security.nesting=true < /dev/null
  "$CLIENT_BIN" config set "server$i" security.syscalls.intercept.mknod=true < /dev/null
  "$CLIENT_BIN" config set "server$i" security.syscalls.intercept.setxattr=true < /dev/null
  "$CLIENT_BIN" config set "server$i" limits.memory="$CONTAINER_MEMORY" < /dev/null
  "$CLIENT_BIN" config set "server$i" limits.memory.swap="$CONTAINER_SWAP" < /dev/null
  # eth0 may already exist from the default profile; the fallback tolerates both.
  # Static addressing is set via netplan below, so a failure here is non-fatal.
  "$CLIENT_BIN" config device add "server$i" eth0 nic nictype=bridged parent=$LXD_BRIDGE_NAME name=eth0 \
    ipv4.address="$IP" 2>/dev/null < /dev/null || \
  "$CLIENT_BIN" config device set "server$i" eth0 ipv4.address="$IP" < /dev/null 2>/dev/null || true

  # 부팅 대기 (최대 60초)
  for attempt in $(seq 1 30); do
    "$CLIENT_BIN" exec "server$i" -- true < /dev/null 2>/dev/null && break
    sleep 2
  done

  # 사용자 생성
  "$CLIENT_BIN" exec "server$i" -- useradd -m -s /bin/bash -G sudo server < /dev/null
  "$CLIENT_BIN" exec "server$i" -- bash -c "echo 'server:${PASS}' | chpasswd" < /dev/null
  "$CLIENT_BIN" exec "server$i" -- bash -c "echo server$i > /etc/hostname && hostname server$i" < /dev/null

  # 비루트 사용자도 ping을 쓸 수 있게 파일 capability 부여 (실패 시 setuid로 대체)
  "$CLIENT_BIN" exec "server$i" -- bash -c \
    "setcap cap_net_raw+ep /usr/bin/ping 2>/dev/null || chmod u+s /usr/bin/ping 2>/dev/null || true" \
    < /dev/null

  # cloud-init 비활성화
  "$CLIENT_BIN" exec "server$i" -- bash -c \
    "touch /etc/cloud/cloud-init.disabled && \
     systemctl disable cloud-init cloud-init-local cloud-config cloud-final 2>/dev/null || true" \
    < /dev/null

  # 네트워크 설정
  # 10-lxd.yaml (LXD 자동 생성)도 dhcp4:false로 덮어써서 DHCP 완전 차단
  "$CLIENT_BIN" exec "server$i" -- bash -c \
    "printf 'network:\n  version: 2\n  ethernets:\n    eth0:\n      dhcp4: false\n' \
     > /etc/netplan/10-lxd.yaml && chmod 600 /etc/netplan/10-lxd.yaml" < /dev/null

  # 정적 IP netplan 설정
  "$CLIENT_BIN" exec "server$i" -- bash -c "cat > /etc/netplan/50-cloud-init.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - ${IP}/24
      routes:
        - to: default
          via: ${LXD_BRIDGE_IP}
      nameservers:
        addresses: [${LXD_BRIDGE_IP}, 8.8.8.8]
NETPLAN
chmod 600 /etc/netplan/50-cloud-init.yaml" < /dev/null

  # netplan apply로 네트워크 및 DNS 설정 즉시 적용
  "$CLIENT_BIN" exec "server$i" -- netplan apply < /dev/null

  # 추가 패키지 설치 (선택: CONTAINER_EXTRA_PACKAGES)
  # 호스트 셸에서 확장/실행되지 않도록 --env로 넘기고 컨테이너 안에서 확장한다.
  if [[ -n "${CONTAINER_EXTRA_PACKAGES:-}" ]]; then
    echo "    추가 패키지 설치: $CONTAINER_EXTRA_PACKAGES"
    "$CLIENT_BIN" exec "server$i" \
      --env CONTAINER_EXTRA_PACKAGES="$CONTAINER_EXTRA_PACKAGES" \
      -- bash -c 'export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a; \
       apt-get update -qq && apt-get install -y -qq $CONTAINER_EXTRA_PACKAGES' \
      < /dev/null || echo "    경고: 추가 패키지 설치 실패 (계속 진행)"
  fi

  # SSH 서버 활성화 여부 (기본 비활성: CONTAINER_SSH_ENABLED=0)
  if [[ "${CONTAINER_SSH_ENABLED:-0}" == "1" ]]; then
    "$CLIENT_BIN" exec "server$i" -- bash -c \
      "systemctl enable --now ssh.socket 2>/dev/null || true; \
       systemctl enable --now ssh.service 2>/dev/null || true" \
      < /dev/null
  else
    "$CLIENT_BIN" exec "server$i" -- bash -c \
      "systemctl disable --now ssh.socket 2>/dev/null || true; \
       systemctl disable --now ssh.service 2>/dev/null || true" \
      < /dev/null
  fi

  # needrestart 무음 처리 (needrestart 미설치 이미지에서는 건너뜀)
  "$CLIENT_BIN" exec "server$i" -- bash -c \
    "if [ -f /etc/needrestart/needrestart.conf ]; then \
       grep -v 'nrconf{restart}' /etc/needrestart/needrestart.conf > /tmp/nr.conf; \
       echo '\$nrconf{restart} = q(a);' >> /tmp/nr.conf; \
       mv /tmp/nr.conf /etc/needrestart/needrestart.conf; \
     fi" \
    < /dev/null

  echo "server$i 완료 (IP: $IP, PW: $PASS)"
}

for id in "${IDS[@]}"; do
  setup_container "$id"
done

echo "완료: ${IDS[*]}"
