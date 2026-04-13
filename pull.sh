#!/bin/bash
# CatWrt 插件拉取脚本 (增强容错版)
# 支持重试、预检、备用源、稀疏克隆，确保单个仓库失效不影响整体流程

set -euo pipefail

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# 全局变量
USER_HOME="/home"
TARGET_DIR="/home/lede/package"
LOG_FILE="/var/log/catwrt-pull.log"
TEMP_DIRS=()

# ---------------------------- 工具函数 ----------------------------

# 带重试的命令执行
retry() {
    local max_attempts=3
    local delay=5
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if eval "$@" 2>>"$LOG_FILE"; then
            return 0
        else
            echo -e "${YELLOW}[重试] 命令失败，${delay}秒后重试 ($attempt/$max_attempts)${NC}"
            sleep $delay
            ((attempt++))
        fi
    done
    echo -e "${RED}[错误] 命令最终失败: $*${NC}" | tee -a "$LOG_FILE"
    return 1
}

# 检查 Git 仓库是否可达（超时 5 秒）
check_repo_reachable() {
    local url=$1
    git ls-remote --heads "$url" &>/dev/null
    return $?
}

# 清理临时目录
cleanup_temp() {
    for dir in "${TEMP_DIRS[@]}"; do
        rm -rf "$dir" 2>/dev/null || true
    done
}
trap cleanup_temp EXIT

# 权限检查
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${GREEN}需要 root 才能使用，但是编译需要非 root 用户${NC}"
    exit 1
fi

if [ ! -d "/home/lede" ]; then
    echo -e "${RED}/home 目录下未找到 lede 源码仓库，请确保源码仓库在 /home 目录下${NC}"
    ls /home
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"

# ---------------------------- 仓库列表 ----------------------------

REPOS=(
    "https://github.com/miaoermua/cattools"
    "https://github.com/miaoermua/openwrt-homebox"
    "https://github.com/miaoermua/luci-app-poweroff"
    "https://github.com/destan19/OpenAppFilter"
    "https://github.com/fw876/helloworld"
    "https://github.com/Openwrt-Passwall/openwrt-passwall"
    "https://github.com/xiaorouji/openwrt-passwall2"            # 修正迁移后的地址
    "https://github.com/Openwrt-Passwall/openwrt-passwall-packages"
    "https://github.com/rufengsuixing/luci-app-adguardhome"
    "https://github.com/linkease/istore"
    "https://github.com/0x676e67/luci-theme-design"
    "https://github.com/Zxilly/UA2F"                            # 使用 v4.5.0
    "https://github.com/rufengsuixing/luci-app-usb3disable"
    "https://github.com/esirplayground/luci-app-LingTiGameAcc"
    "https://github.com/esirplayground/LingTiGameAcc"
    "https://github.com/messense/openwrt-netbird"
    "https://github.com/sirpdboy/luci-app-eqosplus"
    "https://github.com/sirpdboy/luci-app-autotimeset"
    "https://github.com/sirpdboy/luci-app-lucky"
    "https://github.com/sirpdboy/luci-app-ddns-go"              # 使用 lua 分支
    "https://github.com/Erope/openwrt_nezha"
    "https://github.com/sbwml/luci-app-alist"                   # 使用 v3.40.0
    "https://github.com/ilxp/luci-app-ikoolproxy"
    "https://github.com/jimlee2002/openwrt-minieap-gdufs"
    "https://github.com/jimlee2048/luci-proto-minieap"
    "https://github.com/ysc3839/openwrt-minieap"
    "https://github.com/BoringCat/luci-app-mentohust"
    "https://github.com/BoringCat/luci-app-minieap"
    "https://github.com/FUjr/luci-theme-asus"
    "https://github.com/SunBK201/UA3F"
    "https://github.com/yuhanjin/feed-netkeeper"
    "https://github.com/EOYOHOO/rkp-ipid"
    "https://github.com/EasyTier/luci-app-easytier"
    "https://github.com/sirpdboy/luci-app-partexp"
)

# 备用镜像映射（GitHub -> Gitee）
declare -A FALLBACK_URLS=(
    ["https://github.com/Zxilly/UA2F"]="https://gitee.com/mirrors/UA2F"
    ["https://github.com/sbwml/luci-app-alist"]="https://gitee.com/mirrors/luci-app-alist"
    ["https://github.com/sirpdboy/luci-app-ddns-go"]="https://gitee.com/mirrors/luci-app-ddns-go"
    ["https://github.com/fw876/helloworld"]="https://gitee.com/mirrors/helloworld"
    ["https://github.com/xiaorouji/openwrt-passwall2"]="https://gitee.com/mirrors/openwrt-passwall2"
)

# Openclash 配置
OPENCLASH_REPO="https://github.com/vernesong/OpenClash.git"
OPENCLASH_DIR="$TARGET_DIR/luci-app-openclash"

# WYC-2020 插件（需要稀疏检出）
WYC_REPO="https://github.com/WYC-2020/openwrt-packages.git"
WYC_PLUGINS=("ddnsto" "luci-app-ddnsto")

# 背景图片
BACKGROUND_IMAGE_URL="https://cdn.miaoer.net/images/bg/kami/background.png"
BACKGROUND_IMAGE_PATH="$TARGET_DIR/luci-theme-argon/htdocs/luci-static/argon/background"

# ---------------------------- 插件更新函数 ----------------------------

update_or_clone_repo() {
    local repo_url=$1
    local repo_name=$(basename -s .git "$repo_url")
    local repo_dir="$TARGET_DIR/$repo_name"

    echo -e "${GREEN}检查 $repo_name ...${NC}"
    
    # 预检：仓库是否可达（不可达直接跳过）
    if ! check_repo_reachable "$repo_url"; then
        echo -e "${YELLOW}[警告] 仓库 $repo_name 不可达，尝试备用源...${NC}"
        local fallback="${FALLBACK_URLS[$repo_url]:-}"
        if [[ -n "$fallback" ]] && check_repo_reachable "$fallback"; then
            repo_url="$fallback"
            echo -e "${GREEN}使用备用源: $repo_url${NC}"
        else
            echo -e "${RED}[跳过] 仓库 $repo_name 无可用源，继续下一项${NC}"
            return 0
        fi
    fi

    if [ ! -d "$repo_dir" ]; then
        echo -e "${GREEN}克隆 $repo_name${NC}"
        
        case "$repo_name" in
            UA2F)
                retry "git clone -b v4.5.0 --depth=1 $repo_url $repo_dir" || return 0
                ;;
            luci-app-alist)
                retry "git clone -b v3.40.0 --depth=1 $repo_url $repo_dir" || return 0
                ;;
            luci-app-ddns-go)
                retry "git clone -b lua --depth=1 $repo_url $repo_dir" || return 0
                ;;
            *)
                retry "git clone --depth=1 $repo_url $repo_dir" || return 0
                ;;
        esac
    else
        echo -e "${GREEN}更新 $repo_name${NC}"
        cd "$repo_dir" || return 0
        case "$repo_name" in
            UA2F)
                git fetch --tags --depth=1 2>/dev/null || true
                git checkout v4.5.0 2>/dev/null || true
                ;;
            luci-app-alist)
                git fetch --tags --depth=1 2>/dev/null || true
                git checkout v3.40.0 2>/dev/null || true
                ;;
            luci-app-ddns-go)
                git fetch origin lua --depth=1 2>/dev/null || true
                git checkout lua 2>/dev/null || true
                ;;
            *)
                git pull origin master --rebase 2>/dev/null || git pull 2>/dev/null || true
                ;;
        esac
        cd - > /dev/null || true
    fi
}

update_openclash() {
    echo -e "${GREEN}处理 luci-app-openclash${NC}"
    local repo="https://github.com/vernesong/OpenClash.git"
    local dest="$OPENCLASH_DIR"
    
    if ! check_repo_reachable "$repo"; then
        echo -e "${YELLOW}[警告] OpenClash 仓库不可达，跳过${NC}"
        return 0
    fi

    if [[ -d "$dest/.git" ]]; then
        echo -e "${GREEN}更新 OpenClash${NC}"
        cd "$dest" && git pull --depth=1 2>/dev/null || true
    else
        rm -rf "$dest" 2>/dev/null || true
        echo -e "${GREEN}克隆 OpenClash (浅克隆)${NC}"
        retry "git clone --depth=1 $repo $dest" || return 0
    fi
}

update_wyc_plugins() {
    echo -e "${GREEN}处理 WYC-2020 插件 (稀疏检出)${NC}"
    
    if ! check_repo_reachable "$WYC_REPO"; then
        echo -e "${YELLOW}[警告] WYC 仓库不可达，跳过${NC}"
        return 0
    fi

    local temp_dir=$(mktemp -d)
    TEMP_DIRS+=("$temp_dir")
    cd "$temp_dir" || return 0
    
    git init -q
    git remote add origin "$WYC_REPO"
    git config core.sparseCheckout true
    for plugin in "${WYC_PLUGINS[@]}"; do
        echo "$plugin" >> .git/info/sparse-checkout
    done
    
    if ! retry "git pull --depth=1 origin master"; then
        echo -e "${RED}[警告] WYC 仓库拉取失败，跳过${NC}"
        return 0
    fi
    
    for plugin in "${WYC_PLUGINS[@]}"; do
        if [[ -d "$temp_dir/$plugin" ]]; then
            rm -rf "$TARGET_DIR/$plugin"
            cp -r "$temp_dir/$plugin" "$TARGET_DIR/"
            echo -e "${GREEN}已更新 $plugin${NC}"
        fi
    done
}

update_bitsrunlogin_go() {
    echo -e "${GREEN}处理 immortalwrt bitsrunlogin-go (稀疏检出)${NC}"

    local temp_dir=$(mktemp -d)
    TEMP_DIRS+=("$temp_dir")
    mkdir -p "$temp_dir/luci" "$temp_dir/packages"

    # Luci 部分
    cd "$temp_dir/luci"
    git init -q && git remote add origin https://github.com/immortalwrt/luci.git
    git config core.sparseCheckout true
    echo "applications/luci-app-bitsrunlogin-go" >> .git/info/sparse-checkout
    if ! retry "git pull --depth=1 origin master"; then
        echo -e "${YELLOW}[警告] 提取 luci-app-bitsrunlogin-go 失败${NC}"
    fi

    # Packages 部分
    cd "$temp_dir/packages"
    git init -q && git remote add origin https://github.com/immortalwrt/packages.git
    git config core.sparseCheckout true
    echo "net/bitsrunlogin-go" >> .git/info/sparse-checkout
    if ! retry "git pull --depth=1 origin master"; then
        echo -e "${YELLOW}[警告] 提取 bitsrunlogin-go 失败${NC}"
    fi

    # 复制到目标
    LUCI_SRC="$temp_dir/luci/applications/luci-app-bitsrunlogin-go"
    LUCI_DST="$TARGET_DIR/luci-app-bitsrunlogin-go"
    if [[ -d "$LUCI_SRC" ]]; then
        rm -rf "$LUCI_DST"
        cp -r "$LUCI_SRC" "$LUCI_DST"
        echo -e "${GREEN}已更新 luci-app-bitsrunlogin-go${NC}"
    fi

    PKG_SRC="$temp_dir/packages/net/bitsrunlogin-go"
    PKG_DST="$TARGET_DIR/bitsrunlogin-go"
    if [[ -d "$PKG_SRC" ]]; then
        rm -rf "$PKG_DST"
        cp -r "$PKG_SRC" "$PKG_DST"
        echo -e "${GREEN}已更新 bitsrunlogin-go${NC}"
    fi
}

update_luci_theme_argon() {
    echo -e "${GREEN}处理 luci-theme-argon${NC}"
    local repo_url="https://github.com/jerrykuku/luci-theme-argon"
    local repo_dir="$TARGET_DIR/luci-theme-argon"

    if ! check_repo_reachable "$repo_url"; then
        echo -e "${YELLOW}[警告] argon 主题仓库不可达，跳过${NC}"
        return 0
    fi

    if [ ! -d "$repo_dir" ]; then
        echo -e "${GREEN}克隆 luci-theme-argon (分支 18.06)${NC}"
        retry "git clone -b 18.06 --depth=1 $repo_url $repo_dir" || return 0
    else
        echo -e "${GREEN}更新 luci-theme-argon${NC}"
        cd "$repo_dir" || return 0
        git pull origin 18.06 2>/dev/null || true
        cd - > /dev/null || true
    fi

    # 下载背景图
    if [ ! -f "$BACKGROUND_IMAGE_PATH/background.png" ]; then
        echo -e "${GREEN}下载背景图片${NC}"
        mkdir -p "$BACKGROUND_IMAGE_PATH"
        retry "wget -q --show-progress --tries=3 --retry-connrefused -O $BACKGROUND_IMAGE_PATH/background.png $BACKGROUND_IMAGE_URL" || \
            echo -e "${YELLOW}[警告] 背景图下载失败，但不影响编译${NC}"
    else
        echo -e "${GREEN}背景图片已存在，跳过${NC}"
    fi
}

rm_lean_ddnsgo() {
    echo -e "${GREEN}移除 feeds 中的默认 ddns-go 包${NC}"
    rm -rf /home/lede/feeds/packages/net/ddns-go 2>/dev/null || true
    rm -rf /home/lede/feeds/luci/applications/luci-app-ddns-go 2>/dev/null || true
}

# ---------------------------- 主流程 ----------------------------

main() {
    echo -e "${GREEN}========== CatWrt 插件拉取脚本 (增强版) ==========${NC}"
    
    # 逐个更新仓库
    for repo in "${REPOS[@]}"; do
        update_or_clone_repo "$repo"
    done

    update_openclash
    update_wyc_plugins
    update_bitsrunlogin_go
    update_luci_theme_argon
    rm_lean_ddnsgo

    echo -e "${GREEN}========== 所有插件处理完毕 ==========${NC}"
    echo -e "${GREEN}日志文件: $LOG_FILE${NC}"
}

main "$@"
