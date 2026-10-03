# MiniStack 上のS3を tfstate バックエンドにする設定
# （scripts/bootstrap-backend.sh ministack でバケット/テーブルを作っておく）
#
# endpoint / dynamodb_endpoint は scripts/tf.sh が .env の
# MINISTACK_HOST / MINISTACK_PORT から実行時に -backend-config で注入する。

bucket                      = "proxmox-ministack-tfstate"
key                         = "base-stack/terraform.tfstate"
region                      = "ap-northeast-1"
access_key                  = "test"
secret_key                  = "test"
dynamodb_table              = "proxmox-ministack-tflock"

skip_credentials_validation = true
skip_metadata_api_check     = true
skip_region_validation      = true
use_path_style              = true
