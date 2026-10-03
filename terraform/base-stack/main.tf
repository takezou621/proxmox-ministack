###############################################################################
# base-stack — サンプルリソース
#
# MiniStack でも本番AWSでも同じ定義がそのまま動くことを示す最小構成:
#   * S3バケット（バージョニングあり）
#   * DynamoDBテーブル（アプリ用。tfstateロックテーブルとは別物）
#   * SQSキュー
#   * SSMパラメータ
#
# 実際のプロジェクトでは、このスタックをコピーしてリソースを足していく。
# 両環境で挙動が違うリソース（ACM、CloudFrontの実ドメイン等）は
# count = var.use_ministack ? 0 : 1 で本番時だけ作る、といった切り分けも可能。
###############################################################################

# ---- S3 ------------------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.project}-${var.environment}-artifacts"

  # MiniStack ではバージョニング含め同じAPIがエミュレートされる
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ---- DynamoDB --------------------------------------------------------------------

resource "aws_dynamodb_table" "app_table" {
  name         = "${var.project}-${var.environment}-app"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
}

# ---- SQS --------------------------------------------------------------------------

resource "aws_sqs_queue" "jobs" {
  name                       = "${var.project}-${var.environment}-jobs"
  message_retention_seconds  = 345600
  visibility_timeout_seconds = 30
}

# ---- SSM --------------------------------------------------------------------------

resource "aws_ssm_parameter" "config" {
  name  = "/${var.project}/${var.environment}/example"
  type  = "String"
  value = "managed-by-terraform"
}
