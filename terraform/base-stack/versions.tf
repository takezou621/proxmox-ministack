###############################################################################
# base-stack — バージョン固定とバックエンド（state置き場）の定義
#
# backend "s3" の中身は空（partial configuration）になっており、
# 実際の接続先は scripts/tf.sh が環境ごとの hcl を -backend-config で注入する:
#
#   scripts/tf.sh ministack init   -> envs/ministack.backend.hcl（MiniStack上のS3）
#   scripts/tf.sh aws      init   -> envs/aws.backend.hcl        （本番AWSのS3+DynamoDB）
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {}
}
