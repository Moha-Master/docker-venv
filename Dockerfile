ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG DEV_USER
ARG DEV_UID
ARG DEV_GID
ARG BASE_PACKAGES
ARG NPM_ALLOW_SCRIPTS
ARG NPM_GLOBAL_PACKAGES
ARG PIP_GLOBAL_PACKAGES
ARG INSTALL_NODE

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/${DEV_USER}

# ---- 1. 基础包 + 用户创建 (使用上游默认源) ----
RUN set -eux; \
    if [ -n "${BASE_PACKAGES:-}" ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends ${BASE_PACKAGES}; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    install -d -m 755 /etc/sudoers.d; \
    EXISTING=$(getent passwd ${DEV_UID} | cut -d: -f1 || true); \
    if [ -z "${EXISTING}" ]; then \
        if ! getent group ${DEV_GID} >/dev/null; then groupadd -g ${DEV_GID} ${DEV_USER}; fi; \
        useradd -m -u ${DEV_UID} -g ${DEV_GID} -s /bin/bash ${DEV_USER}; \
    elif [ "${EXISTING}" != "${DEV_USER}" ]; then \
        usermod -l ${DEV_USER} -d /home/${DEV_USER} -m ${EXISTING}; \
        EXISTING_GROUP=$(getent group ${DEV_GID} | cut -d: -f1 || true); \
        if [ -n "${EXISTING_GROUP}" ] && [ "${EXISTING_GROUP}" != "${DEV_USER}" ]; then \
            groupmod -n ${DEV_USER} ${EXISTING_GROUP}; \
        fi; \
    fi; \
    echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${DEV_USER}; \
    chmod 440 /etc/sudoers.d/${DEV_USER}; \
    chown -R ${DEV_UID}:${DEV_GID} /home/${DEV_USER}

# ---- 2. Node.js 24 (当且仅当 INSTALL_NODE 为 true 时安装，默认值为 true) ----
COPY config/nodesource.sources /etc/apt/sources.list.d/nodesource.sources
COPY config/nodesource.gpg /usr/share/keyrings/nodesource.gpg
COPY config/nodejs.pin /etc/apt/preferences.d/nodejs
RUN set -eux; \
    if [ "${INSTALL_NODE:-true}" = "true" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends nodejs \
        && rm -rf /var/lib/apt/lists/*; \
    else \
        echo "Skip Node.js installation"; \
        rm -f /etc/apt/sources.list.d/nodesource.sources /usr/share/keyrings/nodesource.gpg /etc/apt/preferences.d/nodejs; \
    fi

# ---- 3. 全局工具链部署 ----
USER ${DEV_USER}

# npm 全局工具 (仅当安装了 Node 且包列表非空时执行)
# --allow-scripts: npm >=11.16 生效 (npm 12 起 install script 默认拒绝); 旧版 npm 仅打印
# "Unknown cli config" 警告并忽略, 退出码仍为 0, 不中断构建 (npm 9.2/11.14 实测)
RUN set -eux; \
    if [ "${INSTALL_NODE:-true}" = "true" ] && [ -n "${NPM_GLOBAL_PACKAGES:-}" ]; then \
        if [ -n "${NPM_ALLOW_SCRIPTS:-}" ]; then \
            npm install -g ${NPM_GLOBAL_PACKAGES} --prefix=/home/${DEV_USER}/.local --allow-scripts=${NPM_ALLOW_SCRIPTS}; \
        else \
            npm install -g ${NPM_GLOBAL_PACKAGES} --prefix=/home/${DEV_USER}/.local; \
        fi; \
    fi

# pip 全局工具
RUN set -eux; \
    if [ -n "${PIP_GLOBAL_PACKAGES:-}" ]; then \
        pip install --break-system-packages --user -U ${PIP_GLOBAL_PACKAGES}; \
    fi

# ---- 4. 镜像优化/换肤 ----
USER root
# 复制二进制工具
COPY bin/aria2c /usr/local/bin/aria2c
COPY bin/tcping /usr/local/bin/tcping
COPY bin/git-credential /usr/local/bin/git-credential

# 注入国内优化配置
COPY config/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources
COPY config/nanorc /etc/nanorc
COPY config/gitconfig /etc/gitconfig
COPY config/bash.bashrc /etc/bash.bashrc
COPY config/environment /etc/environment
COPY config/pip.conf /etc/pip.conf

# 注入国内 .npmrc (仅当安装了 Node 时执行)
# allow-scripts 同时写入运行期配置: 容器内 npm -g / npx 沿用同一份白名单
# (注意: 项目级 npm install/ci 不能用 --allow-scripts 命令行, npm 11.16+ 会直接报错,
#  项目应写 package.json#allowScripts; 此处 .npmrc 与构建期的 -g 用法均属合法上下文)
COPY --chown=${DEV_UID}:${DEV_GID} config/.npmrc /home/${DEV_USER}/.npmrc
RUN set -eux; \
    if [ "${INSTALL_NODE:-true}" = "true" ]; then \
        echo "prefix=/home/${DEV_USER}/.local" >> /home/${DEV_USER}/.npmrc; \
        if [ -n "${NPM_ALLOW_SCRIPTS:-}" ]; then \
             echo "allow-scripts=${NPM_ALLOW_SCRIPTS}" >> /home/${DEV_USER}/.npmrc; \
        fi; \
    else \
        echo "Skip .npmrc setup"; \
        rm -f /home/${DEV_USER}/.npmrc; \
    fi

# ---- 5. 运行环境设置 ----
ENV PATH="/home/${DEV_USER}/.local/bin:${PATH}"
WORKDIR /workspace
USER ${DEV_USER}
