# 03. Terraform のワークフロー（MiniStack ⇄ AWS 切替）

このリポジトリの核となる「**同じコードのまま、向き先だけ切り替える**」仕組みの説明です。

---

## 3つの環境モード

`scripts/tf.sh <環境> <コマンド>` の環境は3つあります:

| モード | プロバイダの向き先 | tfstate の置き場所 | 用途 |
|--------|------------------|-------------------|------|
| `ministack` | MiniStack（ローカルAWS） | MiniStack 上の S3 + DynamoDBロック | 普段の開発・試行錯誤 |
| `local` | MiniStack | カレントのローカルファイル | 最初の5分のお試し（backend不要） |
| `aws` | 本物の AWS | AWS の S3 + DynamoDBロック | 本番 |

```bash
# --- 日常（MiniStack上で開発） ---
scripts/bootstrap-backend.sh ministack    # 初回一度だけ: tfstateバケット等を作成
scripts/tf.sh ministack init              # 初回一度だけ
scripts/tf.sh ministack plan
scripts/tf.sh ministack apply

# --- 本番AWSへ移行 ---
scripts/bootstrap-backend.sh aws          # 初回一度だけ（要AWS認証）
scripts/tf.sh aws plan                    # 差分 = 全リソースの新規作成
scripts/tf.sh aws apply

# --- 自宅に戻す（リバース運用） ---
scripts/tf.sh aws destroy
scripts/tf.sh ministack apply             # ローカルに再デプロイ
```

`make` 経由なら `make plan ENV=ministack` / `make apply ENV=aws` でも同じです。

---

## 切替の仕組み

二重化された切り替えポイントが全て変数で制御されています。

### 1. プロバイダの向き先 — `terraform/base-stack/providers.tf`

```hcl
provider "aws" {
  region = var.aws_region

  access_key = var.use_ministack ? "test" : null   # AWS時は標準認証チェーン
  secret_key = var.use_ministack ? "test" : null

  skip_credentials_validation = var.use_ministack
  s3_use_path_style           = var.use_ministack

  endpoints {
    s3       = var.use_ministack ? local.ministack_endpoint : null
    dynamodb = var.use_ministack ? local.ministack_endpoint : null
    ...（全サービス同じパターン）
  }
}
```

`envs/ministack.tfvars` では `use_ministack = true`、`envs/aws.tfvars` では `false` になっており、
`tf.sh` が `-var-file` で切替えます。`endpoints` が `null` のときは公式エンドポイントが使われます。

### 2. tfstate の置き場所 — partial backend

`versions.tf` の `backend "s3" {}` は空で、実体は `envs/*.backend.hcl` を
`terraform init -backend-config` で注入します（`tf.sh` が自動で行う）:

| ファイル | 内容 |
|---------|------|
| `envs/ministack.backend.hcl` | MiniStack の S3（dummy認証 / path style / エンドポイントは `.env` から動的注入） |
| `envs/aws.backend.hcl` | 本番AWSの S3 + DynamoDBロック（認証は標準チェーン） |

**tfstateは環境ごとに別々に管理**されるのがポイントです。
「MiniStackで作ったstate」を「AWSに適用」するのではなく、
**AWS用のstateを新規に作ってAWSに適用（全リソース新規作成）** します。
これがState不整合事故を起こさない一番安全な移行方法です。

### 3. AWS CLI側の切替 — `lib/ministack.sh`

terraform 以外（aws CLI、SDK、スクリプト）向けに `ms_use` / `ms_clear` を提供します。
中身は `AWS_ENDPOINT_URL` 系の export なので、boto3や他ツールにも効きます。

---

## 新しいスタックを足す方法

`terraform/base-stack/` をコピーして `terraform/<新しいスタック名>/` を作るだけです。
`envs/` も一緒にコピーし、`envs/*.backend.hcl` の `key` を
`<新しいスタック名>/terraform.tfstate` に変えます。

```bash
cp -r terraform/base-stack terraform/app-stack
sed -i '' 's|base-stack/terraform.tfstate|app-stack/terraform.tfstate|' terraform/app-stack/envs/*.backend.hcl
STACK=app-stack scripts/tf.sh ministack plan    # STACK環境変数で切替
```

## 環境で挙動が違うリソースの扱い

例: ACM証明書や実ドメインのCloudFrontなど、ローカルでエミュレートしきれないものは
`use_ministack` で出し分けます:

```hcl
resource "aws_acm_certificate" "site" {
  count    = var.use_ministack ? 0 : 1      # 本番(AWS)時のみ作成
  domain   = "example.com"
  ...
}

# ローカル時はダミーの値を返す
locals {
  cert_arn = var.use_ministack ? "arn:aws:acm:local:dummy" : aws_acm_certificate.site[0].arn
}
```

---

## ハマりどころ（実測済み）

1. **バージョニング有効バケットは destroy できない**
   `aws s3 rm` では削除マーカーが残るため。`ms_s3_purge <bucket>`（lib）で
   全バージョン削除してから destroy してください。

2. **環境を切り替えると state が「別世界」になる**
   仕様です（上記参照）。`local` で apply した後に `ministack` に移ると
   stateがないため全リソースが「新規作成」扱いになります。
   最初にどのモードで運用するか決めて統一するのが安全です。

3. **`tf.sh aws` はAWS認証が無いと init の前に止まる**
   `aws sts get-caller-identity` で事前チェックしています。

4. **SQS作成など一部リソースは反映に数十秒かかる**
   MiniStackの実装上の遅延です。planの差分が落ち着かない場合は少し待って再plan。
