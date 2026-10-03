#!/usr/bin/env bash
# =============================================================================
# create-lxc.sh — Proxmoxホスト上で実行し、MiniStack用のLXCコンテナを作る
#
#   使い方（Proxmoxホストに root でSSHしてから）:
#     ./provision/create-lxc.sh [CTID] [ホスト名] [IP/CIDR] [ゲートウェイ]
#
#     ./provision/create-lxc.sh                    # デフォルト: 210 ministack dhcp
#     ./provision/create-lxc.sh 210 ministack 192.168.11.50/24 192.168.11.1
#
#   何をするか:
#     1. Debian 12 のLXCテンプレートをダウンロード（無ければ）
#     2. nesting=1 の特権なしLXCを作成（Docker動作に必要）
#     3. Docker + docker compose をインストール
#     4. このリポジトリを clone して compose/ を準備するまで（起動は各自）
#
#   リソースの目安: メモリ4GB / 2コア / ディスク20GB以上
#   （MiniStack自体はアイドル30MB程度だが、RDS/ElastiCacheとして
#    Dockerコンテナが起動するため、その分の余裕が要る）
# =============================================================================
set -euo pipefail

CTID="${1:-210}"
HOSTNAME="${2:-ministack}"
IP="${3:-dhcp}"
GW="${4:-}"
STORAGE="${STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-4096}"
CORES="${CORES:-2}"
DISK="${DISK:-20}"
REPO_URL="${REPO_URL:-https://github.com/takezou621/proxmox-ministack.git}"

[[ $EUID -eq 0 ]] || { echo "error: Proxmoxホストで root として実行してください" >&2; exit 1; }
command -v pct >/dev/null 2>&1 || { echo "error: pct コマンドがありません（Proxmoxホストで実行してください）" >&2; exit 1; }

if pct status "$CTID" >/dev/null 2>&1; then
    echo "error: CT $CTID は既に存在します" >&2
    exit 1
fi

# ---- 1. テンプレート ------------------------------------------------------------
echo "== Debian 12 テンプレートを確認/ダウンロード =="
pveam update >/dev/null
TEMPLATE="$(pveam available --section local | awk '/debian-12-standard/ {print $2}' | sort -V | tail -1)"
if [[ -z "$TEMPLATE" ]]; then
    echo "error: debian-12-standard テンプレートが見つかりません" >&2
    exit 1
fi
pveam list "$STORAGE" | grep -q "$TEMPLATE" || pveam download "$STORAGE" "$TEMPLATE"

# ---- 2. LXC作成 -------------------------------------------------------------------
echo "== LXC作成: CT$CTID / $HOSTNAME / mem=${MEMORY}MB / cores=$CORES / disk=${DISK}G =="
if [[ "$IP" == "dhcp" ]]; then
    NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
else
    NET0="name=eth0,bridge=${BRIDGE},ip=${IP},gateway=${GW}"
fi

pct create "$CTID" "${STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" \
    --net0 "$NET0" \
    --rootfs "${STORAGE}-lvm:${DISK}" \
    --memory "$MEMORY" \
    --swap 2048 \
    --cores "$CORES" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 1

echo "== ネットワーク到達性のためDNSとSSHを確保 =="
pct exec "$CTID" -- bash -c 'apt-get update -qq && apt-get install -y -qq openssh-server ca-certificates curl gnupg >/dev/null'

# ---- 3. Docker ---------------------------------------------------------------------
echo "== Docker のインストール =="
pct exec "$CTID" -- bash -c \
    'install -m 0755 -d /etc/apt/keyrings && \
     curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
     chmod a+r /etc/apt/keyrings/docker.asc && \
     echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list && \
     apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null'

echo "== 動作確認 =="
pct exec "$CTID" -- docker version --format 'Docker {{.Server.Version}} OK'

# ---- 4. リポジトリ配置 ---------------------------------------------------------------
echo "== リポジトリを clone =="
pct exec "$CTID" -- bash -c "apt-get install -y -qq git >/dev/null && git clone ${REPO_URL} /root/proxmox-ministack"

IP_ADDR="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
cat <<EOF

==========================================================================
 LXC作成完了: CT$CTID ($HOSTNAME) @ $IP_ADDR
 次の手順:
   1. pct exec $CTID -- bash
   2. cp /root/proxmox-ministack/.env.example /root/proxmox-ministack/.env
      → MINISTACK_HOST / MINISTACK_PUBLIC_HOST を $IP_ADDR に設定
   3. cd /root/proxmox-ministack && scripts/ministack-up.sh
   4. 開発マシン側の .env も同じ IP に合わせる
==========================================================================
EOF
