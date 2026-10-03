###############################################################################
# base-stack — 変数
###############################################################################

# --- 切替スイッチ（envs/*.tfvars で上書きされる） ------------------------------

variable "use_ministack" {
  description = "true なら MiniStack（ローカルAWS）に、false なら本物のAWSに接続する"
  type        = bool
  default     = true
}

variable "ministack_host" {
  description = "MiniStack を稼働させるホスト（Proxmox上のVM/LXCのIP等）。scripts/tf.sh が .env から自動注入する"
  type        = string
  default     = "localhost"
}

variable "ministack_port" {
  description = "MiniStack のゲートウェイポート"
  type        = number
  default     = 4566
}

# --- 共通 -----------------------------------------------------------------------

variable "aws_region" {
  description = "デプロイ先リージョン（MiniStack時は MINISTACK_REGION と同じものを使う）"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "リソース名のプレフィックス兼タグ"
  type        = string
  default     = "ministack-demo"
}

variable "environment" {
  description = "環境識別子（ministack / prod など）。名前とタグに使われる"
  type        = string
  default     = "ministack"
}
