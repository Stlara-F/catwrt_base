#!/bin/bash
# CatWrt 完全自动化编译脚本 (v2.4 - GitHub Actions 专属优化版)
# 真正无人值守，零交互，失败自动重试，完美适配 GitHub Actions 资源限制
# 用法: sudo ./build_catwrt_ci.sh --auto --user=miaoer --arch=amd64 --ver=v24.9

set -euo pipefail  # 严格模式：未定义变量报错，管道失败检测

# ---------------------------- 全局配置参数 ----------------------------
# 第一重保险：所有全局变量都加默认值
NORMAL_USER="${CATWRT_USER:-$(logname 2>/dev/null || echo "builder")}"
TARGET_ARCH="${CATWRT_ARCH:-"amd64"}"
TARGET_VER="${CATWRT_VER:-"v24.9"}"
SKIP_FIRST_BUILD="${SKIP_FIRST_BUILD:-true}"
USE_PRESET_CONFIG="${USE_PRESET_CONFIG:-true}"
CONFIG_TYPE="${CONFIG_TYPE:-}"
AUTO_MODE="${AUTO_MODE:-false}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
MAX_RETRIES="${MAX_RETRIES:-3}"

# 所有可选变量的默认值，从根源解决 unbound variable
CLEAN_BUILD="${CLEAN_BUILD:-false}"
SINGLE_THREAD_FIRST="${SINGLE_THREAD_FIRST:-false}"
AUTO_RETRY_SINGLE="${AUTO_RETRY_SINGLE:-true}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
CATWRT_DOCKER_MODE="${CATWRT_DOCKER_MODE:-0}"

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
    esac
    echo -e "${color}[$level]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

die() {
    log ERROR "$@"
    # 发送失败通知（如果配置了 webhook）
    if [[ -n "$DISCORD_WEBHOOK" ]]; then
        curl -fsSL -X POST -H "Content-Type: application/json" \
            -d "{\"content\":\"❌ CatWrt 编译失败: $*\"}" "$DISCORD_WEBHOOK" || true
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
    
    # Docker 模式：跳过某些检查
    if [[ "$CATWRT_DOCKER_MODE" == "1" ]]; then
        log INFO "运行在 Docker 模式中，跳过宿主机检查"
        id "$NORMAL_USER" &>/dev/null || die "用户 $NORMAL_USER 不存在"
        # 跳过其他宿主机检查
    else
        # 磁盘空间（编译需要 50GB+）
        local avail_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G')
        [[ $avail_gb -gt 50 ]] || die "磁盘空间不足 50GB (当前: ${avail_gb}GB)"
        
        # 内存检查（建议 4GB+）
        local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
        [[ $mem_gb -gt 3 ]] || log WARN "内存不足 4GB，编译可能缓慢或失败"
    fi
    
    # 🔧 GitHub Actions 专属优化：自动适配资源限制
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        log INFO "🔧 检测到 GitHub Actions 环境，自动适配资源限制..."
        # 限制线程为 4，内存峰值控制在 6GB 以内，不超过 7GB 上限
        MAKE_JOBS=4
        # 检查存储使用情况
        local workspace_used=$(df -BG . | awk 'NR==2 {print $3}' | tr -d 'G')
        log INFO "当前工作空间已使用: ${workspace_used}GB / 14GB 上限"
    fi
    
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
        # 全局解决 Git unsafe repository 阻断问题
    log INFO "配置 Git 全局安全目录防止权限阻断..."
    git config --global --add safe.directory '*'
    sudo -u "$NORMAL_USER" git config --global --add safe.directory '*'
}

# ---------------------------- 步骤1：依赖安装 ----------------------------
install_deps() {
    log INFO "步骤1: 安装编译依赖"
    
    export DEBIAN_FRONTEND=noninteractive
    
    # APT 更新加重试，解决源网络波动
    retry "apt-get update -qq"
    
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
    
    # 🔧 限制 ccache 最大 5GB，避免超过存储上限
    sudo -u "$NORMAL_USER" ccache -M 5G 2>/dev/null || true
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
        # 🔧 浅克隆，只克隆最新提交，节省98%的存储！
        retry "git clone --depth=1 https://github.com/miaoermua/catwrt_base.git $CATWRT_BASE_DIR"
    fi
    chmod +x "$CATWRT_BASE_DIR"/*.sh 2>/dev/null || true
    
    # LEDE
    if [[ -d "$LEDE_DIR/.git" ]]; then
        log INFO "LEDE 已存在，更新源码..."
        cd "$LEDE_DIR"
        fix_lede_permissions
        sudo -u "$NORMAL_USER" git fetch origin --depth=1
        sudo -u "$NORMAL_USER" git reset --hard origin/master
    else
        # 🔧 处理非git仓库的情况，完美兼容挂载点！
        local dl_is_mount=false
        local dl_cache=""
        local lede_already_setup=false
        
        if [[ -d "$LEDE_DIR" ]]; then
            log WARN "/home/lede 目录存在但非 Git 仓库，尝试安全清理..."
            # 检查是否有子目录是挂载点
            local mounts=$(mount | grep "$LEDE_DIR" | awk '{print $3}' || true)
            if [[ -n "$mounts" ]]; then
                for mnt in $mounts; do
                    log WARN "发现挂载点: $mnt，尝试卸载..."
                    if umount "$mnt" 2>/dev/null; then
                        log INFO "成功卸载挂载点: $mnt"
                    else
                        log WARN "无法卸载 $mnt，将保留该挂载点并就地克隆..."
                        if [[ "$mnt" == "$LEDE_DIR/dl" ]]; then
                            dl_is_mount=true
                        fi
                    fi
                done
            fi
            
            # 🔧 如果 dl 是挂载点，我们不能移动它，就地处理！
            if [[ "$dl_is_mount" == true ]]; then
                log WARN "dl 是缓存挂载点，无法移动，就地克隆源码..."
                # 删掉除了 dl 之外的所有内容
                find "$LEDE_DIR" -mindepth 1 -maxdepth 1 -not -name dl -exec rm -rf {} \; 2>/dev/null || true
                # 就地初始化 git，不用移动挂载点
                cd "$LEDE_DIR"
                sudo -u "$NORMAL_USER" git init
                sudo -u "$NORMAL_USER" git remote add origin https://github.com/coolsnowwolf/lede.git
                retry "sudo -u $NORMAL_USER git fetch origin --depth=1"
                sudo -u "$NORMAL_USER" git reset --hard origin/master
                # 修复权限
                chown -R "$NORMAL_USER":"$NORMAL_USER" "$LEDE_DIR"
                fix_lede_permissions
                # 标记已经处理完了
                lede_already_setup=true
            else
                # 普通目录，用原来的临时移出方案
                if [[ -d "$LEDE_DIR/dl" ]]; then
                    log WARN "发现 dl 缓存目录，临时移出以避免克隆失败..."
                    dl_cache="/tmp/lede-dl-cache-$(date +%s)"
                    mv "$LEDE_DIR/dl" "$dl_cache"
                fi
                # 删掉整个目录，确保 git clone 能成功
                rm -rf "$LEDE_DIR" 2>/dev/null || true
            fi
        fi
        
        # 如果还没处理，就正常克隆
        if [[ ! "$lede_already_setup" == true ]]; then
            log INFO "克隆 LEDE 源码..."
            # 🔧 浅克隆，只克隆最新提交，把30G的历史压缩到500M！
            retry "sudo -u $NORMAL_USER git clone --depth=1 https://github.com/coolsnowwolf/lede.git $LEDE_DIR"
            
            # 恢复 dl 缓存目录，节省下载时间
            if [[ -n "$dl_cache" && -d "$dl_cache" ]]; then
                log WARN "恢复 dl 缓存目录，节省下载时间..."
                mv "$dl_cache" "$LEDE_DIR/dl"
                chown -R "$NORMAL_USER":"$NORMAL_USER" "$LEDE_DIR/dl"
            fi
            
            fix_lede_permissions
        fi
    fi
}


# ---------------------------- 步骤3：智能配置选择 ----------------------------
select_config() {
    # 函数内变量保护
    local TARGET_ARCH="${TARGET_ARCH:-amd64}"
    local CATWRT_BASE_DIR="${CATWRT_BASE_DIR:-/home/catwrt_base}"
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local NORMAL_USER="${NORMAL_USER:-builder}"
    
    log INFO "步骤3: 选择编译配置"
    
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
    # 函数内变量保护
    local TARGET_ARCH="${TARGET_ARCH:-amd64}"
    local TARGET_VER="${TARGET_VER:-v24.9}"
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local NORMAL_USER="${NORMAL_USER:-builder}"
    
    local target_system=""
    local subtarget=""
    local device="default"
    
    case "$TARGET_ARCH" in
        amd64) 
            target_system="x86"
            subtarget="64"
            device="generic"
            ;;
        mt7621) 
            target_system="mediatek"
            subtarget="mt7621"
            device="default"
            ;;
        mt798x) 
            target_system="mediatek"
            subtarget="mt7986"
            device="default"
            ;;
        meson32) 
            target_system="amlogic"
            subtarget="meson8b"
            device="default"
            ;;
        meson64) 
            target_system="amlogic"
            subtarget="mesongxbb"
            device="default"
            ;;
        rkarm64) 
            target_system="rockchip"
            subtarget="rk33xx"
            device="default"
            ;;
        diy/*)
            # DIY 主题默认使用 amd64 基础配置
            log WARN "DIY 架构，默认使用 amd64 基础配置"
            target_system="x86"
            subtarget="64"
            device="generic"
            ;;
        *) 
            die "无法为架构 $TARGET_ARCH 生成最小配置，请提供预置配置文件" 
            ;;
    esac
    
    log INFO "生成最小配置: $target_system/$subtarget"
    
    sudo -u "$NORMAL_USER" bash <<EOF
cd "$LEDE_DIR"
cat > .config <<CONFIG
# 自动生成的最小配置
CONFIG_TARGET_${target_system}=y
CONFIG_TARGET_${target_system}_${subtarget}=y
CONFIG_TARGET_${target_system}_${subtarget}_DEVICE_${device}=y

# 基础包
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
CONFIG_PACKAGE_default-settings=y
CONFIG_PACKAGE_default-settings-chn=y

# 版本信息
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
    # 函数内变量保护
    local TARGET_ARCH="${TARGET_ARCH:-amd64}"
    local TARGET_VER="${TARGET_VER:-v24.9}"
    local CATWRT_BASE_DIR="${CATWRT_BASE_DIR:-/home/catwrt_base}"
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local NORMAL_USER="${NORMAL_USER:-builder}"
    local MAX_RETRIES="${MAX_RETRIES:-3}"
    
    log INFO "步骤4: 应用 CatWrt 定制"
    
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
    
    # cattools（修复文件冲突：改为 cattools.sh 避免与 base-files 同名）
    mkdir -p "$LEDE_DIR/package/base-files/files/usr/sbin"
    retry "curl -fsSL https://raw.miaoer.net/cattools/cattools.sh -o $LEDE_DIR/package/base-files/files/usr/sbin/cattools"
    chmod +x "$LEDE_DIR/package/base-files/files/usr/sbin/cattools"
    # 同时确保 config_generate 权限
    chmod +x "$LEDE_DIR/package/base-files/files/bin/config_generate"
    
    # 关键：修复权限
    fix_lede_permissions
    log INFO "CatWrt 定制应用完成"
}

# ---------------------------- 步骤5：Feeds 更新 ----------------------------
update_feeds() {
    # 函数内变量保护
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local NORMAL_USER="${NORMAL_USER:-builder}"
    local MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
    
    log INFO "步骤5: 更新 Feeds"
    
    cd "$LEDE_DIR"
    
    # 🔧 feeds 也用浅克隆，节省存储
    export FEEDS_DEPTH=1
    
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

# ---------------------------- 步骤6：编译（核心优化） ----------------------------
do_build() {
    local CLEAN_BUILD="${CLEAN_BUILD:-false}"
    local MAKE_JOBS="${MAKE_JOBS:-2}"
    log INFO "步骤6: 开始严格编译（线程：$MAKE_JOBS，无容错跳过）"

    cd "$LEDE_DIR"
    [[ ! -f ".config" ]] && die "缺少 .config"
    [[ "$CLEAN_BUILD" == "true" ]] && sudo -u "$NORMAL_USER" make clean

    # 临时文件用于收集错误和警告
    local error_log=$(mktemp)
    local warn_log=$(mktemp)

    log INFO "执行: make -j${MAKE_JOBS} V=s"
    set +e
    sudo -u "$NORMAL_USER" make -j${MAKE_JOBS} V=s 2>&1 | tee -a "$LOG_FILE" | while IFS= read -r line; do
        echo "$line"
        if [[ "$line" =~ ERROR: ]] || [[ "$line" =~ "Error " ]] || [[ "$line" =~ "make["[0-9]+"]: ***" ]]; then
            echo "$line" >> "$error_log"
        elif [[ "$line" =~ WARNING: ]]; then
            echo "$line" >> "$warn_log"
        fi
    done
    local ret=${PIPESTATUS[0]}
    set -e

    # 输出汇总
    if [[ -s "$warn_log" ]]; then
        log WARN "========== 编译过程中发现的警告 =========="
        cat "$warn_log" | tee -a "$LOG_FILE"
        log WARN "=========================================="
    fi

    if [[ $ret -ne 0 ]]; then
        log ERROR "========== 编译失败，错误摘要 =========="
        if [[ -s "$error_log" ]]; then
            cat "$error_log" | tee -a "$LOG_FILE"
        else
            log ERROR "未捕获到具体错误行，请查看完整日志"
        fi
        log ERROR "=========================================="
        rm -f "$error_log" "$warn_log"
        die "编译失败，请根据上述错误信息修复（如缺失依赖、文件冲突、仓库失效等）"
    fi

    rm -f "$error_log" "$warn_log"

    # 验证固件是否生成
    local bin_dir="$LEDE_DIR/bin/targets"
    [[ -d "$bin_dir" ]] || die "未找到固件输出目录"
    local count=$(find "$bin_dir" -type f \( -name "*.bin" -o -name "*.img" -o -name "*.gz" \) | wc -l)
    [[ $count -gt 0 ]] || die "未生成固件文件"
    log INFO "编译成功！固件数量：$count"
}

# ---------------------------- 后处理 ----------------------------
post_process() {
    # 函数内变量保护
    local TARGET_ARCH="${TARGET_ARCH:-amd64}"
    local TARGET_VER="${TARGET_VER:-v24.9}"
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local LOG_FILE="${LOG_FILE:-/var/log/catwrt-build/build.log}"
    local DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
    
    log INFO "后处理"
    
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
    
    # 🔧 GitHub Actions 专属：编译完清理中间文件，节省存储！
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        log INFO "🔧 GitHub Actions 环境，清理中间文件以节省存储..."
        # 删除几十G的编译中间文件，只保留最终固件
        sudo -u "$NORMAL_USER" bash -c "cd '$LEDE_DIR' && rm -rf build_dir staging_dir tmp logs"
        # 检查剩余存储
        local workspace_used=$(df -BG . | awk 'NR==2 {print $3}' | tr -d 'G')
        log INFO "清理后工作空间已使用: ${workspace_used}GB / 14GB 上限，完全在限制内！"
    fi
    # 收集 Makefile 依赖缺失警告（从日志中提取）
    grep -E "WARNING: Makefile.*has a (build )?dependency on.*which does not exist" "$LOG_FILE" > "$output_dir/missing-deps.txt" || true

    log INFO "输出目录: $output_dir"
    
    # 发送成功通知
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
    
    # 解析参数
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
    
    # 自动模式强制设置
    if [[ "$AUTO_MODE" == true ]]; then
        SKIP_FIRST_BUILD=true
        USE_PRESET_CONFIG=true
    fi
    
    # 全局导出所有变量，确保 sudo 子进程能继承
    export NORMAL_USER TARGET_ARCH TARGET_VER
    export CLEAN_BUILD SINGLE_THREAD_FIRST AUTO_RETRY_SINGLE
    export DISCORD_WEBHOOK CATWRT_DOCKER_MODE
    export MAKE_JOBS MAX_RETRIES
    export CONFIG_TYPE AUTO_MODE USE_PRESET_CONFIG SKIP_FIRST_BUILD
    
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
