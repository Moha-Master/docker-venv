# 1. 加载本地运行期配置 (Ignored by Git)
-include .env

# 2. 导出所有变量为环境变量，让 docker compose 能够直接插值
export

.PHONY: check pull up in shell stop down clean reset purge ps

check:          ## 校验配置
	docker compose config --quiet && echo "Config Validated."

pull:           ## 拉取镜像
	docker compose pull

up:             ## 启动容器
	docker compose up -d

in:             ## 进入容器
	docker compose exec dev bash

shell:          ## 一次性容器 shell
	docker compose run --rm dev bash

stop:           ## 停止
	docker compose stop

down:           ## 删除容器
	docker compose down

clean:          ## 删容器 + 悬空镜像
	docker compose down
	docker image prune -f

reset:          ## 彻底重置：容器 + 缓存卷全删
	docker compose down -v

purge:          ## 连镜像一起删
	docker compose down -v
	docker compose config --images | xargs -r docker rmi

ps:             ## 查看状态
	docker compose ps
