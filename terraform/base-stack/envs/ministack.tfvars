# MiniStack（ローカルAWS）向けの値 — scripts/tf.sh ministack で使用
use_ministack = true
environment   = "ministack"

# aws_region / ministack_host / ministack_port は scripts/tf.sh が .env から
# -var で自動注入するため、ここには書かない（.env の MINISTACK_REGION を変えれば
# プロバイダとbackendの両方に反映される）
