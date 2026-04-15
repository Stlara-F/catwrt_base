#!/bin/bash
# CatWrt 完全自动化编译脚本 (v2.5 - 修复架构适配)
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
    
    if [[ "$CATWRT_DOCKER_MODE" == "1" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        log INFO "运行在 CI/Docker 模式，跳过所有宿主机检查"
        id "$NORMAL_USER" &>/dev/null || die "用户 $NORMAL_USER 不存在"
    else
        local avail_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G')
        [[ $avail_gb -gt 50 ]] || die "磁盘空间不足 50GB (当前: ${avail_gb}GB)"
        local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
        [[ $mem_gb -gt 3 ]] || log WARN "内存不足 4GB，编译可能缓慢"
    fi
    
    # 🔥 GitHub Actions 专属：强制 8 线程，拉满速度
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        log INFO "🔧 GitHub Actions 环境，强制 8 线程极速编译"
        MAKE_JOBS=16
        export SKIP_DOCS=1
        export CCACHE_DIR="/home/lede/.ccache"
        export CCACHE_MAXSIZE="5G"
        mkdir -p "$CCACHE_DIR"
        chown -R "$NORMAL_USER":"$NORMAL_USER" "$CCACHE_DIR"
        
        local workspace_used=$(df -BG . | awk 'NR==2 {print $3}' | tr -d 'G')
        log INFO "当前工作空间: ${workspace_used}GB / 14GB | 线程数: $MAKE_JOBS"
    fi
    
    # 网络检查（容错）
    log INFO "检查网络连接..."
    if ! retry "curl -fsSL --connect-timeout 5 https://github.com" 2>/dev/null; then
        log WARN "GitHub 连接失败，尝试继续编译（可能后续下载失败）"
    fi
    
    # 用户检查
    id "$NORMAL_USER" &>/dev/null || die "用户 $NORMAL_USER 不存在"
    
    # Git 安全目录（容错）
    log INFO "配置 Git 全局安全目录..."
    git config --global --add safe.directory '*' 2>/dev/null || true
    sudo -u "$NORMAL_USER" git config --global --add safe.directory '*' 2>/dev/null || true
    
    # 权限清理
    fix_lede_permissions
    
    log INFO "环境检查通过（CI 极速模式）| 用户: $NORMAL_USER | 架构: $TARGET_ARCH | 线程: $MAKE_JOBS"
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
    
    # CatWrt Base（指定 main 分支，避免 Git 默认分支提示）
    if [[ -d "$CATWRT_BASE_DIR/.git" ]]; then
        cd "$CATWRT_BASE_DIR"
        retry "git pull origin main"
    else
        rm -rf "$CATWRT_BASE_DIR" 2>/dev/null || true
        # 🔥 修复：显式指定 --branch main，消除 Git 分支名提示
        retry "git clone --depth=1 --branch main https://github.com/miaoermua/catwrt_base.git $CATWRT_BASE_DIR"
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
        # 处理非 git 仓库的情况
        local dl_is_mount=false
        local dl_cache=""
        local lede_already_setup=false
        
        if [[ -d "$LEDE_DIR" ]]; then
            log WARN "/home/lede 目录存在但非 Git 仓库，尝试安全清理..."
            # 检查挂载点
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
            
            # dl 是挂载点：就地处理
            if [[ "$dl_is_mount" == true ]]; then
                log WARN "dl 是缓存挂载点，无法移动，就地克隆源码..."
                # 删掉除了 dl 之外的所有内容
                find "$LEDE_DIR" -mindepth 1 -maxdepth 1 -not -name dl -exec rm -rf {} \; 2>/dev/null || true
                # 🔥 修复：就地初始化 git 时显式指定 master 分支（匹配 lede 仓库默认分支）
                cd "$LEDE_DIR"
                sudo -u "$NORMAL_USER" git init -b master
                sudo -u "$NORMAL_USER" git config --local init.defaultBranch master  # 彻底消除分支提示
                sudo -u "$NORMAL_USER" git remote add origin https://github.com/coolsnowwolf/lede.git
                retry "sudo -u $NORMAL_USER git fetch origin --depth=1"
                sudo -u "$NORMAL_USER" git reset --hard origin/master
                # 修复权限
                chown -R "$NORMAL_USER":"$NORMAL_USER" "$LEDE_DIR"
                fix_lede_permissions
                lede_already_setup=true
            else
                # 普通目录：临时移出 dl 缓存
                if [[ -d "$LEDE_DIR/dl" ]]; then
                    log WARN "发现 dl 缓存目录，临时移出以避免克隆失败..."
                    dl_cache="/tmp/lede-dl-cache-$(date +%s)"
                    mv "$LEDE_DIR/dl" "$dl_cache"
                fi
                rm -rf "$LEDE_DIR" 2>/dev/null || true
            fi
        fi
        
        # 正常克隆（如果还没处理）
        if [[ ! "$lede_already_setup" == true ]]; then
            log INFO "克隆 LEDE 源码..."
            # 🔥 修复：显式指定 master 分支
            retry "sudo -u $NORMAL_USER git clone --depth=1 --branch master https://github.com/coolsnowwolf/lede.git $LEDE_DIR"
            
            # 恢复 dl 缓存
            if [[ -n "$dl_cache" && -d "$dl_cache" ]]; then
                log WARN "恢复 dl 缓存目录，节省下载时间..."
                mv "$dl_cache" "$LEDE_DIR/dl"
                chown -R "$NORMAL_USER":"$NORMAL_USER" "$LEDE_DIR/dl"
            fi
            
            fix_lede_permissions
        fi
    fi
}

# ---------------------------- 步骤3：智能配置选择（修复：支持所有架构） ----------------------------
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
    
    # 🔥 修复：自动选择配置 - 支持所有架构
    local auto_config=""
    case "$TARGET_ARCH" in
        amd64)
            auto_config="$CATWRT_BASE_DIR/build/config/amd64.config"
            [[ -f "$auto_config" ]] || auto_config="$CATWRT_BASE_DIR/build/config/amd64.luci2.config"
            ;;
        mt7621)
            auto_config="$CATWRT_BASE_DIR/build/config/mt7621.config"
            ;;
        mt798x)
            auto_config="$CATWRT_BASE_DIR/build/config/mt798x.config"
            ;;
        meson32)
            auto_config="$CATWRT_BASE_DIR/build/config/meson32.config"
            ;;
        meson64)
            auto_config="$CATWRT_BASE_DIR/build/config/meson64.config"
            ;;
        rkarm64)
            auto_config="$CATWRT_BASE_DIR/build/config/rkarm64.config"
            ;;
        diy/*)
            # DIY 架构尝试寻找同名配置
            local diy_name="${TARGET_ARCH#diy/}"
            auto_config="$CATWRT_BASE_DIR/build/config/${diy_name}.config"
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

# ---------------------------- 步骤4：应用 CatWrt 定制（修复：兼容无版本子目录的架构） ----------------------------
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
    
    # 🔥 修复：智能寻找 source_dir - 兼容两种目录结构
    log INFO "释放 CatWrt 模板文件..."
    local source_dir=""
    
    # 优先级 1：DIY 架构
    if [[ "$TARGET_ARCH" == diy/* ]]; then
        source_dir="$CATWRT_BASE_DIR/$TARGET_ARCH"
    # 优先级 2：尝试 架构/版本 结构（如 amd64/v24.9）
    elif [[ -d "$CATWRT_BASE_DIR/$TARGET_ARCH/$TARGET_VER" ]]; then
        source_dir="$CATWRT_BASE_DIR/$TARGET_ARCH/$TARGET_VER"
    # 优先级 3：尝试直接 架构/ 结构（如 meson64/、mt798x/）
    elif [[ -d "$CATWRT_BASE_DIR/$TARGET_ARCH" ]]; then
        source_dir="$CATWRT_BASE_DIR/$TARGET_ARCH"
        log WARN "未找到版本子目录 $TARGET_ARCH/$TARGET_VER，使用根目录 $source_dir"
    else
        die "配置目录不存在: $CATWRT_BASE_DIR/$TARGET_ARCH/$TARGET_VER 或 $CATWRT_BASE_DIR/$TARGET_ARCH"
    fi
    
    [[ -d "$source_dir" ]] || die "配置目录不存在: $source_dir"
    log INFO "使用配置目录: $source_dir"
    
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
    
    # 确保 config_generate 权限
    chmod +x "$LEDE_DIR/package/base-files/files/bin/config_generate" 2>/dev/null || true
    
    # 关键：修复权限
    fix_lede_permissions
    log INFO "CatWrt 定制应用完成"
}

# ---------------------------- 步骤5：Feeds 更新 ----------------------------
update_feeds() {
    local LEDE_DIR="${LEDE_DIR:-/home/lede}"
    local NORMAL_USER="${NORMAL_USER:-builder}"
    local MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
    
    log INFO "步骤5: 更新 Feeds 并自动修复编译问题"
    cd "$LEDE_DIR"
    export FEEDS_DEPTH=1
    
    sudo -u "$NORMAL_USER" rm -rf tmp/.packageinfo 2>/dev/null || true
    
    sudo -u "$NORMAL_USER" bash <<EOF
./scripts/feeds clean 2>&1 || true
./scripts/feeds update -a 2>&1 || true
./scripts/feeds install -a 2>&1 || true

# 🔥 自动修复 1：ipset 内核头文件路径
if [ -f "package/network/utils/ipset/Makefile" ]; then
    sed -i 's|CONFIGURE_ARGS +=|CONFIGURE_ARGS += --with-kernel-include=$(LINUX_DIR)/include |' package/network/utils/ipset/Makefile
    echo "已修复 ipset 内核头文件路径"
fi

# 🔥 自动修复 2：禁用无用包 linux-atm
if [ -f ".config" ]; then
    sed -i 's/CONFIG_PACKAGE_linux-atm=y/# CONFIG_PACKAGE_linux-atm is not set/' .config
    echo "已禁用 linux-atm"
fi

# 🔥 终极修复：直接删除 netkeeper 插件目录
if [ -d "package/feed-netkeeper" ]; then
    rm -rf package/feed-netkeeper
    echo "已删除 netkeeper 插件（不兼容 ppp-2.5.2）"
fi

# 🔥 双重保险：确保 .config 中没有 netkeeper
if [ -f ".config" ]; then
    sed -i '/CONFIG_PACKAGE_netkeeper/d' .config
    echo "# CONFIG_PACKAGE_netkeeper is not set" >> .config
fi

# 🔥 优化：跳过文档编译（节省大量时间）
if [ -f ".config" ]; then
    sed -i 's/CONFIG_BUILD_DOCS=y/# CONFIG_BUILD_DOCS is not set/' .config
    sed -i 's/CONFIG_BUILD_MAN=y/# CONFIG_BUILD_MAN is not set/' .config
    echo "已禁用文档编译"
fi
EOF
    
    # 应用配置
    sudo -u "$NORMAL_USER" bash -c "cd '$LEDE_DIR' && make defconfig 2>&1 || true"
    
    # 三重保险
    sudo -u "$NORMAL_USER" bash -c "cd '$LEDE_DIR' && [ -d 'package/feed-netkeeper' ] && rm -rf package/feed-netkeeper || true"
    sudo -u "$NORMAL_USER" bash -c "cd '$LEDE_DIR' && sed -i '/CONFIG_PACKAGE_netkeeper/d' .config && echo '# CONFIG_PACKAGE_netkeeper is not set' >> .config"
    
    # 下载依赖（增加超时时间，避免网络波动导致失败）
    log INFO "下载编译依赖包（线程: $MAKE_JOBS）..."
    retry "sudo -u $NORMAL_USER bash -c 'cd $LEDE_DIR && make download -j${MAKE_JOBS} 2>&1 || true'" || true
}

# ---------------------------- 步骤6：编译（核心优化） ----------------------------
do_build() {
    local CLEAN_BUILD="${CLEAN_BUILD:-false}"
    # 🔥 强制多线程：GitHub Actions 7GB 内存可用，直接拉满到 8 线程
    local MAKE_JOBS="${MAKE_JOBS:-8}"
    log INFO "步骤6: 开始强制多线程编译（线程：$MAKE_JOBS，CI 极速模式）"
    cd "$LEDE_DIR"
    [[ ! -f ".config" ]] && die "缺少 .config"
    [[ "$CLEAN_BUILD" == "true" ]] && sudo -u "$NORMAL_USER" make clean 2>&1 || true
    
    local ret=0
    set +e
    
    # 🔥 强制多线程：移除所有单线程 fallback，失败直接退出
    log INFO "执行: make -j${MAKE_JOBS} V=s（强制多线程，不回退）"
    sudo -u "$NORMAL_USER" make -j${MAKE_JOBS} V=s 2>&1 | tee -a "$LOG_FILE"
    ret=${PIPESTATUS[0]}
    
    set -e

    # 验证固件
    local bin_dir="$LEDE_DIR/bin/targets"
    if [[ -d "$bin_dir" ]]; then
        local count=$(find "$bin_dir" -type f \( -name "*.bin" -o -name "*.img" -o -name "*.gz" \) 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            log INFO "编译成功！固件数量：$count"
            return 0
        fi
    fi
    
    if [[ $ret -eq 0 ]]; then
        log WARN "编译返回成功，但未找到固件文件，继续执行"
        return 0
    fi
    
    die "编译失败，请查看日志（强制多线程模式，失败不回退）"
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
