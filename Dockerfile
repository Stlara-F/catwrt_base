# CatWrt 编译环境 Docker 镜像 (优化版)
# 基于 Ubuntu 22.04 LTS，包含完整的 OpenWrt/LEDE 编译依赖
# 使用方式: 
#   docker run --rm -v ./output:/output catwrt/builder --auto --arch=amd64 --ver=v24.9

FROM ubuntu:25.10

# 环境变量
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
ENV FORCE_UNSAFE_CONFIGURE=1
ENV MAKE_JOBS=8
ENV CATWRT_DOCKER_MODE=1
ENV CCACHE_DIR=/home/builder/.ccache

# 安装基础工具和编译依赖
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
        generate-ninja \
        htop iotop strace \
        # 修复缺失依赖
        libattr1-dev libdebuginfod-dev libipt-dev python3-dev doxygen valgrind libcap-ng-dev \
        rustc cargo && \
    # 设置时区
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
    # 配置 ccache
    ccache --max-size=5G && \
    # 清理
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 🔥 修复：安全创建 builder 用户，彻底消除家目录警告
RUN groupadd -g 1000 builder && \
    # 先删除可能存在的旧用户（安全）
    if id -u builder >/dev/null 2>&1; then \
        userdel -r builder 2>/dev/null || true; \
    fi && \
    # 重新创建用户
    useradd -u 1000 -g builder -m -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder && \
    chmod 0440 /etc/sudoers.d/builder && \
    mkdir -p /home/lede /home/catwrt_base /output /var/log/catwrt-build && \
    chown -R builder:builder /home /output /var/log/catwrt-build

# 声明 volume
VOLUME ["/home/builder/.ccache", "/home/lede/dl"]

# 🔥 修复：预下载 ImmortalWrt 环境脚本，显式使用 bash 避免 pipefail 错误
RUN curl -fsSL -o /usr/local/bin/init_build_environment.sh \
    https://build-scripts.immortalwrt.org/init_build_environment.sh && \
    chmod +x /usr/local/bin/init_build_environment.sh && \
    # 显式使用 bash 执行，临时关闭 pipefail 避免 broken pipe
    bash -c 'set +o pipefail && /usr/local/bin/init_build_environment.sh 2>&1 | head -n 200 || true'


# 复制编译脚本
COPY --chown=builder:builder build_catwrt_ci.sh /usr/local/bin/catwrt-build
RUN chmod +x /usr/local/bin/catwrt-build

# 复制入口脚本
COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD test -f /usr/local/bin/catwrt-build && test -d /home/lede || exit 1

# 工作目录
WORKDIR /home

# 入口点
ENTRYPOINT ["/entrypoint.sh"]
CMD ["--help"]
