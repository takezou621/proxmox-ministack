# =============================================================================
# proxmox-ministack — よく使う操作のショートカット
#   使い方: make <ターゲット> （ENV=ministack|aws, CMD=plan|apply|destroy）
# =============================================================================

SHELL := /bin/bash
ENV   ?= ministack
CMD   ?= plan

# ---- MiniStack の起動/停止/確認 ------------------------------------------------
.PHONY: up down logs ps health reset

up:            ## MiniStackを起動
	scripts/ministack-up.sh

down:          ## MiniStackを停止（データは残る）
	scripts/ministack-down.sh

logs:          ## MiniStackのログを追う
	docker logs -f ministack

ps:            ## 起動中のDBコンテナ含め表示
	docker compose --env-file .env --project-directory compose ps

health:        ## ヘルスチェック
	scripts/healthcheck.sh

reset:         ## MiniStackの全状態をリセット（確認あり）
	source lib/ministack.sh && ms_reset

# ---- Terraform -----------------------------------------------------------------
.PHONY: bootstrap tf init plan apply destroy output

bootstrap:     ## tfstate用バケット＋ロックテーブルを作成（ENV=ministack|aws）
	scripts/bootstrap-backend.sh $(ENV)

tf:            ## 任意コマンド実行: make tf ENV=ministack CMD=plan
	scripts/tf.sh $(ENV) $(CMD)

init:          ## terraform init
	scripts/tf.sh $(ENV) init

plan:          ## terraform plan
	scripts/tf.sh $(ENV) plan

apply:         ## terraform apply
	scripts/tf.sh $(ENV) apply

destroy:       ## terraform destroy
	scripts/tf.sh $(ENV) destroy

output:        ## terraform output
	scripts/tf.sh $(ENV) output

# ---- AWS移行 --------------------------------------------------------------------
.PHONY: migrate-s3 migrate-rds

migrate-s3:    ## S3データ同期: make migrate-s3 ARGS="--bucket my-bucket --dry-run"
	scripts/migrate-s3.sh $(ARGS)

migrate-rds:   ## RDS移行: make migrate-rds ARGS="--list"
	scripts/migrate-rds.sh $(ARGS)

# ---- その他 ----------------------------------------------------------------------
.PHONY: help fmt-check

fmt-check:     ## terraform fmt チェック
	terraform -chdir=terraform/base-stack fmt -check -recursive

help:          ## このヘルプを表示
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
