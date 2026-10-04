# 本番AWSの tfstate バックエンド設定
#
# bucket 名を変える場合はこのファイルを編集すればOK。
# scripts/bootstrap-backend.sh aws は **このファイルの bucket / dynamodb_table を
# 読んで** 作成するため、backend と bootstrap の名前がずれることはない。
# （環境変数 TFSTATE_BUCKET / TFLOCK_TABLE で上書きも可能）
#
# 認証情報はここに書かない。標準認証チェーン（環境変数 / SSO / プロファイル）
# を使う。CIから実行する場合は assume_role ブロックの追加も検討すること。

bucket         = "proxmox-ministack-tfstate"   # 本番用バケット名に変更する（グローバル一意）
key            = "base-stack/terraform.tfstate"
region         = "ap-northeast-1"
dynamodb_table = "proxmox-ministack-tflock"    # State Lock 用（LockID キー）

encrypt        = true
