#!/bin/bash
# CatWrt 完全自动化编译脚本 (v2.3.2 - 修复挂载点删除失败)
# 真正无人值守，零交互，失败自动重试
# 用法: sudo ./build_catwrt_ci.sh --auto --user=miaoer --arch=amd64 --ver=v24.9

set -euo pipefail

# ---------------------------- 全局配置参数 ----------------------------
NORMAL_USER="${CATWRT_USER:-$(logname 2>/dev/null || echo "builder")}"
TARGET_ARCH="${CATWRT_ARCH:-"amd64"}"
TARGET_VER="${CATWRT_VER:-"v24.9"}"
SKIP_FIRST_BUILD="${SKIP_FIRST_BUILD:-true}"
USE_PRESET_CONFIG="${USE_PRESET_CONFIG:-true}"
CONFIG_TYPE="${CONFIG_TYPE:-}"
AUTO_MODE="${AUTO_MODE:-false}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
MAX_RETRIES="${MAX_RETRIES:-3}"

CLEAN_BUILD="${CLEAN_BUILD:-false}"
SINGLE_THREAD_FIRST="${SINGLE_THREAD_FIRST:-false}"
AUTO_RETRY_SINGLE="${AUTO_RETRY_SINGLE:-true}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
CATWRT_DOCKER_MODE="${CATWRT_DOCKER_MODE:-0}"

LEDE_DIR="/home/lede"
CATWRT_BASE_DIR="/home/catwrt_base"
LOG_DIR="/var/log/catwrt-build"
LOG_FILE="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/tmp/catwrt-build.lock"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ---------------------------- 核心工具函数 ----------------------------
log() {
    local level="$1"; shift
    local color="$NC"
    case "$level" in
        INFO) color="$GREEN" ;;
        WARN) color="$YELLOW" ;;
        ERROR) color="$RED" ;;
    esac
    echo -e "${color}[$level]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

die() {
    log ERROR "$@"
    if [[ -n "$DISCORD_WEBHOOK" ]]; then
        curl -fsSL -X POST -H "Content-Type: application/json" \
            -d "{\"content\":\"❌ CatWrt 编译失败: $*\"}" "$DISCORD_WEBHOOK" || true
    fi
    exit 1
}

retry() {
    local n=1
    local cmd="$*"
    while true; do
        log INFO "执行: $cmd (尝试 $n/$MAX_RETRIES)"
        if eval "$cmd" 2>&1 | tee -a "$LOG_FILE"; then
            return 0
        fi
        if [[ $n -ge $MAX_RETRIES ]]; then
            die "命令失败超过 $MAX_RETRIES 次: $cmd"
        fi
        ((n++))
        log WARN "命令失败，$((2**n)) 秒后重试..."
        sleep $((2**n))
    done
}

fix_lede_permissions() {
    local owner=$(stat -c '%U' "$LEDE_DIR" 2>/dev/null || echo "root")
    if [[ "$owner" == "root" ]]; then
        log WARN "检测到 LEDE 目录被 root 拥有，修复权限..."
        chown -R "$NORMAL_USER":"$NORMAL_USER" "$LEDE_DIR"
    fi
    local bad_dirs=$(find "$LEDE_DIR" -user root -type d 2>/dev/null | head -5)
    if [[ -n "$bad_dirs" ]]; then
        log WARN "发现 root 拥有的子目录，批量修复..."
        chown -R "$NORMAL_USER":"$NORMAL_USER" "$LEDE_DIR"
    fi
}

# ---------------------------- 预检 ----------------------------
check_env() {
    [[ $EUID -eq 0 ]] || die "必须使用 root 运行"
    [[ -d "/home" ]] || die "/home 目录不存在"
    mkdir -p "$LOG_DIR"

    if [[ "$CATWRT_DOCKER_MODE" == "1" ]]; then
        log INFO "运行在 Docker 模式中，跳过宿主机检查"
        id "$NORMAL_USER" &>/dev/null || die "用户 $NORMAL_USER 不存在"
    else
        local avail_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G')
        [[ $avail_gb -gt 50 ]] || die "磁盘空间不足 50GB (当前: ${avail_gb}GB)"
        local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
        [[ $mem_gb -gt 3 ]] || log WARN "内存不足 4GB，编译可能缓慢或失败"
    fi

    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        log INFO "检测到 GitHub Actions 环境，限制编译线程为 2 (防止内存溢出)"
        MAKE_JOBS=2
        export DOWNLOAD_JOBS=2
    fi

    retry "curl -fsSL --connect-timeout 10 https://github.com"
    id "$NORMAL_USER" &>/dev/null || die "用户 $NORMAL_USER 不存在"
    ulimit -n 65535 2>/dev/null || log WARN "无法设置 ulimit -n 65535"

    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            die "另一个编译进程正在运行 (PID: $pid)"
        fi
    fi
    echo $$ > "$LOCK_FILE"

    log INFO "环境检查通过 | 用户: $NORMAL_USER | 架构: $TARGET_ARCH | 自动模式: $AUTO_MODE"
}

# ---------------------------- 步骤1：依赖安装 ----------------------------
install_deps() {
    log INFO "步骤1: 安装编译依赖"
    export DEBIAN_FRONTEND=noninteractive
    retry "apt-get update -qq"

    if ! dpkg -l | grep -q "build-essential"; then
        log INFO "安装基础依赖..."
        apt-get install -y -qq \
            ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
            bzip2 ccache clang cmake cpio curl device-tree-compiler flex gawk \
            gcc-multilib g++-multilib gettext genisoimage git gperf haveged help2man \
            intltool libc6-dev-i386 libelf-dev libfuse-dev libglib2.0-dev libgmp3-dev \
            libltdl-dev libmpc-dev libmpfr-dev libncurses5-dev libncursesw5-dev \
            libpython3-dev libreadline-dev libssl-dev libtool llvm lrzsz msmtp \
            ninja-build p7zip p7zip-full patch pkgconf python3 python3-pyelftools \
            python3-setuptools qemu-utils rsync scons squashfs-tools subversion swig \
            texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev
    else
        log INFO "依赖已安装，跳过"
    fi

    if [[ ! -f "/etc/catwrt-env-ready" ]]; then
        log INFO "初始化 ImmortalWrt 编译环境..."
        bash -c 'bash <(curl -fsSL https://build-scripts.immortalwrt.org/init_build_environment.sh)'
        touch /etc/catwrt-env-ready
    fi

    sudo -u "$NORMAL_USER" ccache -M 10G 2>/dev/null || true
    log INFO "依赖安装完成"
}

# ---------------------------- 步骤2：仓库准备 ----------------------------
setup_repos() {
    log INFO "步骤2: 准备代码仓库"

    # CatWrt Base
    if [[ -d "$CATWRT_BASE_DIR/.git" ]]; then
        cd "$CATWRT_BASE_DIR"
        retry "git pull origin main"
    else
        rm -rf "$CATWRT_BASE_DIR" 2>/dev/null || true
        retry "git clone https://github.com/miaoermua/catwrt_base.git $CATWRT_BASE_DIR"
    fi
    chmod +x "$CATWRT_BASE_DIR"/*.sh 2>/dev/null || true

    # LEDE
    if [[ -d "$LEDE_DIR/.git" ]]; then
        log INFO "LEDE 已存在，更新源码..."
        cd "$LEDE_DIR"
        fix_lede_permissions
        sudo -u "$NORMAL_USER" git fetch origin
        sudo -u "$NORMAL_USER" git reset --hard origin/master
        sudo -u "$NORMAL_USER" git pull
    else
        # 如果目录存在但不是 git 仓库，则安全清理（处理挂载点占用）
        if [[ -d "$LEDE_DIR" ]]; then
            log WARN "/home/lede 目录存在但非 Git 仓库，尝试安全清理..."
            # 检查是否有子目录是挂载点，尝试卸载
            local mounts=$(mount | grep "$LEDE_DIR" | awk '{print $3}' || true)
            if [[ -n "$mounts" ]]; then
                for mnt in $mounts; do
                    log WARN "发现挂载点: $mnt，尝试卸载..."
                    umount "$mnt" 2>/dev/null || log WARN "无法卸载 $mnt，将保留该目录"
                done
            fi
            # 清空除 dl 外的内容（dl 可能是缓存挂载点）
            find "$LEDE_DIR" -mindepth 1 -maxdepth 1 -not -name dl -exec rm -rf {} \; 2>/dev/null || true
            if [[ -d "$LEDE_DIR/dl" ]]; then
                log WARN "保留 dl 目录（可能为挂载缓存），仅清空其他内容"
            fi
        fi
        log INFO "克隆 LEDE 源码..."
        retry "sudo -u $NORMAL_USER git clone https://github.com/coolsnowwolf/lede.git $LEDE_DIR"
        fix_lede_permissions
    fi
}

# ---------------------------- 步骤3：智能配置选择 ----------------------------
select_config() {
    local TARGET_ARCH="${TARGET_ARCH:-amd64}"
    local CATWRT_BASE_DIR="${CATWRT_BASE_DIR:-/home/catwrt_base}"
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local NORMAL_USER="${NORMAL_USER:-builder}"

    log INFO "步骤3: 选择编译配置"

    if [[ -n "$CONFIG_TYPE" ]]; then
        local cfg_file="$CATWRT_BASE_DIR/build/config/${CONFIG_TYPE}.config"
        [[ -f "$cfg_file" ]] || die "指定的配置文件不存在: $cfg_file"
        log INFO "使用指定配置: $CONFIG_TYPE"
        sudo -u "$NORMAL_USER" cp "$cfg_file" "$LEDE_DIR/.config"
        return
    fi

    local auto_config=""
    case "$TARGET_ARCH" in
        amd64)
            auto_config="$CATWRT_BASE_DIR/build/config/amd64.config"
            [[ -f "$auto_config" ]] || auto_config="$CATWRT_BASE_DIR/build/config/amd64.luci2.config"
            ;;
        mt7621)
            auto_config="$CATWRT_BASE_DIR/build/config/mt7621.config" 2>/dev/null || true
            ;;
        mt798x)
            auto_config="$CATWRT_BASE_DIR/build/config/mt798x.config" 2>/dev/null || true
            ;;
        diy/*)
            local diy_name="${TARGET_ARCH#diy/}"
            auto_config="$CATWRT_BASE_DIR/build/config/${diy_name}.config" 2>/dev/null || true
            ;;
    esac

    if [[ -f "$auto_config" ]]; then
        log INFO "自动选择配置: $(basename "$auto_config")"
        sudo -u "$NORMAL_USER" cp "$auto_config" "$LEDE_DIR/.config"
    else
        log WARN "未找到预置配置，尝试生成最小可用配置..."
        _generate_minimal_config
    fi
}

_generate_minimal_config() {
    local TARGET_ARCH="${TARGET_ARCH:-amd64}"
    local TARGET_VER="${TARGET_VER:-v24.9}"
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local NORMAL_USER="${NORMAL_USER:-builder}"

    local target_system=""
    local subtarget=""
    local device="default"

    case "$TARGET_ARCH" in
        amd64) target_system="x86"; subtarget="64"; device="generic" ;;
        mt7621) target_system="mediatek"; subtarget="mt7621" ;;
        mt798x) target_system="mediatek"; subtarget="mt7986" ;;
        meson32) target_system="amlogic"; subtarget="meson8b" ;;
        meson64) target_system="amlogic"; subtarget="mesongxbb" ;;
        rkarm64) target_system="rockchip"; subtarget="rk33xx" ;;
        diy/*) target_system="x86"; subtarget="64"; device="generic" ;;
        *) die "无法为架构 $TARGET_ARCH 生成最小配置" ;;
    esac

    log INFO "生成最小配置: $target_system/$subtarget"
    sudo -u "$NORMAL_USER" bash <<EOF
cd "$LEDE_DIR"
cat > .config <<CONFIG
CONFIG_TARGET_${target_system}=y
CONFIG_TARGET_${target_system}_${subtarget}=y
CONFIG_TARGET_${target_system}_${subtarget}_DEVICE_${device}=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
CONFIG_PACKAGE_default-settings=y
CONFIG_PACKAGE_default-settings-chn=y
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="CatWrt"
CONFIG_VERSION_NUMBER="${TARGET_VER}"
CONFIG_VERSION_CODE="$(date +%Y%m%d)"
CONFIG
make defconfig
EOF
}

# ---------------------------- 步骤4：应用 CatWrt 定制 ----------------------------
apply_custom() {
    local TARGET_ARCH="${TARGET_ARCH:-amd64}"
    local TARGET_VER="${TARGET_VER:-v24.9}"
    local CATWRT_BASE_DIR="${CATWRT_BASE_DIR:-/home/catwrt_base}"
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local NORMAL_USER="${NORMAL_USER:-builder}"

    log INFO "步骤4: 应用 CatWrt 定制"
    cd "$CATWRT_BASE_DIR"
    retry "bash $CATWRT_BASE_DIR/pull.sh"

    log INFO "释放 CatWrt 模板文件..."
    local source_dir=""
    if [[ "$TARGET_ARCH" == diy/* ]]; then
        source_dir="$CATWRT_BASE_DIR/$TARGET_ARCH"
    else
        source_dir="$CATWRT_BASE_DIR/$TARGET_ARCH/$TARGET_VER"
    fi
    [[ -d "$source_dir" ]] || die "配置目录不存在: $source_dir"

    local base_files="$source_dir/base-files/files"
    if [[ -d "$base_files" ]]; then
        [[ -f "$base_files/bin/config_generate" ]] && \
            cp -v "$base_files/bin/config_generate" "$LEDE_DIR/package/base-files/files/bin/"
        [[ -f "$base_files/etc/catwrt_release" ]] && \
            cp -v "$base_files/etc/catwrt_release" "$LEDE_DIR/package/base-files/files/etc/"
        [[ -f "$base_files/etc/banner" ]] && \
            cp -v "$base_files/etc/banner" "$LEDE_DIR/package/base-files/files/etc/"
        [[ -f "$base_files/etc/banner.failsafe" ]] && \
            cp -v "$base_files/etc/banner.failsafe" "$LEDE_DIR/package/base-files/files/etc/"

        if [[ "$TARGET_ARCH" == "mt7621" && -f "$base_files/etc/init.d/mtwifi" ]]; then
            cp -v "$base_files/etc/init.d/mtwifi" "$LEDE_DIR/package/base-files/files/etc/init.d/"
            chmod +x "$LEDE_DIR/package/base-files/files/etc/init.d/mtwifi"
        elif [[ "$TARGET_ARCH" != "mt7621" ]]; then
            rm -f "$LEDE_DIR/package/base-files/files/etc/init.d/mtwifi" 2>/dev/null || true
        fi

        if [[ "$TARGET_ARCH" == "mt798x" && -d "$base_files/usr/bin" ]]; then
            mkdir -p "$LEDE_DIR/package/base-files/files/usr/bin"
            cp -v "$base_files/usr/bin/"* "$LEDE_DIR/package/base-files/files/usr/bin/" 2>/dev/null || true
            chmod +x "$LEDE_DIR/package/base-files/files/usr/bin/"* 2>/dev/null || true
        fi
    fi

    if [[ -d "$source_dir/lean/default-settings/files" ]]; then
        cp -v "$source_dir/lean/default-settings/files/zzz-default-settings" \
            "$LEDE_DIR/package/lean/default-settings/files/"
        chmod +x "$LEDE_DIR/package/lean/default-settings/files/zzz-default-settings"
    fi

    mkdir -p "$LEDE_DIR/package/base-files/files/usr/bin"
    retry "curl -fsSL https://raw.miaoer.net/cattools/cattools.sh -o $LEDE_DIR/package/base-files/files/usr/bin/cattools"
    chmod +x "$LEDE_DIR/package/base-files/files/usr/bin/cattools"
    chmod +x "$LEDE_DIR/package/base-files/files/bin/config_generate"

    fix_lede_permissions
    log INFO "CatWrt 定制应用完成"
}

# ---------------------------- 步骤5：Feeds 更新 ----------------------------
update_feeds() {
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local NORMAL_USER="${NORMAL_USER:-builder}"
    local MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

    log INFO "步骤5: 更新 Feeds"
    cd "$LEDE_DIR"
    sudo -u "$NORMAL_USER" rm -rf tmp/.packageinfo 2>/dev/null || true

    sudo -u "$NORMAL_USER" bash <<EOF
./scripts/feeds clean
./scripts/feeds update -a
./scripts/feeds install -a
EOF

    sudo -u "$NORMAL_USER" bash -c "cd '$LEDE_DIR' && make defconfig"

    log INFO "下载编译依赖包..."
    local dl_jobs="${DOWNLOAD_JOBS:-${MAKE_JOBS}}"
    retry "sudo -u $NORMAL_USER bash -c 'cd $LEDE_DIR && make download -j${dl_jobs}'"
}

# ---------------------------- 步骤6：编译 ----------------------------
do_build() {
    local SINGLE_THREAD_FIRST="${SINGLE_THREAD_FIRST:-false}"
    local AUTO_RETRY_SINGLE="${AUTO_RETRY_SINGLE:-true}"
    local CLEAN_BUILD="${CLEAN_BUILD:-false}"
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local NORMAL_USER="${NORMAL_USER:-builder}"
    local MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
    local LOG_FILE="${LOG_FILE:-/var/log/catwrt-build/build.log}"

    log INFO "步骤6: 开始编译"
    log INFO "使用 $MAKE_JOBS 个并行任务，日志: $LOG_FILE"

    cd "$LEDE_DIR"
    [[ ! -f ".config" ]] && die "缺少 .config 文件，无法编译"

    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        local mem_available=$(free -m | awk '/^Mem:/{print $7}')
        if [[ $mem_available -lt 1024 ]]; then
            log WARN "可用内存仅 ${mem_available}MB，编译可能因 OOM 失败，已强制单线程"
            MAKE_JOBS=1
        fi
    fi

    if [[ "$CLEAN_BUILD" == "true" ]]; then
        log INFO "执行 make clean..."
        sudo -u "$NORMAL_USER" make clean
    fi

    local build_cmd="make V=s -j${MAKE_JOBS}"
    [[ "$SINGLE_THREAD_FIRST" == "true" ]] && build_cmd="make V=s -j1"

    set +e
    sudo -u "$NORMAL_USER" bash -c "cd '$LEDE_DIR' && $build_cmd" 2>&1 | tee -a "$LOG_FILE"
    local ret=$?
    set -e

    if [[ $ret -ne 0 && "${SINGLE_THREAD_FIRST:-false}" != "true" && "${AUTO_RETRY_SINGLE:-true}" == "true" ]]; then
        log WARN "多线程编译失败，尝试单线程重试..."
        set +e
        sudo -u "$NORMAL_USER" bash -c "cd '$LEDE_DIR' && make V=s -j1" 2>&1 | tee -a "$LOG_FILE"
        ret=$?
        set -e
    fi

    [[ $ret -eq 0 ]] || die "编译失败 (退出码: $ret)"

    local bin_dir="$LEDE_DIR/bin/targets"
    [[ -d "$bin_dir" ]] || die "编译成功但未找到输出目录"

    local firmware_count=$(find "$bin_dir" -type f \( -name "*.bin" -o -name "*.img" -o -name "*.gz" \) | wc -l)
    [[ $firmware_count -gt 0 ]] || die "编译完成但未生成固件文件"

    log INFO "编译成功！生成 $firmware_count 个固件文件"
    find "$bin_dir" -type f -exec ls -lh {} \; | tee -a "$LOG_FILE"
}

# ---------------------------- 后处理 ----------------------------
post_process() {
    local TARGET_ARCH="${TARGET_ARCH:-amd64}"
    local TARGET_VER="${TARGET_VER:-v24.9}"
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local LOG_FILE="${LOG_FILE:-/var/log/catwrt-build/build.log}"
    local DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"

    log INFO "后处理"

    local output_dir="/output/catwrt-${TARGET_ARCH}-${TARGET_VER}-$(date +%Y%m%d)"
    mkdir -p "$output_dir"

    cp -r "$LEDE_DIR/bin/targets"/* "$output_dir/" 2>/dev/null || true
    cp "$LEDE_DIR/.config" "$output_dir/config.build" 2>/dev/null || true
    cp "$LOG_FILE" "$output_dir/" 2>/dev/null || true

    cd "$output_dir"
    find . -type f ! -name "*.sha256" -exec sha256sum {} \; > SHA256SUMS 2>/dev/null || true

    log INFO "输出目录: $output_dir"

    if [[ -n "$DISCORD_WEBHOOK" ]]; then
        local firmware_info=$(find "$output_dir" -name "*.bin" -o -name "*.img" | head -3 | xargs -I{} basename {} | tr '\n' ', ')
        curl -fsSL -X POST -H "Content-Type: application/json" \
            -d "{\"content\":\"✅ CatWrt 编译成功！\n架构: ${TARGET_ARCH}\n版本: ${TARGET_VER}\n固件: ${firmware_info}\"}" \
            "$DISCORD_WEBHOOK" || true
    fi
}

# ---------------------------- 清理 ----------------------------
cleanup() {
    rm -f "$LOCK_FILE"
    log INFO "清理完成"
}

# ---------------------------- 主流程 ----------------------------
main() {
    trap cleanup EXIT

    while [[ $# -gt 0 ]]; do
        case $1 in
            --user=*) NORMAL_USER="${1#*=}" ;;
            --arch=*) TARGET_ARCH="${1#*=}" ;;
            --ver=*) TARGET_VER="${1#*=}" ;;
            --config=*) CONFIG_TYPE="${1#*=}"; USE_PRESET_CONFIG=true ;;
            --auto|-y) AUTO_MODE=true; SKIP_FIRST_BUILD=true ;;
            --jobs=*) MAKE_JOBS="${1#*=}" ;;
            --clean-build) CLEAN_BUILD=true ;;
            --help) 
                echo "用法: sudo $0 --auto --user=NAME --arch=ARCH [--ver=VER] [选项]"
                echo "选项: --config=TYPE  --jobs=N  --clean-build"
                exit 0
                ;;
        esac
        shift
    done

    if [[ "$AUTO_MODE" == true ]]; then
        SKIP_FIRST_BUILD=true
        USE_PRESET_CONFIG=true
    fi

    export NORMAL_USER TARGET_ARCH TARGET_VER
    export CLEAN_BUILD SINGLE_THREAD_FIRST AUTO_RETRY_SINGLE
    export DISCORD_WEBHOOK CATWRT_DOCKER_MODE
    export MAKE_JOBS MAX_RETRIES
    export CONFIG_TYPE AUTO_MODE USE_PRESET_CONFIG SKIP_FIRST_BUILD

    check_env
    install_deps
    setup_repos
    select_config
    apply_custom
    update_feeds
    do_build
    post_process

    log INFO "🎉 全部完成！总耗时: $(ps -o etime= -p $$ | tr -d ' ')"
}

main "$@"
