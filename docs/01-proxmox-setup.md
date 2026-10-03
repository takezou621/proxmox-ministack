# 01. Proxmox 上に MiniStack 用の VM/LXC を用意する

自宅Proxmox上に「ローカルAWS」を稼働させるためのホスト（VMまたはLXC）を作る手順です。
どちらでも動きますが、**LXC＋スクリプトが最短**です。

---

## リソースの目安

| 項目 | 目安 | 備考 |
|------|------|------|
| メモリ | **4GB 以上**（最低2GB） | MiniStack自体はアイドル約30MB。RDS/ElastiCacheとしてDockerコンテナが起動する分が別途必要 |
| CPU | 2コア以上 | |
| ディスク | 20GB 以上 | DBコンテナのデータ volume がここに置かれる |
| ネットワーク | **固定IP推奨** | 開発マシンから `http://<IP>:4566` で常時アクセスするため |

---

## 方法A: LXC（推奨・最短）

Proxmoxホストに root でSSHし、同梱スクリプトを実行するだけです。

```bash
git clone https://github.com/takezou621/proxmox-ministack.git
cd proxmox-ministack

# デフォルト（CTID=210, ホスト名=ministack, DHCP）:
./provision/create-lxc.sh

# 固定IPを指定する場合:
./provision/create-lxc.sh 210 ministack 192.168.11.50/24 192.168.11.1
```

スクリプトがやること:

1. Debian 12 の LXC テンプレートをダウンロード
2. `nesting=1` の**特権なし**LXCを作成（Docker動作に必要）
3. Docker / docker compose をインストール
4. このリポジトリを `/root/proxmox-ministack` に clone

### 手動で作る場合の要点

```bash
pveam update
pveam download local debian-12-standard_12.7-1_amd64.tar.zst
pct create 210 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
    --hostname ministack \
    --net0 name=eth0,bridge=vmbr0,ip=192.168.11.50/24,gateway=192.168.11.1 \
    --rootfs local-lvm:20 --memory 4096 --cores 2 \
    --unprivileged 1 --features nesting=1 --onboot 1 --start 1
pct exec 210 -- bash -c 'apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://get.docker.com | sh'
```

> **`nesting=1` について**: Docker は LXC 内でコンテナを起動するため nested container 機能が必要です。
> `unprivileged 1`（特権なし）のままでも `nesting=1` があれば Debian 12 + Docker は動作します。
> rootfs が ZFS の場合に overlayfs の警告が出るときは `--rootfs` を dir ストレージにするか VM を使ってください。

---

## 方法B: VM（Ubuntu等）

LXCで問題が出る場合、素直にVMにします。

1. Ubuntu Server 24.04 LTS のISO（または cloud-init テンプレート）からVM作成
   - メモリ4GB / 2vCPU / 20GB / NIC: vmbr0
2. ゲストに Docker をインストール:

```bash
curl -fsSL https://get.docker.com | sh   # Ubuntu用
```

3. このリポジトリを clone:

```bash
git clone https://github.com/takezou621/proxmox-ministack.git
```

---

## 作成後の共通手順

LXC/VM に入って MiniStack を起動します:

```bash
pct exec 210 -- bash        # または VM に SSH
cd /root/proxmox-ministack

cp .env.example .env
# MINISTACK_HOST / MINISTACK_PUBLIC_HOST を このLXC/VM の IP に変更する
vi .env

scripts/ministack-up.sh
scripts/healthcheck.sh      # "OK" が出れば完了
```

開発マシン（Mac/PC）側の `.env` も同じIPに合わせておけば、
`scripts/tf.sh ministack plan` が開発マシンからそのまま使えます。

詳細は [02. MiniStack の運用](02-ministack-operations.md) へ。

---

## バックアップ

- Proxmox標準の `vzdump`（LXC/VM全体）または
- `compose/data/` ディレクトリ（S3オブジェクト・サービス状態・Redis）だけrsync

DBコンテナのデータは Docker の名前付きボリューム（`RDS_PERSIST=1`）に置かれるため、
丸ごとバックアップするなら `vzdump` が確実です。
