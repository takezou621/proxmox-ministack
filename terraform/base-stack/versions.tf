###############################################################################
# base-stack — バージョン固定
#
# tfstate のバックエンドは scripts/tf.sh が環境に応じて backend.generated.tf に
# 生成する（gitignore 対象）:
#
#   scripts/tf.sh ministack ... -> backend "s3" + envs/ministack.backend.hcl（MiniStack上のS3）
#   scripts/tf.sh aws       ... -> backend "s3" + envs/aws.backend.hcl        （本番AWSのS3+DynamoDB）
#   scripts/tf.sh local     ... -> backend "local"                            （ローカルファイル）
#
# このため versions.tf には backend ブロックを書かない（ここに書くと local モードが
# 成立しなくなる）。手で terraform init する場合は backend.generated.tf の内容に注意。
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
