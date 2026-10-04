###############################################################################
# base-stack — 出力
###############################################################################

output "s3_bucket_name" {
  description = "アーティファクト用S3バケット"
  value       = aws_s3_bucket.artifacts.bucket
}

output "dynamodb_table_name" {
  description = "アプリ用DynamoDBテーブル"
  value       = aws_dynamodb_table.app_table.name
}

output "sqs_queue_url" {
  description = "ジョブ用SQSキュー"
  value       = aws_sqs_queue.jobs.url
}

output "ssm_parameter_name" {
  description = "SSMパラメータ"
  value       = aws_ssm_parameter.config.name
}

output "ministack_endpoint" {
  description = "MiniStack時のエンドポイント（AWS時は null）"
  value       = var.use_ministack ? "http://${var.ministack_host}:${var.ministack_port}" : null
}
