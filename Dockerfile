# CatWrt 编译环境 Docker 镜像 (优化版)
# 基于 Ubuntu 22.04 LTS，包含完整的 OpenWrt/LEDE 编译依赖

FROM ubuntu:22.04

# 构建参数
ARG MAKE_JOBS=4

# 环境变量
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
ENV FORCE_UNSAFE_CONFIGURE=1
ENV MAKE_JOBS=${MAKE_JOBS}

# 安装基础工具和编译依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        # ... (保持原有依赖列表不变) ...
        sudo time tzdata file gosu \
        generate-ninja \
        htop iotop strace && \
    # 设置时区
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
    # 清理
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 创建普通用户
RUN groupadd -g 1000 builder && \
    useradd -u 1000 -g builder -m -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder && \
    chmod 0440 /etc/sudoers.d/builder && \
    mkdir -p /home/lede /home/catwrt_base /output /var/log/catwrt-build && \
    chown -R builder:builder /home /output /var/log/catwrt-build

# 预下载 ImmortalWrt 环境脚本
RUN curl -fsSL -o /usr/local/bin/init_build_environment.sh \
    https://build-scripts.immortalwrt.org/init_build_environment.sh && \
    chmod +x /usr/local/bin/init_build_environment.sh && \
    bash /usr/local/bin/init_build_environment.sh || true

# 配置 ccache 并确保 builder 用户有权限
RUN mkdir -p /home/builder/.ccache && \
    chown -R builder:builder /home/builder/.ccache && \
    sudo -u builder ccache -M 10G || true

# 复制脚本
COPY --chown=builder:builder build_catwrt_ci.sh /usr/local/bin/catwrt-build
RUN chmod +x /usr/local/bin/catwrt-build

COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD test -f /usr/local/bin/catwrt-build && test -d /home/lede || exit 1

WORKDIR /home

ENTRYPOINT ["/entrypoint.sh"]
CMD ["--help"]
