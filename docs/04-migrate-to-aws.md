# 04. 本番AWSへの移行（そして切り戻し）

MiniStack（自宅Proxmox）→ 本番AWSへの移行手順です。
**Terraformは「構造」を作り、「中身のデータ」は移しません**。両方やる必要があります。

---

## 移行チェックリスト

移行の全体像（順番に実行します）:

```
[準備]
  1. AWS認証・リージョン確認
  2. tfstate用バケット＆ロックテーブル作成（AWS側）
[構造の移行]
  3. scripts/tf.sh aws plan   → 差分＝全リソース作成であることを確認
  4. scripts/tf.sh aws apply  → AWS側にリソース作成
[データの移行]
  5. S3: scripts/migrate-s3.sh
  6. RDS: scripts/migrate-rds.sh
[ DNS/ドメイン ]
  7. Route53/ACM/CloudFront の切り替え
[検証〜切替]
  8. アプリの向き先変更、動作確認、トラフィック切り替え
```

---

## 1-2. 準備

```bash
aws sts get-caller-identity                  # 認証確認（環境変数 / SSO / プロファイル）
vi terraform/base-stack/envs/aws.tfvars      # 本番リージョン・environment を確認
vi terraform/base-stack/envs/aws.backend.hcl # tfstate用バケット名（グローバル一意）を設定
scripts/bootstrap-backend.sh aws             # S3バケット + DynamoDBロックテーブル作成
```

## 3-4. インフラ構造（Terraform）の移行

```bash
scripts/tf.sh aws plan
```

planが示す差分は「全リソースの新規作成」になるはずです
（MiniStack用stateとAWS用stateは別管理のため。これが安全な移行方式）。

```bash
scripts/tf.sh aws apply
```

## 5. S3データの移行

```bash
# 何が転送されるか確認してから:
scripts/migrate-s3.sh --dry-run

# 全バケットを MiniStack → AWS へ:
scripts/migrate-s3.sh

# 特定バケット・prefixだけ:
scripts/migrate-s3.sh --bucket my-app-assets --prefix uploads/
```

- 仕組み: 2段階の `aws s3 sync`（一度ローカルに受けてから書き戻す）なので
  **再実行しても差分だけ転送**されます
- バケット自体は存在しなければ自動作成されます（リージョン配置も正しく）
- 数十GB以上なら [rclone](https://rclone.org/)（2つのS3リモートを直接同期可）を推奨

## 6. RDSデータの移行

```bash
# MiniStack側のDBインスタンス確認:
scripts/migrate-rds.sh --list

# ダンプ取得:
export DB_PW='<MiniStackでCreateDBInstance時に指定したマスターパスワード>'
scripts/migrate-rds.sh --db mydb --password-env DB_PW --out mydb.sql

# 本番RDSへリストア（--to-identifier でエンドポイント自動解決）:
export PROD_PW='<本番RDSのマスターパスワード>'
scripts/migrate-rds.sh --db mydb --out mydb.sql \
    --to-identifier mydb-prod --to-user admin --to-password-env PROD_PW --yes
```

注意点:

- 本番RDSインスタンス自体は **事前に Terraform（tf.sh aws apply）で作成済み** にする
- `--to-dbname` の初期データベースは本番側に存在する必要がある（Terraformの
  `aws_db_instance` で `db_name` を指定しておくと楽）
- シーケンス（SERIALの現在値）は必要に応じ `setval` で再調整
- MySQLの場合 `mysqldump --set-gtid-purged=OFF` 相当の考慮がRDS側で必要になることがある

---

## 7. ドメイン・DNS・ネットワーク

ここは**エミュレータでは再現できない「本物の世界」の設定**になるため、
Terraformにあらかじめパラメータを仕込んでおきます。

| 項目 | ローカル（MiniStack） | 本番（AWS） |
|------|----------------------|------------|
| ドメイン | `http://192.168.x.x:4566` での疑似ホスト名 | 実ドメイン（Route53 Hosted Zone） |
| 証明書 | エミュレート（ACM APIは叩ける） | **本物のACM**（DNS検証。CloudFrontは us-east-1 必須） |
| DNS検証レコード | 不要 | Route53 に ACM 検証の CNAME を自動登録させる |

実装パターン（`use_ministack` で分岐）:

```hcl
resource "aws_route53_zone" "main" {
  count = var.use_ministack ? 0 : 1
  name  = var.domain_name
}

resource "aws_acm_certificate" "site" {
  count           = var.use_ministack ? 0 : 1
  domain_name     = var.domain_name
  validation_method = "DNS"
}

resource "aws_route53_record" "acm_validation" {
  count = var.use_ministack ? 0 : 1
  # ACM検証のCNAMEをHosted Zoneへ（ aws_acm_certificate.cert[0].domain_validation_options から ）
}
```

ローカルでは代わりのダミー値を `locals` で与えて参照を崩さない運用にします
（詳細は docs/03 の「環境で挙動が違うリソースの扱い」）。

## 8. アプリケーションの向き先

アプリは環境変数で向き先を変える設計にしておきます:

```bash
# ローカル開発（MiniStack）
AWS_ENDPOINT_URL=http://192.168.11.50:4566
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test

# 本番: AWS_ENDPOINT_URL を指定しない（＝公式エンドポイント）
```

---

## 切り戻し（AWS → 自宅Proxmox へのリバース運用）

**いつでも戻せる**のがこのアーキテクチャの利点です。

```bash
# 1. AWS側リソースを削除（課税停止）
scripts/tf.sh aws destroy

# 2. 必要ならデータも自宅へ戻す
scripts/migrate-s3.sh --from aws --to ministack
export DB_PW=... PROD_PW=...
scripts/migrate-rds.sh --db mydb --from aws --to-identifier mydb --out rollback.sql \
    --to-host <ProxmoxホストIP> --to-port 15432 --to-user admin --to-password-env DB_PW --yes
# ※ AWS→MiniStack のdumpは --from aws を指定（現状ダンプ元情報は手動指定）

# 3. ローカルに再デプロイ
scripts/tf.sh ministack apply
```

---

## 移行後にやること

- [ ] `aws budgets` または請求アラートの設定（コスト監視）
- [ ] `terraform/base-stack/envs/aws.backend.hcl` の stateバケットを本番用に変更したか
- [ ] MiniStack側の `.env` / テストデータを残すか消すか決定（`make reset`）
- [ ] Route53のNSレジストラ反映待ち（最大48時間の余裕を見る）
