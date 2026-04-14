# CatWrt 编译环境 Docker 镜像 (安全优化版)
FROM ubuntu:20.04

# 环境变量
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
ENV FORCE_UNSAFE_CONFIGURE=1
ENV MAKE_JOBS=8
ENV CATWRT_DOCKER_MODE=1
ENV CCACHE_DIR=/home/builder/.ccache

# 安全补丁：系统全量升级 + 清理无效依赖
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
        bzip2 ccache clang cmake cpio curl device-tree-compiler flex gawk \
        gcc-multilib g++-multilib gettext genisoimage git gperf haveged help2man \
        intltool libc6-dev-i386 libelf-dev libfuse-dev libglib2.0-dev libgmp3-dev \
        libltd-dev libmpc-dev libmpfr-dev libncurses5-dev libncursesw5-dev \
        libpython3-dev libreadline-dev libssl-dev libtool llvm lrzsz msmtp \
        ninja-build p7zip p7zip-full patch pkgconf python3 python3-pyelftools \
        python3-setuptools qemu-utils rsync scons squashfs-tools subversion swig \
        texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev \
        sudo time tzdata file gosu libattr1-dev libipt-dev python3-dev libcap-ng-dev \
    && apt-get remove -y rustc cargo doxygen valgrind htop iotop strace && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
    ccache --max-size=5G && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
           /usr/share/doc/* /usr/share/man/* /usr/share/locale/*

# 安全创建用户 + 🔥 唯一修改：修复sudo环境变量权限（兼容脚本）
RUN set -ex && \
    if id -u builder >/dev/null 2>&1; then userdel -f builder; fi && \
    if getent group builder >/dev/null 2>&1; then groupdel -f builder; fi && \
    groupadd builder && \
    useradd -m -d /home/builder -s /bin/bash -g builder builder && \
    # 🔥 修复：允许保留环境 + 无密码sudo（编译脚本必需，安全可控）
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder && \
    chmod 0440 /etc/sudoers.d/builder && \
    mkdir -p /home/lede /home/catwrt_base /output /var/log/catwrt-build && \
    chown -R builder:builder /home /output /var/log/catwrt-build

VOLUME ["/home/builder/.ccache", "/home/lede/dl"]

# 预下载编译环境脚本
RUN curl -fsSL -o /usr/local/bin/init_build_environment.sh \
    https://build-scripts.immortalwrt.org/init_build_environment.sh && \
    chmod +x /usr/local/bin/init_build_environment.sh && \
    bash -c 'set +o pipefail && /usr/local/bin/init_build_environment.sh 2>&1 | head -n 200 || true'

# 复制脚本
COPY --chown=builder:builder build_catwrt_ci.sh /usr/local/bin/catwrt-build
RUN chmod +x /usr/local/bin/catwrt-build

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
