# 02. MiniStack の運用

`compose/docker-compose.yml` で稼働させる MiniStack（ローカルAWS）の説明と運用コマンドです。

---

## 起動・停止・確認

```bash
make up          # 起動（初回は .env を .env.example から自動作成）
make health      # ヘルスチェック + DBコンテナ一覧
make logs        # ログを追う
make down        # 停止（データは残る）
make reset       # 全状態をリセット（確認あり。開発の切り戻しに便利）
```

手で叩く場合:

```bash
scripts/ministack-up.sh
scripts/ministack-down.sh [--reset-data]   # --reset-data で compose/data も削除
scripts/healthcheck.sh
```

---

## compose のポイント

### 1. docker.sock のマウント（必須級）

MiniStack は RDS / ElastiCache / Lambda / ECS の実体として
**本物のDockerコンテナを兄弟起動**します。そのため docker.sock が必要です。

```
RDSを作る → PostgreSQL/MySQL のコンテナが Proxmox 側で起動 → 動的ポート (15432〜) で公開
```

### 2. 3種類の永続化フラグ

| フラグ | 何が残る | 保存先 |
|--------|---------|--------|
| `PERSIST_STATE=1` | 各サービスの状態（キュー、テーブル定義、DBインスタンス定義…） | `compose/data/state` |
| `S3_PERSIST=1` | S3オブジェクトの中身 | `compose/data/s3` |
| `RDS_PERSIST=1` | RDSコンテナのデータ（名前付きボリューム） | Docker volume |

LXC/VMを再起動しても、これらがあれば状態が戻ります
（DBインスタンスは自動でコンテナが再作成されます）。

### 3. ポート設計 — よくあるハマりどころ

- **4566のみ** compose が公開します（全AWSサービス共通ゲートウェイ）。
- **15432〜（RDS）と 16379〜（ElastiCache）は compose で公開しません。**
  DBコンテナが自分でホストポートをバインドするため、compose側で範囲を割り当てると
  **ポート衝突でDBコンテナの起動が失敗**します（実測済みの落とし穴）。
- 接続可能なDBインスタンス数 = ポート範囲の幅（デフォルトで RDS 68台分）。
  もっと増やす場合は MiniStack 側の環境変数 `RDS_BASE_PORT` の連番を広げる必要があります。

### 4. `MINISTACK_HOST`（リモート開発の要）

`.env` の `MINISTACK_PUBLIC_HOST` に Proxmox 上の LXC/VM の IP を設定すると:

- `DescribeDBInstances` が返すエンドポイントが `そのIP:15432+` になる
  （設定しないと `localhost` が返り、開発マシンから接続不能になる）
- CloudFront / API Gateway の仮想ホスト名の解決にも使われる

---

## マルチアカウント・マルチリージョン

MiniStack は **12桁の数値のアクセスキー＝アカウントID** としてテナント分離できます。

```bash
export AWS_ACCESS_KEY_ID=111122223333   # = アカウント 111122223333
export AWS_SECRET_ACCESS_KEY=test
```

「本番想定のアカウント」「ステージング想定のアカウント」を1つのMiniStackで
完全分離して運用できます（リージョンも同様に分離）。
認証を有効にする `AUTH=true` もあります（詳細は MiniStack 公式README）。

---

## 開発マシンから aws CLI で触る

`lib/ministack.sh` を source すると切替が1行でできます:

```bash
source lib/ministack.sh

ms_use                    # これ以降の aws は MiniStack 向き（AWS_ENDPOINT_URL を export）
aws s3 ls
aws sqs list-queues

ms_clear                  # 本物のAWSに戻す
```

1コマンドだけ向けるなら:

```bash
ms_aws s3 ls                       # MiniStack 向け
ms_aws_real sts get-caller-identity  # 本物のAWS向け
```

CIに組み込む場合は `AWS_ENDPOINT_URL=http://<IP>:4566` 等を直接 export しても同じです。

---

## 状態のリセット

```bash
make reset                                    # APIレベルで全消去（確認あり）
scripts/ministack-down.sh --reset-data        # ディスク永続分も含めて完全初期化
```

Terraform 管理のリソースを消す場合はリセットではなく `scripts/tf.sh ministack destroy` を
使ってください（stateと実態の整合が保たれます）。

---

## メモリ・リソースの目安

- MiniStack アイドル: 約30MB
- RDS PostgreSQL コンテナ1台: 約50〜100MB
- ElastiCache (Redis) 1台: 約10〜30MB
- Terraform apply で一気にDBを複数作るとその分積み上がる

Proxmoxの割り当ては **4GB** あると安心です。`docker stats` と `pct` のコンソールで
経過を見て、不足したらメモリを増設してください。
