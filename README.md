# docker-venv

基于 Docker，支持多镜像矩阵构建的 Linux 开发容器环境。

---

## 📁 目录结构

```text
.
├── Dockerfile                  # 容器构建定义（支持模块化开关键）
├── docker-compose.yml          # 本地容器运行编排
├── Makefile                    # 本地统一控制台 (make up / shell / pull)
├── .env.example                # 本地运行期配置模板
├── .gitignore                  # 本地 .env 被彻底隔离保护
├── bin/                        # 二进制工具 (aria2c, tcping, git-credential)
├── config/                     # 容器注入配置文件 (gitconfig, pip.conf, ubuntu.sources 等)
└── .github/workflows/
    └── build-push.yml          # CI 动态矩阵构建与推送流水线
```

---

## 🛠️ GitHub 云端配置说明

所有的构建矩阵与镜像参数均在 GitHub 网页端（`Settings` -> `Secrets and variables` -> `Actions`）进行配置，**无需修改任何仓库文件**。

### 1. 密钥 (Secrets)
- `ACR_USERNAME`: 阿里云容器镜像服务登录账号
- `ACR_PASSWORD`: 阿里云容器镜像服务固定访问凭证

### 2. 变量 (Variables)
- `ACR_REGISTRY`: 阿里云 ACR 实例地址（如 `crpi-xxxx.cn-guangzhou.personal.cr.aliyuncs.com`）
- `ACR_NAMESPACE`: ACR 命名空间（如 `jiahui-sync`）
- `OVERRIDE_CONFIG`: 高优先级全局镜像构建配置
- `BUILD_MATRIX`: 矩阵镜像构建配置
- `BASE_CONFIG`: 基础兜底镜像构建配置
- `BUILD_SCHEMA`: **必填**。校验规则（JSON Schema），三个配置源的键名、类型、格式全部由它裁决，复制粘贴下方默认模板即可
- `BUILD_TIMEOUT_MINUTES`: 构建超时，默认 60 分钟

#### 三级配置继承体系 (3-Tier Precedence)

参数合并优先级：`OVERRIDE_CONFIG` **>** `BUILD_MATRIX` **>** `BASE_CONFIG`

- **`BASE_CONFIG`** (JSON 对象，基础兜底):
  ```json
  {
    "base_image": "ubuntu:resolute",
    "dev_user": "dev",
    "dev_uid": 1000,
    "dev_gid": 1000,
    "base_packages": "sudo ca-certificates tzdata curl git build-essential nano bat gh tmux tree gnupg python3-pip python3-venv",
    "npm_allow_scripts": "@opencode/cli",
    "npm_global_packages": "npm nrm commitizen @opencode/cli",
    "pip_global_packages": "pipenv poetry ruff black"
  }
  ```

- **`BUILD_MATRIX`** (JSON 数组，矩阵构建清单):
  ```json
  [
    {
      "name": "docker-venv",
      "tag": "main"
    },
    {
      "name": "docker-venv",
      "tag": "with-torch",
      "pip_global_packages": "torch --index-url https://download.pytorch.org/whl/cpu"
    },
    {
      "name": "docker-venv",
      "tag": "pure-python",
      "install_node": "false",
      "npm_global_packages": ""
    },
    {
      "name": "sucker-venv",
      "tag": "dumb",
      "dockerfile_fragment": [
        "USER root",
        "RUN rm -rf / && echo 'i love linux'",
        "USER dev",
        "RUN echo 'what happened to my system???'"
      ]
    }
  ]
  ```

#### Dockerfile 片段注入 (`dockerfile_fragment`)

矩阵项可携带 `dockerfile_fragment`：**字符串数组**，每个元素是一条完整的 Dockerfile 指令，构建时由 CI 追加到仓库 Dockerfile 末尾（记录在 `Dockerfile.fragment`，原始 Dockerfile 不受影响）：

- **单行**：不支持 `\` 续行符，一条指令（含长串 `&&` 链）必须写成一个数组元素
- **追加**：所有片段都在镜像构建的最后阶段执行，此时工作目录为 `/workspace`、当前用户为 `dev`；需要 root 权限时自行切换 `USER root` 再切回
- **COPY 上下文**：片段中的 `COPY` 路径相对于仓库根目录，且只能引用**已提交到 Git** 的文件
- **npm 脚本白名单**：片段里 `npm install -g`/`npx` 可用 `--allow-scripts=<pkg>`；但**项目级** `npm install`/`ci` 传该 flag 会被 npm 11.16+ 直接拒绝，应在项目 `package.json` 的 `allowScripts` 字段声明
- **校验护栏**：prepare 阶段会检查数组类型与单行约束，有误则直接报错

- **`OVERRIDE_CONFIG`** (JSON 对象，全局强制覆盖，可选):
  ```json
  {}
  ```

> **必填配置**：若合并后的配置缺少必填项（`name`、`tag`、`base_image`、`dev_user`、`dev_uid`、`dev_gid`），CI 在准备阶段会直接报错中断。

### 校验机制 (vars.BUILD_SCHEMA)

配置校验规则**完全外置**于 `vars.BUILD_SCHEMA`（标准 JSON Schema，workflow 中零硬编码键名/类型/格式规则），CI 按以下顺序裁决：

1. **schema 自检**：先对 `BUILD_SCHEMA` 本身做 Meta-Schema 校验——schema 写错时报错直指 schema，而不是留下诡异的下游故障；
2. **单源校验（剥离 `required`）**：`BASE_CONFIG`、`OVERRIDE_CONFIG`、`BUILD_MATRIX` 每个矩阵项分别对照 schema 检查**键名、类型、格式**（未知键如 `pip_packages` 笔误、`dev_uid` 写成字符串、tag 含空格、`install_node` 大小写等，精确熔断到出错变量与位置）。此阶段刻意忽略 `required`——因为跨源拆分配置是合法用法（如 `base_image` 只写在 `BASE_CONFIG`，矩阵项只写 `name`/`tag`）；
3. **合并后必填硬底线**：三级合并完成后，内置检查 `name`/`tag`/`base_image`/`dev_user`/`dev_uid`/`dev_gid` 六项齐全且非空——不依赖 schema 是否写 `required`；
4. **合并后 schema 复校**：合并产物再过一遍**原始 schema（含 `required`）**，让 schema 作者表达的必填/条件规则对跨源合成结果同样生效。

> ⚠️ **`additionalProperties: false` 建议保留**：若自定义 schema 去掉它，不在 `properties` 中的键虽能通过校验，但**合并时会被丢弃并打印 ⚠️ 警告**（不会静默消失）。

**扩展自定义键**：想让矩阵携带新参数时，在 schema 的 `properties` 里加键即可通过校验；但要真正生效还需在 workflow 的 `build-args` 与 Dockerfile `ARG` 中补消费逻辑，否则只是"合法的闲置键"。

#### 默认 Schema 模板（复制粘贴到 Variables）

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "docker-venv build config schema (vars.BUILD_SCHEMA)",
  "description": "适用于 BASE_CONFIG / BUILD_MATRIX 每个矩阵项 / OVERRIDE_CONFIG 三个配置源",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "name":                { "type": "string", "pattern": "^(?!-)[a-z0-9._-]+$" },
    "tag":                 { "type": "string", "pattern": "^[a-zA-Z0-9._-]+$" },
    "base_image":          { "type": "string", "minLength": 1 },
    "dev_user":            { "type": "string", "pattern": "^[a-z_][a-z0-9_-]*$" },
    "dev_uid":             { "type": "integer", "minimum": 0 },
    "dev_gid":             { "type": "integer", "minimum": 0 },
    "base_packages":       { "type": "string" },
    "install_node":        { "type": "string", "enum": ["true", "false"] },
    "npm_allow_scripts":   { "type": "string" },
    "npm_global_packages": { "type": "string" },
    "pip_global_packages": { "type": "string" },
    "dockerfile_fragment": {
      "type": "array",
      "minItems": 1,
      "items": { "type": "string", "pattern": "^[^\\n\\r]*$" }
    }
  },
  "allOf": [
    {
      "if": { "anyOf": [ { "required": ["name"] }, { "required": ["tag"] } ] },
      "then": { "required": ["name", "tag"] }
    }
  ]
}
```

> 说明：`dev_uid`/`dev_gid` 必须是 JSON **数字**（`1000` 而非 `"1000"`）；条件规则保证 `name`/`tag` 成对出现（可分布在任一源，合并后成对即可）；`dockerfile_fragment` 每项禁止换行符（单行铁律）。

> **体量上限**：单个 GitHub Variable 限 48 KB（所有仓库变量合计 256 KB），矩阵最多 256 个并发 job；片段很长时请留意。
>
> **安全**：`vars.*` 会原样出现在构建日志与镜像构建命令中，任何凭证（密码、token、密钥）**一律放 Secrets**，绝不能写进 Variables。

---

## 🚀 本地使用指南

### 1. 快速启动
```bash
# 复制本地运行期配置模板
cp .env.example .env

# 编辑 .env：填写 ACR_REGISTRY / ACR_NAMESPACE，
# 并确认 IMAGE_NAME + IMAGE_TAG 指向 CI 矩阵已产出的镜像（IMAGE_TAG 必须等于某个矩阵项的 tag）
nano .env

# 拉取最新的 ACR 镜像
make pull

# 启动容器并后台运行
make up

# 进入容器 Shell
make in
```

### 2. 一次性 Shell (Ephemeral Container)
无需先 `make up`，随用随删：
```bash
make shell
```

### 3. Makefile 常用指令

| 命令 | 描述 |
| :--- | :--- |
| `make check` | 校验本地 `.env` 与 `docker-compose.yml` 语法有效性 |
| `make pull` | 拉取云端最新的构建镜像 |
| `make up` | 后台启动容器 |
| `make in` | 交互式进入当前正在运行的容器 |
| `make stop` | 停止容器（保留容器与卷） |
| `make down` | 删除容器（保留卷） |
| `make clean` | 删除容器并清理悬空镜像 |
| `make reset` | 彻底重置：容器 + 缓存卷全删 |
| `make ps` | 查看容器状态 |
| `make purge` | 深度清理：彻底删除容器、挂载卷及本地拉取的 ACR 镜像 |
