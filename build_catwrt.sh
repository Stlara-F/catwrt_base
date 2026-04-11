#!/bin/bash
# CatWrt 完全自动化编译脚本 (v2.0 - CI/CD Ready)
# 真正无人值守，零交互，失败自动重试
# 用法: sudo ./build_catwrt_ci.sh --auto --user=miaoer --arch=amd64 --ver=v24.9

set -euo pipefail  # 严格模式：未定义变量报错，管道失败检测

# ---------------------------- 配置参数 ----------------------------
NORMAL_USER="${CATWRT_USER:-$(logname 2>/dev/null || echo "builder")}"
TARGET_ARCH="${CATWRT_ARCH:-"amd64"}"
TARGET_VER="${CATWRT_VER:-"v24.9"}"
SKIP_FIRST_BUILD="${SKIP_FIRST_BUILD:-true}"    # 默认跳过首次编译（CI环境）
USE_PRESET_CONFIG="${USE_PRESET_CONFIG:-true}"  # 默认使用预置配置
CONFIG_TYPE="${CONFIG_TYPE:-}"                  # 空则自动选择
AUTO_MODE="${AUTO_MODE:-false}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
MAX_RETRIES="${MAX_RETRIES:-3}"                 # 网络操作最大重试次数

# 路径
LEDE_DIR="/home/lede"
CATWRT_BASE_DIR="/home/catwrt_base"
LOG_DIR="/var/log/catwrt-build"
LOG_FILE="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/tmp/catwrt-build.lock"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ---------------------------- 核心工具函数 ----------------------------
log() {
    local level="$1"; shift
    local color="$NC"
    case "$level" in
        INFO) color="$GREEN" ;;
        WARN) color="$YELLOW" ;;
        ERROR) color="$RED" ;;
        STEP) color="$BLUE" ;;
    esac
    echo -e "${color}[$level]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

die() {
    log ERROR "$@"
    # 发送失败通知（如果配置了 webhook）
    if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
        curl -fsSL -X POST -H "Content-Type: application/json" \
            -d "{\"content\":\"CatWrt 编译失败: $*\"}" "$DISCORD_WEBHOOK" || true
    fi
    exit 1
}

# 带重试的函数执行
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

# 检查并修复 LEDE 权限（关键：防止 root 污染）
fix_lede_permissions() {
    local owner=$(stat -c '%U' "$LEDE_DIR" 2>/dev/null || echo "root")
    if [[ "$owner" == "root" ]]; then
        log WARN "检测到 LEDE 目录被 root 拥有，修复权限..."
        chown -R "$NORMAL_USER":"$NORMAL_USER" "$LEDE_DIR"
    fi
    # 检查关键目录
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
    
    # 磁盘空间（编译需要 50GB+）
    local avail_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G')
    [[ $avail_gb -gt 50 ]] || die "磁盘空间不足 50GB (当前: ${avail_gb}GB)"
    
    # 内存检查（建议 4GB+）
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    [[ $mem_gb -gt 3 ]] || log WARN "内存不足 4GB，编译可能缓慢或失败"
    
    # 网络检查（带重试）
    retry "curl -fsSL --connect-timeout 10 https://github.com"
    
    # 用户检查
    id "$NORMAL_USER" &>/dev/null || die "用户 $NORMAL_USER 不存在"
    
    # 文件描述符
    ulimit -n 65535 2>/dev/null || log WARN "无法设置 ulimit -n 65535"
    
    # 锁文件（防止重复运行）
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
    log STEP "步骤1: 安装编译依赖"
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    
    # 检测是否已安装主要依赖，避免重复安装
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
    
    # ImmortalWrt 环境脚本（幂等执行）
    if [[ ! -f "/etc/catwrt-env-ready" ]]; then
        log INFO "初始化 ImmortalWrt 编译环境..."
        bash -c 'bash <(curl -fsSL https://build-scripts.immortalwrt.org/init_build_environment.sh)'
        touch /etc/catwrt-env-ready
    fi
    
    # 配置 ccache
    sudo -u "$NORMAL_USER" ccache -M 10G 2>/dev/null || true
    log INFO "依赖安装完成"
}

# ---------------------------- 步骤2：仓库准备 ----------------------------
setup_repos() {
    log STEP "步骤2: 准备代码仓库"
    
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
        sudo -u "$NORMAL_USER" git reset --hard origin/master  # 干净更新
        sudo -u "$NORMAL_USER" git pull
    else
        log INFO "克隆 LEDE 源码..."
        retry "sudo -u $NORMAL_USER git clone https://github.com/coolsnowwolf/lede.git $LEDE_DIR"
        fix_lede_permissions
    fi
}

# ---------------------------- 步骤3：智能配置选择 ----------------------------
select_config() {
    log STEP "步骤3: 选择编译配置"
    
    # 如果用户指定了配置类型
    if [[ -n "$CONFIG_TYPE" ]]; then
        local cfg_file="$CATWRT_BASE_DIR/build/config/${CONFIG_TYPE}.config"
        [[ -f "$cfg_file" ]] || die "指定的配置文件不存在: $cfg_file"
        log INFO "使用指定配置: $CONFIG_TYPE"
        sudo -u "$NORMAL_USER" cp "$cfg_file" "$LEDE_DIR/.config"
        return
    fi
    
    # 自动选择配置
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
            # DIY 架构尝试寻找同名配置
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

# 生成最小配置（保底方案，确保能编译出固件）
_generate_minimal_config() {
    local target_system=""
    local subtarget=""
    
    case "$TARGET_ARCH" in
        amd64) target_system="x86"; subtarget="64" ;;
        mt7621) target_system="MediaTek Ralink MIPS"; subtarget="MT7621" ;;
        mt798x) target_system="MediaTek Ralink ARM"; subtarget="MT798X" ;;
        meson32) target_system="Amlogic Meson"; subtarget="Meson8b" ;;
        meson64) target_system="Amlogic Meson"; subtarget="Mesongxbb" ;;
        rkarm64) target_system="Rockchip"; subtarget="RK33xx" ;;
        *) die "无法为架构 $TARGET_ARCH 生成最小配置，请提供预置配置文件" ;;
    esac
    
    log INFO "生成最小配置: $target_system / $subtarget"
    
    sudo -u "$NORMAL_USER" bash <<EOF
cd "$LEDE_DIR"
cat > .config <<CONFIG
CONFIG_TARGET_${target_system// /_}=y
CONFIG_TARGET_${target_system// /_}_${subtarget}=y
CONFIG_TARGET_${target_system// /_}_${subtarget}_DEVICE_generic=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
CONFIG_PACKAGE_default-settings=y
CONFIG_PACKAGE_default-settings-chn=y
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="CatWrt"
CONFIG_VERSION_NUMBER="$TARGET_VER"
CONFIG_VERSION_CODE="$(date +%Y%m%d)"
CONFIG
make defconfig
EOF
}

# ---------------------------- 步骤4：应用 CatWrt 定制 ----------------------------
apply_custom() {
    log STEP "步骤4: 应用 CatWrt 定制"
    
    # 执行 pull.sh 更新插件（带重试）
    cd "$CATWRT_BASE_DIR"
    retry "bash $CATWRT_BASE_DIR/pull.sh"
    
    # 直接复制文件（绕过交互式 main.sh）
    log INFO "释放 CatWrt 模板文件..."
    local source_dir=""
    
    if [[ "$TARGET_ARCH" == diy/* ]]; then
        source_dir="$CATWRT_BASE_DIR/$TARGET_ARCH"
    else
        source_dir="$CATWRT_BASE_DIR/$TARGET_ARCH/$TARGET_VER"
    fi
    
    [[ -d "$source_dir" ]] || die "配置目录不存在: $source_dir"
    
    # 基础文件复制
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
        
        # mtwifi 特殊处理
        if [[ "$TARGET_ARCH" == "mt7621" && -f "$base_files/etc/init.d/mtwifi" ]]; then
            cp -v "$base_files/etc/init.d/mtwifi" "$LEDE_DIR/package/base-files/files/etc/init.d/"
            chmod +x "$LEDE_DIR/package/base-files/files/etc/init.d/mtwifi"
        elif [[ "$TARGET_ARCH" != "mt7621" ]]; then
            rm -f "$LEDE_DIR/package/base-files/files/etc/init.d/mtwifi" 2>/dev/null || true
        fi
        
        # mt798x 特有工具
        if [[ "$TARGET_ARCH" == "mt798x" && -d "$base_files/usr/bin" ]]; then
            mkdir -p "$LEDE_DIR/package/base-files/files/usr/bin"
            cp -v "$base_files/usr/bin/"* "$LEDE_DIR/package/base-files/files/usr/bin/" 2>/dev/null || true
            chmod +x "$LEDE_DIR/package/base-files/files/usr/bin/"* 2>/dev/null || true
        fi
    fi
    
    # lean 默认设置
    if [[ -d "$source_dir/lean/default-settings/files" ]]; then
        cp -v "$source_dir/lean/default-settings/files/zzz-default-settings" \
            "$LEDE_DIR/package/lean/default-settings/files/"
        chmod +x "$LEDE_DIR/package/lean/default-settings/files/zzz-default-settings"
    fi
    
    # cattools
    mkdir -p "$LEDE_DIR/package/base-files/files/usr/bin"
    retry "curl -fsSL https://raw.miaoer.net/cattools/cattools.sh -o $LEDE_DIR/package/base-files/files/usr/bin/cattools"
    chmod +x "$LEDE_DIR/package/base-files/files/usr/bin/cattools"
    chmod +x "$LEDE_DIR/package/base-files/files/bin/config_generate"
    
    # 关键：修复权限
    fix_lede_permissions
    log INFO "CatWrt 定制应用完成"
}

# ---------------------------- 步骤5：Feeds 更新 ----------------------------
update_feeds() {
    log STEP "步骤5: 更新 Feeds"
    
    cd "$LEDE_DIR"
    
    # 清理旧的 feeds 缓存（避免冲突）
    sudo -u "$NORMAL_USER" rm -rf tmp/.packageinfo 2>/dev/null || true
    
    sudo -u "$NORMAL_USER" bash <<EOF
./scripts/feeds clean
./scripts/feeds update -a
./scripts/feeds install -a
EOF
    
    # 应用配置
    sudo -u "$NORMAL_USER" bash -c "cd '$LEDE_DIR' && make defconfig"
    
    # 下载依赖（带重试）
    log INFO "下载编译依赖包..."
    retry "sudo -u $NORMAL_USER bash -c 'cd $LEDE_DIR && make download -j${MAKE_JOBS}'"
}

# ---------------------------- 步骤6：编译 ----------------------------
do_build() {
    log STEP "步骤6: 开始编译"
    log INFO "使用 $MAKE_JOBS 个并行任务，日志: $LOG_FILE"
    
    cd "$LEDE_DIR"
    
    # 预编译检查
    if [[ ! -f ".config" ]]; then
        die "缺少 .config 文件，无法编译"
    fi
    
    # 清理旧的构建（可选，用于干净构建）
    if [[ "${CLEAN_BUILD:-false}" == "true" ]]; then
        log INFO "执行 make clean..."
        sudo -u "$NORMAL_USER" make clean
    fi
    
    # 编译（单线程首次，失败后自动重试多线程 - 用于调试）
    local build_cmd="make V=s -j${MAKE_JOBS}"
    [[ "${SINGLE_THREAD_FIRST:-false}" == "true" ]] && build_cmd="make V=s -j1"
    
    set +e
    sudo -u "$NORMAL_USER" bash -c "cd '$LEDE_DIR' && $build_cmd" 2>&1 | tee -a "$LOG_FILE"
    local ret=$?
    set -e
    
    # 如果多线程失败且不是单线程模式，尝试单线程重试
    if [[ $ret -ne 0 && "$SINGLE_THREAD_FIRST" != "true" && "${AUTO_RETRY_SINGLE:-true}" == "true" ]]; then
        log WARN "多线程编译失败，尝试单线程重试..."
        set +e
        sudo -u "$NORMAL_USER" bash -c "cd '$LEDE_DIR' && make V=s -j1" 2>&1 | tee -a "$LOG_FILE"
        ret=$?
        set -e
    fi
    
    [[ $ret -eq 0 ]] || die "编译失败 (退出码: $ret)"
    
    # 验证输出
    local bin_dir="$LEDE_DIR/bin/targets"
    [[ -d "$bin_dir" ]] || die "编译成功但未找到输出目录"
    
    local firmware_count=$(find "$bin_dir" -type f \( -name "*.bin" -o -name "*.img" -o -name "*.gz" \) | wc -l)
    [[ $firmware_count -gt 0 ]] || die "编译完成但未生成固件文件"
    
    log INFO "编译成功！生成 $firmware_count 个固件文件"
    find "$bin_dir" -type f -exec ls -lh {} \; | tee -a "$LOG_FILE"
}

# ---------------------------- 后处理 ----------------------------
post_process() {
    log STEP "后处理"
    
    # 收集编译产物
    local output_dir="/output/catwrt-${TARGET_ARCH}-${TARGET_VER}-$(date +%Y%m%d)"
    mkdir -p "$output_dir"
    
    # 复制固件和配置
    cp -r "$LEDE_DIR/bin/targets"/* "$output_dir/" 2>/dev/null || true
    cp "$LEDE_DIR/.config" "$output_dir/config.build" 2>/dev/null || true
    cp "$LOG_FILE" "$output_dir/" 2>/dev/null || true
    
    # 生成校验和
    cd "$output_dir"
    find . -type f ! -name "*.sha256" -exec sha256sum {} \; > SHA256SUMS 2>/dev/null || true
    
    log INFO "输出目录: $output_dir"
    
    # 发送成功通知
    if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
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
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --user=*) NORMAL_USER="${1#*=}" ;;
            --arch=*) TARGET_ARCH="${1#*=}" ;;
            --ver=*) TARGET_VER="${1#*=}" ;;
            --config=*) CONFIG_TYPE="${1#*=}"; USE_PRESET_CONFIG=true ;;
            --auto|-y) AUTO_MODE=true; SKIP_FIRST_BUILD=true ;;
            --jobs=*) MAKE_JOBS="${1#*=}" ;;
            --clean-build) export CLEAN_BUILD=true ;;
            --help) 
                echo "用法: sudo $0 --auto --user=NAME --arch=ARCH [--ver=VER] [选项]"
                echo "选项: --config=TYPE  --jobs=N  --clean-build"
                exit 0
                ;;
        esac
        shift
    done
    
    # 自动模式强制设置
    if [[ "$AUTO_MODE" == true ]]; then
        export SKIP_FIRST_BUILD=true
        export USE_PRESET_CONFIG=true
    fi
    
    check_env
    install_deps
    setup_repos
    select_config      # 必须在 apply_custom 之前，确定目标平台
    apply_custom       # 注入 CatWrt 文件
    update_feeds       # 更新 feeds 并下载
    do_build           # 编译
    post_process       # 收集产物
    
    log INFO "🎉 全部完成！总耗时: $(ps -o etime= -p $$ | tr -d ' ')"
}

main "$@"
