###############################################################################
# MiniStack / AWS 切替の要 — providers.tf
#
# use_ministack = true  （envs/ministack.tfvars）
#   → 全サービスのエンドポイントが http://<ministack_host>:4566 に向き、
#     ダミー認証（test/test）でローカルのMiniStackに繋がる
#
# use_ministack = false （envs/aws.tfvars）
#   → エンドポート指定がすべて null になり、公式AWSエンドポイント＋
#     標準認証チェーン（環境変数 / SSO / プロファイル）で本番AWSに繋がる
#
# このファイルは scripts/tf.sh 経由で使うことを前提としている
# （ministack_host は .env の MINISTACK_HOST が -var で注入される）。
###############################################################################

locals {
  ministack_endpoint = "http://${var.ministack_host}:${var.ministack_port}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Stack       = "base-stack"
  }
}

provider "aws" {
  region = var.aws_region

  # MiniStackではダミー認証。AWSでは null = 標準認証チェーンに任せる
  access_key = var.use_ministack ? "test" : null
  secret_key = var.use_ministack ? "test" : null

  # --- MiniStack向けの設定（AWS時は false / null になり無効化される） ---
  skip_credentials_validation = var.use_ministack
  skip_metadata_api_check     = true
  skip_requesting_account_id  = var.use_ministack
  # エミュレータは仮想ホスト形式 (bucket.domain) に対応しないためパス形式にする
  s3_use_path_style = var.use_ministack

  # --- エンドポイント切替の本体：null なら公式エンドポイントが使われる ---
  endpoints {
    sts            = var.use_ministack ? local.ministack_endpoint : null
    iam            = var.use_ministack ? local.ministack_endpoint : null
    s3             = var.use_ministack ? local.ministack_endpoint : null
    dynamodb       = var.use_ministack ? local.ministack_endpoint : null
    sqs            = var.use_ministack ? local.ministack_endpoint : null
    sns            = var.use_ministack ? local.ministack_endpoint : null
    ec2            = var.use_ministack ? local.ministack_endpoint : null
    rds            = var.use_ministack ? local.ministack_endpoint : null
    lambda         = var.use_ministack ? local.ministack_endpoint : null
    route53        = var.use_ministack ? local.ministack_endpoint : null
    elbv2          = var.use_ministack ? local.ministack_endpoint : null
    cloudfront     = var.use_ministack ? local.ministack_endpoint : null
    kms            = var.use_ministack ? local.ministack_endpoint : null
    ssm            = var.use_ministack ? local.ministack_endpoint : null
    secretsmanager = var.use_ministack ? local.ministack_endpoint : null
    events         = var.use_ministack ? local.ministack_endpoint : null
    logs           = var.use_ministack ? local.ministack_endpoint : null
    elasticache    = var.use_ministack ? local.ministack_endpoint : null
    ecr            = var.use_ministack ? local.ministack_endpoint : null
    apigateway     = var.use_ministack ? local.ministack_endpoint : null
    stepfunctions  = var.use_ministack ? local.ministack_endpoint : null
    kinesis        = var.use_ministack ? local.ministack_endpoint : null
    sesv2          = var.use_ministack ? local.ministack_endpoint : null
  }

  default_tags {
    tags = local.common_tags
  }
}
