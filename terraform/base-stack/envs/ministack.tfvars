# MiniStack（ローカルAWS）向けの値 — scripts/tf.sh ministack で使用
use_ministack = true
environment   = "ministack"
aws_region    = "ap-northeast-1"   # .env の MINISTACK_REGION に合わせる

# ministack_host / ministack_port は scripts/tf.sh が .env から
# -var で自動注入するため、ここには書かない
