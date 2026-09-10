#!/bin/bash
# Linux 실습실 설치 스크립트
# Ubuntu / Debian / Oracle Linux / Amazon Linux / Rocky Linux / Fedora 기준
# 실행 전에 .env 작성 필요

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "오류: $ENV_FILE 파일이 없습니다."
  echo "먼저 .env.example을 복사해 .env를 작성하세요."
  exit 1
fi

# Declared empty so ${#SECONDARY_IPS[@]} is safe under `set -u` when .env
# leaves it undefined; .env replaces it when it does define the array.
SECONDARY_IPS=()

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

DOMAIN="${DOMAIN:-}"
HOST_IFACE="${HOST_IFACE:-}"
INSTALL_USER="${INSTALL_USER:-${SUDO_USER:-$USER}}"
CONTAINER_COUNT="${CONTAINER_COUNT:-10}"
CONTAINER_IP_OFFSET="${CONTAINER_IP_OFFSET:-10}"
LXD_BRIDGE_IP="${LXD_BRIDGE_IP:-10.10.0.1}"
LXD_BRIDGE_SUBNET="${LXD_BRIDGE_SUBNET:-10.10.0.0/24}"
CONTAINER_IP_PREFIX="${CONTAINER_IP_PREFIX:-${LXD_BRIDGE_IP%.*}}"
CONTAINER_MEMORY="${CONTAINER_MEMORY:-1536MB}"
CONTAINER_SWAP="${CONTAINER_SWAP:-true}"
CONTAINER_EXTRA_PACKAGES="${CONTAINER_EXTRA_PACKAGES:-}"
CONTAINER_SSH_ENABLED="${CONTAINER_SSH_ENABLED:-0}"
BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"
ENABLE_PUBLIC_IPS="${ENABLE_PUBLIC_IPS:-1}"
ENABLE_CADDY="${ENABLE_CADDY:-1}"

# 컨테이너 런타임: lxd (기본) 또는 incus (snap 없이 사용 가능한 LXD 포크)
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-lxd}"
LXD_BRIDGE_NAME="${LXD_BRIDGE_NAME:-}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-}"
CONTAINER_RUNTIME_GROUP="${CONTAINER_RUNTIME_GROUP:-}"
STORAGE_CONTAINERS_PATH="${STORAGE_CONTAINERS_PATH:-}"
RUNTIME_UNIT="${RUNTIME_UNIT:-}"

case "$CONTAINER_RUNTIME" in
  incus)
    RUNTIME_CLIENT="${RUNTIME_CLIENT:-incus}"
    RUNTIME_DAEMON="${RUNTIME_DAEMON:-incusd}"
    SERVER_INIT_MODE="incus"
    RUNTIME_UNIT="${RUNTIME_UNIT:-incus.socket}"
    LXD_BRIDGE_NAME="${LXD_BRIDGE_NAME:-incusbr0}"
    CONTAINER_IMAGE="${CONTAINER_IMAGE:-images:ubuntu/noble}"
    CONTAINER_RUNTIME_GROUP="${CONTAINER_RUNTIME_GROUP:-incus-admin}"
    STORAGE_CONTAINERS_PATH="${STORAGE_CONTAINERS_PATH:-/var/lib/incus/storage-pools/default/containers}"
    ;;
  lxd)
    RUNTIME_CLIENT="${RUNTIME_CLIENT:-lxc}"
    RUNTIME_DAEMON="${RUNTIME_DAEMON:-lxd}"
    SERVER_INIT_MODE="lxd"
    RUNTIME_UNIT="${RUNTIME_UNIT:-snap.lxd.daemon.service}"
    LXD_BRIDGE_NAME="${LXD_BRIDGE_NAME:-lxdbr0}"
    CONTAINER_IMAGE="${CONTAINER_IMAGE:-ubuntu:24.04}"
    CONTAINER_RUNTIME_GROUP="${CONTAINER_RUNTIME_GROUP:-lxd}"
    STORAGE_CONTAINERS_PATH="${STORAGE_CONTAINERS_PATH:-/var/snap/lxd/common/lxd/storage-pools/default/containers}"
    ;;
  *)
    echo "오류: CONTAINER_RUNTIME은 lxd 또는 incus 여야 합니다."
    exit 1
    ;;
esac

# Incus(cgroup2 + 하드 메모리 제한)에서는 boolean true가 swap 0이 되므로
# true면 메모리 제한과 같은 크기의 swap 바이트 값으로 변환한다.
# LXD는 이 키를 bool로만 검증하므로 바이트 값을 넘기면 안 된다.
if [[ "$CONTAINER_RUNTIME" == "incus" && "$CONTAINER_SWAP" == "true" ]]; then
  CONTAINER_SWAP="$CONTAINER_MEMORY"
fi

if [[ "$ENABLE_CADDY" == "0" && "$BIND_ADDRESS" == "127.0.0.1" ]]; then
  echo "경고: ENABLE_CADDY=0 인데 BIND_ADDRESS=127.0.0.1 이라 외부에서 접속할 수 없습니다."
  echo "      .env에 BIND_ADDRESS=0.0.0.0 을 설정하세요."
fi

if [[ "$ENABLE_PUBLIC_IPS" != "1" && "$ENABLE_PUBLIC_IPS" != "0" ]]; then
  echo "오류: ENABLE_PUBLIC_IPS는 0 또는 1이어야 합니다."
  exit 1
fi

if [[ "$ENABLE_CADDY" != "1" && "$ENABLE_CADDY" != "0" ]]; then
  echo "오류: ENABLE_CADDY는 0 또는 1이어야 합니다."
  exit 1
fi

if [[ "$ENABLE_CADDY" == "1" && -z "$DOMAIN" ]]; then
  echo "오류: DOMAIN은 .env에 반드시 설정해야 합니다. (ENABLE_CADDY=0이면 불필요)"
  exit 1
fi

if [[ "$ENABLE_PUBLIC_IPS" == "1" && -z "$HOST_IFACE" ]]; then
  echo "오류: HOST_IFACE는 .env에 반드시 설정해야 합니다. (ENABLE_PUBLIC_IPS=0이면 불필요)"
  exit 1
fi

if [[ -z "$INSTALL_USER" ]]; then
  echo "오류: INSTALL_USER는 .env에 반드시 설정해야 합니다."
  exit 1
fi

if ! id "$INSTALL_USER" >/dev/null 2>&1; then
  echo "오류: INSTALL_USER '$INSTALL_USER' 사용자가 서버에 없습니다."
  exit 1
fi

if ! [[ "$CONTAINER_COUNT" =~ ^[0-9]+$ ]] || (( CONTAINER_COUNT < 1 || CONTAINER_COUNT > 100 )); then
  echo "오류: CONTAINER_COUNT는 1~100 범위의 정수여야 합니다."
  exit 1
fi

if ! [[ "$CONTAINER_IP_OFFSET" =~ ^[0-9]+$ ]] || (( CONTAINER_IP_OFFSET < 2 || CONTAINER_IP_OFFSET > 254 )); then
  echo "오류: CONTAINER_IP_OFFSET는 2~254 범위의 정수여야 합니다."
  exit 1
fi

if [[ "$ENABLE_PUBLIC_IPS" == "1" && ${#SECONDARY_IPS[@]} -ne $CONTAINER_COUNT ]]; then
  echo "오류: SECONDARY_IPS 개수는 CONTAINER_COUNT와 같아야 합니다. 현재 ${#SECONDARY_IPS[@]}개 / 설정값 ${CONTAINER_COUNT}개입니다."
  exit 1
fi

CONTAINER_IPS=()
for i in $(seq 0 $((CONTAINER_COUNT - 1))); do
  CONTAINER_IPS+=("${CONTAINER_IP_PREFIX}.$((CONTAINER_IP_OFFSET + i))")
done

if (( CONTAINER_IP_OFFSET + CONTAINER_COUNT - 1 > 254 )); then
  echo "오류: CONTAINER_IP_OFFSET + CONTAINER_COUNT - 1 이 254를 초과할 수 없습니다."
  exit 1
fi

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
else
  echo "오류: /etc/os-release를 찾을 수 없습니다."
  exit 1
fi

PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
else
  echo "오류: apt-get 또는 dnf를 찾을 수 없습니다."
  exit 1
fi

if [[ ":$PATH:" != *":/snap/bin:"* ]]; then
  export PATH="$PATH:/snap/bin"
fi

RUNTIME_CLIENT_BIN=""
RUNTIME_DAEMON_BIN=""

NFTABLES_CONF="/etc/sysconfig/nftables.conf"
if [[ "$PKG_MGR" == "apt" ]]; then
  NFTABLES_CONF="/etc/nftables.conf"
fi

APT_UPDATED=0
DNF_UPDATED=0

apt_update() {
  if [[ "$APT_UPDATED" -eq 0 ]]; then
    sudo apt-get update
    APT_UPDATED=1
  fi
}

dnf_makecache() {
  if [[ "$DNF_UPDATED" -eq 0 ]]; then
    sudo dnf -y makecache
    DNF_UPDATED=1
  fi
}

pkg_install() {
  if [[ "$PKG_MGR" == "apt" ]]; then
    apt_update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else
    dnf_makecache
    sudo dnf install -y "$@"
  fi
}

ensure_snapd() {
  if command -v snap >/dev/null 2>&1; then
    return
  fi

  if [[ "$PKG_MGR" == "apt" ]]; then
    pkg_install snapd
  else
    pkg_install snapd
  fi
}

ensure_snap_path() {
  if [[ ! -e /snap ]]; then
    sudo ln -s /var/lib/snapd/snap /snap
  fi
}

wait_for_runtime_client() {
  local tries=0
  while (( tries < 30 )); do
    if command -v "$RUNTIME_CLIENT" >/dev/null 2>&1; then
      return
    fi
    sleep 1
    tries=$((tries + 1))
  done

  echo "오류: $RUNTIME_CLIENT 명령을 찾을 수 없습니다. $CONTAINER_RUNTIME 설치가 완료되지 않았습니다."
  exit 1
}

resolve_runtime_binaries() {
  local candidate

  RUNTIME_CLIENT_BIN=""
  for candidate in \
    "/usr/bin/$RUNTIME_CLIENT" \
    "/usr/local/bin/$RUNTIME_CLIENT" \
    "/snap/bin/$RUNTIME_CLIENT" \
    "/var/lib/snapd/snap/bin/$RUNTIME_CLIENT" \
    "$(command -v "$RUNTIME_CLIENT" 2>/dev/null || true)"
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      RUNTIME_CLIENT_BIN="$candidate"
      break
    fi
  done

  RUNTIME_DAEMON_BIN=""
  for candidate in \
    "/usr/bin/$RUNTIME_DAEMON" \
    "/usr/local/bin/$RUNTIME_DAEMON" \
    "/snap/bin/$RUNTIME_DAEMON" \
    "/var/lib/snapd/snap/bin/$RUNTIME_DAEMON" \
    "/opt/incus/bin/$RUNTIME_DAEMON" \
    "$(command -v "$RUNTIME_DAEMON" 2>/dev/null || true)"
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      RUNTIME_DAEMON_BIN="$candidate"
      break
    fi
  done

  if [[ -z "$RUNTIME_CLIENT_BIN" ]]; then
    echo "오류: $RUNTIME_CLIENT 실행 파일을 찾을 수 없습니다."
    exit 1
  fi
}

enable_extra_repos() {
  if [[ "$PKG_MGR" != "dnf" ]]; then
    return
  fi

  case "${ID:-}" in
    oracle|ol)
      sudo dnf install -y oracle-epel-release-el9 2>/dev/null || true
      sudo dnf config-manager --set-enabled ol9_codeready_builder 2>/dev/null || true
      sudo dnf config-manager --enable ol9_developer_EPEL 2>/dev/null || true
      ;;
    rocky|almalinux|rhel|centos)
      sudo dnf install -y epel-release 2>/dev/null || true
      sudo dnf config-manager --set-enabled crb 2>/dev/null || \
      sudo dnf config-manager --set-enabled powertools 2>/dev/null || true
      ;;
    amzn)
      sudo dnf config-manager --set-enabled crb 2>/dev/null || true
      ;;
    fedora)
      :
      ;;
  esac
}

install_lxd() {
  if [[ "$CONTAINER_RUNTIME" == "incus" ]]; then
    install_incus
  else
    install_lxd_snap
  fi

  wait_for_runtime_client
  resolve_runtime_binaries
  sudo usermod -aG "$CONTAINER_RUNTIME_GROUP" "$INSTALL_USER" 2>/dev/null || true
}

install_lxd_snap() {
  if snap list lxd >/dev/null 2>&1 && [[ -x /snap/bin/lxc ]]; then
    echo "=== 1. LXD 설치 (이미 설치됨) ==="
    return
  fi

  echo "=== 1. LXD 설치 (snap) ==="

  ensure_snapd
  sudo systemctl enable --now snapd.socket
  ensure_snap_path

  # Ubuntu ships an `lxd-installer` stub at /usr/sbin/lxc that shadows the snap
  # binary and tries to install LXD on first use. Remove it so the snap wins.
  if [[ "$PKG_MGR" == "apt" ]]; then
    sudo apt-get remove -y lxd-installer >/dev/null 2>&1 || true
  fi

  if ! snap list lxd >/dev/null 2>&1; then
    sudo snap install lxd
  fi

  if systemctl list-unit-files | grep -q '^snap\.lxd\.daemon\.service'; then
    sudo systemctl enable --now snap.lxd.daemon
  fi
}

install_incus() {
  if command -v incus >/dev/null 2>&1; then
    echo "=== 1. Incus 설치 (이미 설치됨) ==="
    return
  fi

  echo "=== 1. Incus 설치 (Zabbly apt 저장소) ==="

  if [[ "$PKG_MGR" != "apt" ]]; then
    echo "오류: Incus 설치(Zabbly 저장소)는 현재 apt 기반 시스템만 지원합니다."
    exit 1
  fi

  pkg_install ca-certificates curl gnupg lsb-release

  if [[ ! -f /etc/apt/keyrings/zabbly.gpg ]]; then
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.zabbly.com/key.asc | \
      sudo gpg --dearmor --yes -o /etc/apt/keyrings/zabbly.gpg
  fi

  local codename="${VERSION_CODENAME:-}"
  if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -sc)"
  fi
  if [[ -z "$codename" ]]; then
    echo "오류: 배포판 codename을 확인할 수 없습니다."
    exit 1
  fi

  echo "deb [signed-by=/etc/apt/keyrings/zabbly.gpg] https://pkgs.zabbly.com/incus/stable ${codename} main" | \
    sudo tee /etc/apt/sources.list.d/zabbly-incus-stable.list >/dev/null
  APT_UPDATED=0
  pkg_install incus
}

install_node() {
  if command -v node >/dev/null 2>&1; then
    return
  fi

  echo "=== 2. Node.js 설치 ==="

  if [[ "$PKG_MGR" == "apt" ]]; then
    pkg_install ca-certificates curl gnupg
    if [[ ! -f /etc/apt/keyrings/nodesource.gpg ]]; then
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
        sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    fi
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | \
      sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
    APT_UPDATED=0
    pkg_install nodejs
  else
    pkg_install ca-certificates curl gnupg2 dnf-plugins-core
    curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
    DNF_UPDATED=0
    pkg_install nodejs
  fi
}

install_caddy() {
  if [[ "$ENABLE_CADDY" != "1" ]]; then
    return
  fi

  if command -v caddy >/dev/null 2>&1; then
    return
  fi

  echo "=== 4. Caddy 설치 ==="

  if [[ "$PKG_MGR" == "apt" ]]; then
    pkg_install debian-keyring debian-archive-keyring apt-transport-https ca-certificates curl gnupg
    if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    fi
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
      sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    APT_UPDATED=0
    pkg_install caddy
  else
    pkg_install dnf-plugins-core
    if ! sudo dnf copr list --enabled 2>/dev/null | grep -q '@caddy/caddy'; then
      sudo dnf copr enable -y @caddy/caddy
    fi
    DNF_UPDATED=0
    pkg_install caddy
  fi
}

install_platform_tools() {
  echo "=== 3. 기본 패키지 설치 ==="

  if [[ "$PKG_MGR" == "apt" ]]; then
    if [[ "$ENABLE_PUBLIC_IPS" == "1" ]]; then
      pkg_install build-essential curl gawk jq make nftables network-manager python3
    else
      pkg_install build-essential curl gawk jq make nftables python3
    fi
  else
    enable_extra_repos
    if [[ "$ENABLE_PUBLIC_IPS" == "1" ]]; then
      pkg_install curl gcc gcc-c++ gawk jq make nftables NetworkManager python3
    else
      pkg_install curl gcc gcc-c++ gawk jq make nftables python3
    fi
  fi
}

configure_lxd() {
  resolve_runtime_binaries

  # wait until the daemon API answers before doing anything
  local tries=0
  while (( tries < 30 )); do
    if sudo "$RUNTIME_CLIENT_BIN" query /1.0 >/dev/null 2>&1; then
      break
    fi
    sleep 2
    tries=$((tries + 1))
  done

  if ! sudo "$RUNTIME_CLIENT_BIN" query /1.0 >/dev/null 2>&1; then
    echo "오류: $CONTAINER_RUNTIME 데몬이 응답하지 않습니다."
    exit 1
  fi

  # A fresh daemon already seeds the 'default' profile in its DB before init
  # runs, so that is not a valid "initialized" signal. The presence of the
  # 'default' storage pool (created by init) is.
  if ! sudo "$RUNTIME_CLIENT_BIN" storage list --format=csv -c n 2>/dev/null | grep -qx default; then
    if [[ "$SERVER_INIT_MODE" == "incus" ]]; then
      sudo "$RUNTIME_CLIENT_BIN" admin init --minimal
    else
      sudo "$RUNTIME_DAEMON_BIN" init --minimal
    fi
  fi

  sudo "$RUNTIME_CLIENT_BIN" network set "$LXD_BRIDGE_NAME" ipv4.address="${LXD_BRIDGE_IP}/24"
  sudo "$RUNTIME_CLIENT_BIN" network set "$LXD_BRIDGE_NAME" ipv4.nat=true
  sudo "$RUNTIME_CLIENT_BIN" network set "$LXD_BRIDGE_NAME" ipv4.dhcp=true
  sudo usermod -aG "$CONTAINER_RUNTIME_GROUP" "$INSTALL_USER" 2>/dev/null || true

  if [[ -d "/home/$INSTALL_USER" ]]; then
    sudo install -d -o "$INSTALL_USER" -g "$INSTALL_USER" "/home/$INSTALL_USER/.config"
  fi
}

install_app() {
  echo "=== 5. 앱 설치 ==="
  sudo mkdir -p /opt/lxd-classroom/public /opt/lxd-classroom/scripts
  sudo cp "$SCRIPT_DIR/app/server.js" /opt/lxd-classroom/
  sudo cp "$SCRIPT_DIR/app/package.json" /opt/lxd-classroom/
  sudo cp "$SCRIPT_DIR/app/public/"* /opt/lxd-classroom/public/
  sudo cp "$SCRIPT_DIR/app/scripts/create-containers.sh" /opt/lxd-classroom/scripts/
  sudo chmod +x /opt/lxd-classroom/scripts/create-containers.sh
  if [[ ! -f /opt/lxd-classroom/data.json ]]; then
    sudo cp "$SCRIPT_DIR/app/data.json.example" /opt/lxd-classroom/data.json
  fi

  (cd /opt/lxd-classroom && sudo npm install)
  sudo chown -R "$INSTALL_USER:$INSTALL_USER" /opt/lxd-classroom
}

configure_caddy() {
  if [[ "$ENABLE_CADDY" != "1" ]]; then
    echo "=== 5. Caddy 설정 (건너뜀: ENABLE_CADDY=0) ==="
    return
  fi

  sudo mkdir -p /var/lib/caddy /.config/caddy 2>/dev/null || true
  sudo useradd -r -s /usr/sbin/nologin caddy 2>/dev/null || \
  sudo useradd -r -s /sbin/nologin caddy 2>/dev/null || true

  sed \
    -e "s/__DOMAIN__/$DOMAIN/g" \
    "$SCRIPT_DIR/config/Caddyfile.template" | sudo tee /etc/caddy/Caddyfile >/dev/null
}

configure_networkmanager() {
  if [[ "$ENABLE_PUBLIC_IPS" != "1" ]]; then
    echo "=== 6. Secondary IP 설정 (건너뜀: ENABLE_PUBLIC_IPS=0) ==="
    return
  fi
  echo "=== 6. Secondary IP 설정 ==="

  if systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
    sudo systemctl enable --now NetworkManager
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    echo "오류: nmcli를 찾을 수 없습니다. 이 서버는 NetworkManager 기반이어야 합니다."
    exit 1
  fi

  CONN=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v iface="$HOST_IFACE" '$2 == iface { print $1; exit }')
  if [[ -z "$CONN" ]]; then
    echo "오류: 활성 NetworkManager connection을 찾을 수 없습니다. HOST_IFACE=$HOST_IFACE"
    exit 1
  fi

  for IP in "${SECONDARY_IPS[@]}"; do
    sudo nmcli connection modify "$CONN" +ipv4.addresses "${IP}/24"
  done
  sudo nmcli connection up "$CONN"
}

configure_nftables() {
  echo "=== 7. nftables 설정 ==="

  if ! command -v nft >/dev/null 2>&1; then
    echo "경고: nft 명령을 찾을 수 없습니다. nftables 설정을 건너뜁니다."
    return
  fi

  sudo mkdir -p /etc/nftables

  # 공통 abuse 차단 규칙 (SMTP/BitTorrent) — 공인 IP 모드와 웹 전용 모드 모두 적용
  sed -e "s|__LXD_BRIDGE_NAME__|$LXD_BRIDGE_NAME|g" \
    "$SCRIPT_DIR/config/abuse-block.nft" | sudo tee /etc/nftables/abuse-block.nft >/dev/null
  sudo nft -f /etc/nftables/abuse-block.nft

  sudo touch "$NFTABLES_CONF"
  sudo grep -q 'abuse-block' "$NFTABLES_CONF" 2>/dev/null || \
    sudo bash -c "echo 'include \"/etc/nftables/abuse-block.nft\"' >> '$NFTABLES_CONF'"

  if [[ "$ENABLE_PUBLIC_IPS" == "1" ]]; then
    cat > /tmp/student-nat-gen.nft << 'NFTEOF'
table inet student-nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
NFTEOF

    for i in "${!SECONDARY_IPS[@]}"; do
      echo "        iifname != \"$LXD_BRIDGE_NAME\" ip daddr ${SECONDARY_IPS[$i]} dnat to ${CONTAINER_IPS[$i]}" >> /tmp/student-nat-gen.nft
    done

    cat >> /tmp/student-nat-gen.nft << 'NFTEOF'
    }
    chain postrouting {
        type nat hook postrouting priority 95; policy accept;
NFTEOF

    for i in "${!SECONDARY_IPS[@]}"; do
      echo "        ip saddr ${CONTAINER_IPS[$i]} ip daddr != ${LXD_BRIDGE_SUBNET} snat to ${SECONDARY_IPS[$i]}" >> /tmp/student-nat-gen.nft
    done

    echo "    }
}" >> /tmp/student-nat-gen.nft

    sudo cp /tmp/student-nat-gen.nft /etc/nftables/student-nat.nft
    sudo nft -f /etc/nftables/student-nat.nft
    sudo grep -q 'student-nat' "$NFTABLES_CONF" 2>/dev/null || \
      sudo bash -c "echo 'include \"/etc/nftables/student-nat.nft\"' >> '$NFTABLES_CONF'"
  fi

  sudo systemctl enable --now nftables

  # 브리지를 오가는 트래픽도 netfilter가 보도록 br_netfilter 로드 (abuse 차단에 필요)
  echo 'br_netfilter' | sudo tee /etc/modules-load.d/br_netfilter.conf >/dev/null
  sudo modprobe br_netfilter

  # firewalld가 활성 상태면 브리지를 trusted 존에 추가
  # (미설정 시 firewalld가 호스트↔컨테이너 트래픽을 차단함)
  if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
    sudo firewall-cmd --zone=trusted --add-interface="$LXD_BRIDGE_NAME" --permanent
    sudo firewall-cmd --reload
  fi
}

configure_services() {
  echo "=== 8. systemd 서비스 등록 ==="

  # sed replacement is fragile: escape \, & and | in the package list
  local extra_sed="${CONTAINER_EXTRA_PACKAGES//\\/\\\\}"
  extra_sed="${extra_sed//&/\\&}"
  extra_sed="${extra_sed//|/\\|}"

  sed \
    -e "s/__RUN_USER__/$INSTALL_USER/g" \
    -e "s/__RUN_GROUP__/$INSTALL_USER/g" \
    -e "s/__RUNTIME_GROUP__/$CONTAINER_RUNTIME_GROUP/g" \
    -e "s/__RUNTIME_UNIT__/$RUNTIME_UNIT/g" \
    -e "s/__CONTAINER_RUNTIME__/$CONTAINER_RUNTIME/g" \
    -e "s/__RUNTIME_CLIENT__/$RUNTIME_CLIENT/g" \
    -e "s/__CONTAINER_COUNT__/$CONTAINER_COUNT/g" \
    -e "s/__CONTAINER_IP_OFFSET__/$CONTAINER_IP_OFFSET/g" \
    -e "s/__CONTAINER_IP_PREFIX__/$CONTAINER_IP_PREFIX/g" \
    -e "s/__CONTAINER_MEMORY__/$CONTAINER_MEMORY/g" \
    -e "s/__CONTAINER_SWAP__/$CONTAINER_SWAP/g" \
    -e "s|__CONTAINER_EXTRA_PACKAGES__|$extra_sed|g" \
    -e "s/__CONTAINER_SSH_ENABLED__/$CONTAINER_SSH_ENABLED/g" \
    -e "s|__CONTAINER_IMAGE__|$CONTAINER_IMAGE|g" \
    -e "s/__LXD_BRIDGE_NAME__/$LXD_BRIDGE_NAME/g" \
    -e "s/__LXD_BRIDGE_IP__/$LXD_BRIDGE_IP/g" \
    -e "s|__STORAGE_CONTAINERS_PATH__|$STORAGE_CONTAINERS_PATH|g" \
    -e "s/__BIND_ADDRESS__/$BIND_ADDRESS/g" \
    "$SCRIPT_DIR/config/lxd-classroom.service.template" | sudo tee /etc/systemd/system/lxd-classroom.service >/dev/null

  sudo systemctl daemon-reload
  sudo systemctl enable --now lxd-classroom
  if [[ "$ENABLE_CADDY" == "1" ]]; then
    sudo systemctl enable --now caddy
  fi
}

create_containers() {
  echo "=== 9. 컨테이너 생성 (약 5~10분) ==="
  sudo env \
    CONTAINER_RUNTIME="$CONTAINER_RUNTIME" \
    RUNTIME_CLIENT="$RUNTIME_CLIENT" \
    CONTAINER_COUNT="$CONTAINER_COUNT" \
    CONTAINER_IP_OFFSET="$CONTAINER_IP_OFFSET" \
    CONTAINER_IP_PREFIX="$CONTAINER_IP_PREFIX" \
    CONTAINER_MEMORY="$CONTAINER_MEMORY" \
    CONTAINER_SWAP="$CONTAINER_SWAP" \
    CONTAINER_EXTRA_PACKAGES="$CONTAINER_EXTRA_PACKAGES" \
    CONTAINER_SSH_ENABLED="$CONTAINER_SSH_ENABLED" \
    CONTAINER_IMAGE="$CONTAINER_IMAGE" \
    LXD_BRIDGE_NAME="$LXD_BRIDGE_NAME" \
    LXD_BRIDGE_IP="$LXD_BRIDGE_IP" \
    STORAGE_CONTAINERS_PATH="$STORAGE_CONTAINERS_PATH" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin" \
    bash /opt/lxd-classroom/scripts/create-containers.sh
}

install_lxd
install_node
install_platform_tools
install_caddy
configure_lxd
install_app
configure_caddy
configure_networkmanager
configure_nftables
configure_services
create_containers

echo ""
echo "✓ 설치 완료!"
echo "  패키지 관리자: $PKG_MGR"
echo "  컨테이너 런타임: $CONTAINER_RUNTIME"
echo "  컨테이너 수: $CONTAINER_COUNT"
if [[ "$ENABLE_CADDY" == "1" ]]; then
  echo "  웹 UI: https://${DOMAIN}"
else
  echo "  웹 UI: http://<호스트IP>:3000  (BIND_ADDRESS=${BIND_ADDRESS})"
fi
echo "  관리자 초기 비밀번호: admin"
echo ""
if [[ "$ENABLE_PUBLIC_IPS" == "1" ]]; then
  echo "※ data.json에서 externalIps를 실제 공인 IP로 업데이트하세요."
fi
