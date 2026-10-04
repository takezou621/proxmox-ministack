# proxmox-ministack

**自宅Proxmox上に「ローカルAWS」を立て、Terraformコードを1行も変えずに本番AWSへ移行するためのライブラリ集。**

[MiniStack](https://github.com/ministackorg/ministack)（MITライセンスのAWSエミュレータ。RDS=本物のPostgreSQL/MySQLコンテナ、60以上のサービス対応）を Proxmox の LXC/VM 上で運用し、
`use_ministack` のトグルひとつで「ローカル開発 ⇄ 本番AWS」を切り替えます。

```
┌───────────────────────── 自宅 Proxmox ─────────────────────────┐
│  LXC / VM (Debian + Docker)                                    │
│   ┌──────────────────────────────────────────────┐             │
│   │ MiniStack :4566  ← 全AWSサービスのゲートウェイ │             │
│   │   ├── S3 / DynamoDB / SQS / Lambda ...       │             │
│   │   ├── RDS ────── 本物の Postgres/MySQL コンテナ :15432+     │
│   │   └── ElastiCache 本物の Redis コンテナ      :16379+        │
│   └──────────────────────────────────────────────┘             │
└──────────────┬─────────────────────────────────┬───────────────┘
               │ terraform apply (ministack)      │ aws cli / SDK
┌──────────────┴──────────────┐   ┌──────────────┴───────────────┐
│  開発マシン（Mac等）         │   │  同じコード・同じワークフロー   │
│  scripts/tf.sh ministack …  │   │  scripts/tf.sh aws … → 本番AWS │
└─────────────────────────────┘   └──────────────────────────────┘
```

## 何がうれしいか

- **ランニングコストほぼ0円**でRDS/ALB/S3等を含む構成を納得いくまで試行錯誤できる（電気代のみ）
- **移行は変数1つ**: `use_ministack = false` にして `terraform apply` するだけ
- **切り戻しも自由**: 本番リソースを `destroy` して自宅に戻すリバース運用もスクリプト1発
- tfstateは環境ごとに分離（MiniStackのS3 / 本番AWSのS3+DynamoDB）するので
  **State不整合事故が起きない**設計

## クイックスタート（手元で5分）

Proxmoxがなくても、DockerさえあればMac/PCで試せます。

```bash
cp .env.example .env
make up                                   # MiniStack起動 + ヘルスチェック
scripts/bootstrap-backend.sh ministack    # tfstate用バケット作成（初回のみ）
scripts/tf.sh local plan                  # backendなしでまずplanを見る
scripts/tf.sh local apply                 # S3/DynamoDB/SQS/SSMがローカルに作られる
source lib/ministack.sh && ms_use && aws s3 ls   # aws CLIでも確認
```

## Proxmox で本格運用（LXC 1本）

```bash
# Proxmoxホスト上で（LXC作成 + Docker + このリポジトリ導入まで自動）:
./provision/create-lxc.sh 210 ministack 192.168.11.50/24 192.168.11.1

# LXC内で:
cp .env.example .env && vi .env          # MINISTACK_HOST / MINISTACK_PUBLIC_HOST を 192.168.11.50 に
scripts/ministack-up.sh

# 開発マシン側の .env も同じIPに合わせて:
scripts/tf.sh ministack plan && scripts/tf.sh ministack apply
```

→ 詳細: [docs/01-proxmox-setup.md](docs/01-proxmox-setup.md)

## 本番AWSへの移行

```bash
scripts/bootstrap-backend.sh aws          # tfstate用バケット（AWS側・初回のみ）
scripts/tf.sh aws plan                    # 差分 = 全リソース新規作成
scripts/tf.sh aws apply                   # 構造がAWSに再現される
scripts/migrate-s3.sh                     # S3の中身を同期
scripts/migrate-rds.sh --list             # RDSの中身をダンプ＆リストア（docs/04）
```

→ データ移行・DNS/ACM・切り戻しまで: [docs/04-migrate-to-aws.md](docs/04-migrate-to-aws.md)

---

## リポジトリ構成

| パス | 役割 |
|------|------|
| `compose/docker-compose.yml` | MiniStack本体。永続化3種（状態/S3/RDSボリューム）、docker.sock、DBポートの公開ポリシーまで設定済み |
| `lib/ministack.sh` | **コアライブラリ**。`ms_use` / `ms_clear`（aws CLI・SDKの向き先切替）、`ms_aws`、`ms_ready`、`ms_s3_purge` など |
| `scripts/tf.sh` | **Terraformラッパー**。`<ministack\|local\|aws>` を引数に取り、tfvars・backend・認証を一括切替 |
| `scripts/bootstrap-backend.sh` | tfstate用S3バケット＋DynamoDBロックテーブル作成（ministack/aws両対応・冪等） |
| `scripts/migrate-s3.sh` | S3データの双方向同期（2段階syncで増分転送・dry-run対応） |
| `scripts/migrate-rds.sh` | RDSダンプ＆リストア（pg_dump / mysqldump、`--from aws` で切り戻しも） |
| `scripts/ministack-{up,down}.sh` `healthcheck.sh` | 起動・停止（データ保持）・状態確認 |
| `terraform/base-stack/` | 両環境でそのまま動くサンプルスタック。`providers.tf` に切替ロジック、`envs/` に環境別設定 |
| `provision/create-lxc.sh` | Proxmoxホストで実行。nesting有効LXC＋Docker＋リポジトリ導入を自動化 |
| `Makefile` | `make up / health / plan / apply / migrate-s3 ...` のショートカット |

## 3つの環境モード

| | `local` | `ministack` | `aws` |
|---|---|---|---|
| プロバイダ向き先 | MiniStack | MiniStack | 本物のAWS |
| tfstate | ローカルファイル | MiniStackのS3+DynamoDB | AWSのS3+DynamoDB |
| 認証 | ダミー(test) | ダミー(test) | 標準チェーン(SSO/環境変数/プロファイル) |
| 用途 | 初見のお試し | 日常の開発 | 本番 |

切替の仕組み（providers.tf / partial backend / `.env`）:
[docs/03-terraform-workflow.md](docs/03-terraform-workflow.md)

## ドキュメント

1. [01. Proxmox セットアップ](docs/01-proxmox-setup.md) — LXC/VM作成、リソース目安、nesting
2. [02. MiniStack の運用](docs/02-ministack-operations.md) — 永続化、ポート設計、マルチアカウント、リセット
3. [03. Terraform ワークフロー](docs/03-terraform-workflow.md) — 切替機構、スタック追加、ハマりどころ
4. [04. 本番AWSへの移行](docs/04-migrate-to-aws.md) — チェックリスト、データ移行、DNS/ACM、切り戻し

## AWS移行で意識すべき3つのこと（要約）

1. **データはTerraformの管轄外** — S3は `migrate-s3.sh`、RDSは `migrate-rds.sh` で別途移す
2. **ドメイン/DNS/証明書は本物の世界** — Route53 Hosted Zone・ACM(DNS検証)は
   `count = var.use_ministack ? 0 : 1` で本番時のみ作る切り分けをTerraformに仕込む
3. **Proxmox側のリソースは多めに** — MiniStack本体は軽い（アイドル30MB）が、
   RDS/ElastiCacheで実コンテナが立つためメモリ4GB程度を推奨

## 動作検証済み環境

- MiniStack `ministackorg/ministack:latest`（1.5系）/ Terraform v1.16 / AWS provider v6
- macOS（bash 3.2互換で記述）および Debian 12 LXC 想定
- 検証済みフロー: 起動→bootstrap→init/plan/apply/destroy（S3+DynamoDBロックstate）→
  S3双方向同期→RDS作成・pg_dump・リストアのデータ往復→`local`/`aws` モード切替

## License

MIT — このリポジトリ自身と、依存する [MiniStack](https://github.com/ministackorg/ministack) もMITです。
