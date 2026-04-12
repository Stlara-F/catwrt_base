# CatWrt 编译环境 Docker 镜像 (优化版)
# 基于 Ubuntu 22.04 LTS，包含完整的 OpenWrt/LEDE 编译依赖
# 使用方式: 
#   docker run --rm -v ./output:/output catwrt/builder --auto --arch=amd64 --ver=v24.9

FROM ubuntu:22.04

# 环境变量
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
ENV FORCE_UNSAFE_CONFIGURE=1
# 核心修改：将MAKE_JOBS从4改为2，适配GitHub Actions双核Runner
ENV MAKE_JOBS=2
ENV CATWRT_DOCKER_MODE=1
ENV CCACHE_DIR=/home/builder/.ccache

# 安装基础工具和编译依赖（合并 RUN 减少层数）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        # 基础工具
        ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
        bzip2 ccache clang cmake cpio curl device-tree-compiler flex gawk \
        gcc-multilib g++-multilib gettext genisoimage git gperf haveged help2man \
        intltool libc6-dev-i386 libelf-dev libfuse-dev libglib2.0-dev libgmp3-dev \
        libltdl-dev libmpc-dev libmpfr-dev libncurses5-dev libncursesw5-dev \
        libpython3-dev libreadline-dev libssl-dev libtool llvm lrzsz msmtp \
        ninja-build p7zip p7zip-full patch pkgconf python3 python3-pyelftools \
        python3-setuptools qemu-utils rsync scons squashfs-tools subversion swig \
        texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev \
        sudo time tzdata file gosu \
        # 额外依赖（naive 编译需要）
        generate-ninja \
        # 调试工具
        htop iotop strace && \
    # 设置时区
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
    # 配置 ccache
    ccache --max-size=5G && \
    # 清理
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 创建普通用户（编译 LEDE 必须使用非 root）
# 使用固定 UID/GID 1000，完美匹配 GitHub Actions runner 的默认用户，彻底解决权限问题！
RUN groupadd -g 1000 builder && \
    useradd -u 1000 -g builder -m -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder && \
    chmod 0440 /etc/sudoers.d/builder && \
    mkdir -p /home/lede /home/catwrt_base /output /var/log/catwrt-build && \
    chown -R builder:builder /home /output /var/log/catwrt-build

# 声明 volume 以便在 GitHub Actions 中挂载缓存
VOLUME ["/home/builder/.ccache", "/home/lede/dl"]

# 预下载 ImmortalWrt 环境脚本（加速首次运行）
RUN curl -fsSL -o /usr/local/bin/init_build_environment.sh \
    https://build-scripts.immortalwrt.org/init_build_environment.sh && \
    chmod +x /usr/local/bin/init_build_environment.sh && \
    # 执行环境初始化（幂等）
    bash /usr/local/bin/init_build_environment.sh || true

# 复制编译脚本（确保是最终优化版，放在最后以利用缓存）
COPY --chown=builder:builder build_catwrt_ci.sh /usr/local/bin/catwrt-build
RUN chmod +x /usr/local/bin/catwrt-build

# 复制入口脚本
COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 健康检查（确保环境就绪）
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD test -f /usr/local/bin/catwrt-build && test -d /home/lede || exit 1

# 工作目录
WORKDIR /home

# 使用 gosu 切换用户（比 sudo 更干净）
ENTRYPOINT ["/entrypoint.sh"]

# 默认显示帮助
CMD ["--help"]
