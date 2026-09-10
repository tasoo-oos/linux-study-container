# Linux 실습실

LXD 컨테이너 기반 Linux 실습 환경. 학생마다 독립된 Ubuntu 24.04 서버를 제공하고, 브라우저 터미널과 관리자 대시보드를 제공합니다.

## 구조

```
외부 (공인 IP)              호스트                        컨테이너
공인IP_0:*   ──DNAT──▶  Secondary IP 0  ──SNAT──▶  10.10.0.10 (server0)
공인IP_1:*   ──DNAT──▶  Secondary IP 1  ──SNAT──▶  10.10.0.11 (server1)
...

도메인:443   ──▶  Caddy  ──▶  127.0.0.1:3000 (Node.js 웹앱)
```

- **컨테이너**: `server0`부터 `server{n-1}`까지, 1~100개 설정 가능
- **웹 UI**: 브라우저 터미널(xterm.js), 관리자 대시보드
- **인증**: 컨테이너 리눅스 계정 비밀번호 (`/etc/shadow`) 직접 사용
- **초기 비밀번호**: `server{n}` (학생이 `passwd`로 변경 가능)

## 파일 구조

```
skkuding-linux/
├── README.md
├── setup.sh               # 전체 설치 스크립트
├── .env.example
├── app/
│   ├── server.js          # Node.js 백엔드 (Express + WebSocket + node-pty)
│   ├── package.json
│   ├── data.json.example  # 관리자 비밀번호, 별명, 외부 IP 저장 형식
│   ├── scripts/
│   │   └── create-containers.sh  # 컨테이너 생성/재생성 스크립트
│   └── public/
│       ├── index.html     # 학생 접속 페이지 (서버 선택 → 비밀번호 입력)
│       ├── terminal.html  # xterm.js 터미널
│       └── admin.html     # 관리자 대시보드
└── config/
    ├── lxd-classroom.service.template  # systemd 서비스 템플릿
    ├── Caddyfile.template              # Caddy 설정 템플릿
    └── abuse-block.nft                 # 공통 포트 차단 규칙 (25, 6881-6889)
```

## 설치

### 전제 조건

- Oracle Cloud (또는 기타) VM
- RAM: 컨테이너 수 × `CONTAINER_MEMORY`(기본 1536MB)를 감안 (초과 시 swap 사용)
- `CONTAINER_COUNT` 개수만큼 Secondary Private IP + 각각 공인 IP 할당
- 도메인 및 DNS 설정 완료
- `apt-get` 또는 `dnf` 사용 가능
- NetworkManager(`nmcli`) 사용 환경
- 설치 및 운영에 사용하는 계정이 `sudo`를 비밀번호 없이 실행할 수 있는 `NOPASSWD` 권한 보유

### 빠른 설치

**1. `.env` 파일 작성**

```bash
cp .env.example .env
nano .env
```

`.env` 예시:

```bash
DOMAIN="linux.example.com"      # 웹 UI 도메인
HOST_IFACE="enp0s6"             # 호스트 외부 NIC 이름 (ip a로 확인)
INSTALL_USER="ubuntu"           # 웹앱을 실행할 서버 사용자
CONTAINER_COUNT="10"            # 1~100
CONTAINER_IP_OFFSET="10"        # 내부 IP 시작 옥텟

SECONDARY_IPS=(
  "10.0.10.100"   # 클라우드에서 할당한 Secondary IP
  "10.0.10.101"
  ...
)
```

**2. 설치 실행**

```bash
chmod +x setup.sh app/scripts/create-containers.sh
bash setup.sh
```

**3. 외부 IP 업데이트**

```bash
# /opt/lxd-classroom/data.json 편집
# externalIps에 클라우드에서 할당받은 공인 IP 입력
sudo nano /opt/lxd-classroom/data.json
```

---

### 수동 설치

#### 1. LXD

```bash
sudo apt-get install -y lxd lxd-client
# 또는
sudo dnf install -y lxd lxd-client

sudo lxd init --minimal
lxc network set lxdbr0 ipv4.address 10.10.0.1/24
lxc network set lxdbr0 ipv4.nat true
lxc network set lxdbr0 ipv4.dhcp true
```

#### 2. Node.js 22

```bash
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list
sudo apt-get update && sudo apt-get install -y nodejs
```

#### 3. 앱

```bash
sudo mkdir -p /opt/lxd-classroom/public /opt/lxd-classroom/scripts
sudo cp app/server.js /opt/lxd-classroom/
sudo cp app/package.json /opt/lxd-classroom/
sudo cp app/public/* /opt/lxd-classroom/public/
sudo cp app/scripts/create-containers.sh /opt/lxd-classroom/scripts/
sudo chmod +x /opt/lxd-classroom/scripts/create-containers.sh
sudo cp app/data.json.example /opt/lxd-classroom/data.json
cd /opt/lxd-classroom && sudo npm install
sed \
  -e "s/__RUN_USER__/ubuntu/g" \
  -e "s/__RUN_GROUP__/ubuntu/g" \
  -e "s/__RUNTIME_GROUP__/lxd/g" \
  -e "s/__RUNTIME_UNIT__/snap.lxd.daemon.service/g" \
  -e "s/__CONTAINER_RUNTIME__/lxd/g" \
  -e "s/__RUNTIME_CLIENT__/lxc/g" \
  -e "s/__CONTAINER_COUNT__/10/g" \
  -e "s/__CONTAINER_IP_OFFSET__/10/g" \
  -e "s/__CONTAINER_IP_PREFIX__/10.10.0/g" \
  -e "s/__CONTAINER_MEMORY__/1536MB/g" \
  -e "s/__CONTAINER_SWAP__/true/g" \
  -e "s|__CONTAINER_EXTRA_PACKAGES__||g" \
  -e "s/__CONTAINER_SSH_ENABLED__/0/g" \
  -e "s|__CONTAINER_IMAGE__|ubuntu:24.04|g" \
  -e "s/__LXD_BRIDGE_NAME__/lxdbr0/g" \
  -e "s/__LXD_BRIDGE_IP__/10.10.0.1/g" \
  -e "s|__STORAGE_CONTAINERS_PATH__|/var/snap/lxd/common/lxd/storage-pools/default/containers|g" \
  -e "s/__BIND_ADDRESS__/127.0.0.1/g" \
  config/lxd-classroom.service.template | sudo tee /etc/systemd/system/lxd-classroom.service
sudo systemctl daemon-reload
sudo systemctl enable --now lxd-classroom
```

> Incus로 수동 설치하는 경우 `CONTAINER_RUNTIME=incus`, `RUNTIME_CLIENT=incus`,
> `RUNTIME_GROUP=incus-admin`, `RUNTIME_UNIT=incus.socket`, `CONTAINER_IMAGE=images:ubuntu/noble`,
> `LXD_BRIDGE_NAME=incusbr0`, `STORAGE_CONTAINERS_PATH=/var/lib/incus/storage-pools/default/containers`로 치환하세요.
> `bash setup.sh`를 쓰면 이 치환이 자동으로 처리됩니다.

#### 4. Caddy

```bash
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update && sudo apt-get install -y caddy
sed "s/__DOMAIN__/linux.example.com/g" config/Caddyfile.template | sudo tee /etc/caddy/Caddyfile
```

#### 5. Secondary IP 추가 (NetworkManager)

```bash
# 각 Secondary IP를 호스트 NIC에 추가
CONN=$(nmcli connection show --active | grep enp0s6 | awk '{print $1}')
for IP in 10.0.10.100 10.0.10.101 ...; do
  sudo nmcli connection modify "$CONN" +ipv4.addresses "${IP}/24"
done
sudo nmcli connection up "$CONN"
```

#### 6. nftables

```bash
# abuse-block.nft는 템플릿입니다. 런타임 브리지 이름으로 치환하세요.
#   LXD: lxdbr0, Incus: incusbr0
sed "s/__LXD_BRIDGE_NAME__/lxdbr0/g" config/abuse-block.nft | sudo tee /etc/nftables/abuse-block.nft
sudo nft -f /etc/nftables/abuse-block.nft

# student-nat.nft는 ENABLE_PUBLIC_IPS=1일 때 .env 기준으로 자동 생성
echo 'include "/etc/nftables/student-nat.nft"' | sudo tee -a /etc/nftables.conf
echo 'include "/etc/nftables/abuse-block.nft"' | sudo tee -a /etc/nftables.conf
sudo systemctl enable nftables

# br_netfilter (abuse 차단 규칙에 필요)
echo 'br_netfilter' | sudo tee /etc/modules-load.d/br_netfilter.conf
sudo modprobe br_netfilter
```

> `abuse-block.nft`(SMTP/BitTorrent 차단)는 `ENABLE_PUBLIC_IPS` 값과 무관하게 적용됩니다.

#### 7. 컨테이너 생성

```bash
CONTAINER_COUNT=10 \
CONTAINER_IP_OFFSET=10 \
LXD_BRIDGE_IP=10.10.0.1 \
bash app/scripts/create-containers.sh
```

---

## 환경별 수정 사항

다른 서버 환경에 설치 시 수정이 필요한 파일과 항목:

| 파일 | 수정 항목 |
|------|----------|
| `.env` | `DOMAIN`, `HOST_IFACE`, `INSTALL_USER`, `CONTAINER_COUNT`, `CONTAINER_IP_OFFSET`, `SECONDARY_IPS` |
| `.env` | `CONTAINER_RUNTIME`(`lxd`/`incus`), `CONTAINER_MEMORY`, `CONTAINER_SWAP`, `CONTAINER_EXTRA_PACKAGES`, `CONTAINER_SSH_ENABLED` |
| `.env` | `LXD_BRIDGE_IP`, `LXD_BRIDGE_SUBNET`, `CONTAINER_IP_PREFIX`, `BIND_ADDRESS`, `ENABLE_PUBLIC_IPS`, `ENABLE_CADDY` |
| `app/data.json` (설치 후) | `externalIps` (공인 IP) |

주요 변수:

- `CONTAINER_RUNTIME`: `lxd`(기본, snap 필요) 또는 `incus`(Zabbly apt 저장소, snap 불필요).
- `CONTAINER_MEMORY` / `CONTAINER_SWAP`: 컨테이너 메모리 제한과 swap.
  `CONTAINER_SWAP=true`는 메모리와 같은 크기를 뜻하며, Incus(cgroup2)에서는 자동으로 바이트 값으로 변환됩니다.
- `CONTAINER_EXTRA_PACKAGES`: 생성 시 컨테이너에 설치할 패키지 목록(공백 구분).
- `CONTAINER_SSH_ENABLED`: `1`이면 sshd 활성화, 기본 `0`(비활성). openssh-server는 설치됩니다.
- `ENABLE_PUBLIC_IPS=0` + `ENABLE_CADDY=0`: 웹 터미널 전용 모드. `BIND_ADDRESS=0.0.0.0`으로 노출.

> **참고**: 컨테이너 내부 네트워크와 브리지는 외부 NIC 대역과 겹치지 않으면 됩니다.
> `config/` 안의 템플릿/규칙 파일은 `setup.sh`가 읽어서 실제 설정 파일을 생성합니다.

---

## 관리

### 웹 UI
- 학생 접속: `https://도메인`
- 관리자: `https://도메인/admin.html` (초기 비밀번호: `admin`)

### 컨테이너 직접 접근 (복구용)
```bash
lxc exec server3 -- bash        # 직접 쉘
lxc restart server3             # 재시작
lxc stop server3 && lxc start server3
```

### 서비스 관리
```bash
sudo systemctl status lxd-classroom
sudo journalctl -u lxd-classroom -f    # 실시간 로그
sudo systemctl restart lxd-classroom
```

### 컨테이너 리소스 현황
```bash
btop                            # 전체 리소스
lxc list                        # 컨테이너 상태
```

---

## 기술 스택

- **LXD** — 컨테이너 관리
- **Ubuntu 24.04** — 컨테이너 OS
- **Node.js 22** — 백엔드 (Express, ws, node-pty)
- **xterm.js** — 브라우저 터미널
- **Caddy** — 리버스 프록시 + 자동 TLS
- **nftables** — DNAT/SNAT, 포트 차단
- **NetworkManager** — Secondary IP 관리

## 보안 설정

- 컨테이너당 메모리 하드 캡 (`limits.memory`, 기본 `CONTAINER_MEMORY=1536MB`)
- 컨테이너 swap 허용 (`limits.memory.swap`; Incus/cgroup2에서는 메모리와 같은 바이트 값으로 변환)
- 컨테이너별 독립 systemd/rootfs/네트워크 네임스페이스 (호스트 커널 공유)
- 포트 25/465/587 (SMTP) 차단
- 포트 6881-6889 (BitTorrent) 차단
- 컨테이너 격리 — 한 컨테이너 문제가 다른 컨테이너에 영향 없음
