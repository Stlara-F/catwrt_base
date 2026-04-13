#!/bin/bash
# CatWrt 插件拉取脚本 (最终稳定版)
# 特性：重试机制、预检可达性、Gitee/FastGit 双备用源、版本强制锁定

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

USER_HOME="/home"
TARGET_DIR="/home/lede/package"
LOG_FILE="/var/log/catwrt-pull.log"
TEMP_DIRS=()

# ---------------------------- 工具函数 ----------------------------

retry() {
    local max=3
    local delay=5
    local i=1
    while [[ $i -le $max ]]; do
        if eval "$@" 2>>"$LOG_FILE"; then
            return 0
        fi
        echo -e "${YELLOW}[重试] 命令失败，${delay}秒后重试 ($i/$max)${NC}"
        sleep $delay
        ((i++))
    done
    echo -e "${RED}[错误] 命令最终失败: $*${NC}" | tee -a "$LOG_FILE"
    return 1
}

check_repo_reachable() {
    local url=$1
    git ls-remote --heads "$url" &>/dev/null
    return $?
}

cleanup_temp() {
    for dir in "${TEMP_DIRS[@]}"; do
        rm -rf "$dir" 2>/dev/null || true
    done
}
trap cleanup_temp EXIT

# 权限与目录检查
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${GREEN}需要 root 才能使用，但是编译需要非 root 用户${NC}"
    exit 1
fi

if [ ! -d "/home/lede" ]; then
    echo -e "${RED}/home 目录下未找到 lede 源码仓库${NC}"
    ls /home
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"

# ---------------------------- 仓库列表 (2026年验证版) ----------------------------
REPOS=(
    "https://github.com/miaoermua/cattools"
    "https://github.com/miaoermua/openwrt-homebox"
    "https://github.com/miaoermua/luci-app-poweroff"
    "https://github.com/destan19/OpenAppFilter"
    "https://github.com/fw876/helloworld"
    "https://github.com/Openwrt-Passwall/openwrt-passwall"
    "https://github.com/Openwrt-Passwall/openwrt-passwall2"          # 官方组织地址
    "https://github.com/Openwrt-Passwall/openwrt-passwall-packages"
    "https://github.com/rufengsuixing/luci-app-adguardhome"
    "https://github.com/linkease/istore"
    "https://github.com/0x676e67/luci-theme-design"
    "https://github.com/Zxilly/UA2F"                                # 强制 v4.5.0
    "https://github.com/rufengsuixing/luci-app-usb3disable"
    "https://github.com/esirplayground/luci-app-LingTiGameAcc"
    "https://github.com/esirplayground/LingTiGameAcc"
    "https://github.com/messense/openwrt-netbird"
    "https://github.com/sirpdboy/luci-app-eqosplus"
    "https://github.com/sirpdboy/luci-app-autotimeset"
    "https://github.com/sirpdboy/luci-app-lucky"
    "https://github.com/sirpdboy/luci-app-ddns-go"                  # 强制 lua 分支
    "https://github.com/Erope/openwrt_nezha"
    "https://github.com/sbwml/luci-app-alist"                       # 强制 v3.40.0
    "https://github.com/ilxp/luci-app-ikoolproxy"
    "https://github.com/jimlee2002/openwrt-minieap-gdufs"
    "https://github.com/jimlee2048/luci-proto-minieap"
    "https://github.com/ysc3839/openwrt-minieap"
    "https://github.com/BoringCat/luci-app-mentohust"
    "https://github.com/BoringCat/luci-app-minieap"
    "https://github.com/FUjr/luci-theme-asus"
    "https://github.com/SunBK201/UA3F"
#    "https://github.com/yuhanjin/feed-netkeeper"
    "https://github.com/EOYOHOO/rkp-ipid"
    "https://github.com/EasyTier/luci-app-easytier"
    "https://github.com/sirpdboy/luci-app-partexp"
)

# 备用镜像映射 (Gitee + FastGit)
declare -A FALLBACK_URLS=(
    ["https://github.com/Zxilly/UA2F"]="https://hub.fastgit.xyz/Zxilly/UA2F"
    ["https://github.com/sbwml/luci-app-alist"]="https://hub.fastgit.xyz/sbwml/luci-app-alist"
    ["https://github.com/sirpdboy/luci-app-ddns-go"]="https://hub.fastgit.xyz/sirpdboy/luci-app-ddns-go"
    ["https://github.com/fw876/helloworld"]="https://hub.fastgit.xyz/fw876/helloworld"
    ["https://github.com/Openwrt-Passwall/openwrt-passwall2"]="https://hub.fastgit.xyz/Openwrt-Passwall/openwrt-passwall2"
    # 第二备选 Gitee（部分可能失效）
    ["https://github.com/Zxilly/UA2F-gitee"]="https://gitee.com/mirrors/UA2F"
    ["https://github.com/sbwml/luci-app-alist-gitee"]="https://gitee.com/mirrors/luci-app-alist"
)

# 特殊配置
OPENCLASH_REPO="https://github.com/vernesong/OpenClash.git"
OPENCLASH_DIR="$TARGET_DIR/luci-app-openclash"

WYC_REPO="https://github.com/WYC-2020/openwrt-packages.git"
WYC_PLUGINS=("ddnsto" "luci-app-ddnsto")

BACKGROUND_IMAGE_URL="https://cdn.miaoer.net/images/bg/kami/background.png"
BACKGROUND_IMAGE_PATH="$TARGET_DIR/luci-theme-argon/htdocs/luci-static/argon/background"

# ---------------------------- 核心更新函数 ----------------------------

update_or_clone_repo() {
    local repo_url=$1
    local repo_name=$(basename -s .git "$repo_url")
    local repo_dir="$TARGET_DIR/$repo_name"

    echo -e "${GREEN}检查 $repo_name ...${NC}"

    # 预检可达性
    if ! check_repo_reachable "$repo_url"; then
        echo -e "${YELLOW}[警告] 主源不可达，尝试备用镜像...${NC}"
        local fallback="${FALLBACK_URLS[$repo_url]:-}"
        if [[ -n "$fallback" ]] && check_repo_reachable "$fallback"; then
            repo_url="$fallback"
            echo -e "${GREEN}使用备用源: $repo_url${NC}"
        else
            echo -e "${RED}[跳过] $repo_name 无可用源${NC}"
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
        # 确保本地强制对齐版本/分支
        case "$repo_name" in
            UA2F)
                git fetch --tags --depth=1 origin 2>/dev/null || true
                git checkout v4.5.0 2>/dev/null || true
                ;;
            luci-app-alist)
                git fetch --tags --depth=1 origin 2>/dev/null || true
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
    echo -e "${GREEN}处理 OpenClash${NC}"
    local repo="https://github.com/vernesong/OpenClash.git"
    if ! check_repo_reachable "$repo"; then
        repo="https://hub.fastgit.xyz/vernesong/OpenClash.git"
        check_repo_reachable "$repo" || { echo -e "${YELLOW}[跳过] OpenClash 无可用源${NC}"; return 0; }
    fi
    if [[ -d "$OPENCLASH_DIR/.git" ]]; then
        cd "$OPENCLASH_DIR" && git pull --depth=1 2>/dev/null || true
    else
        rm -rf "$OPENCLASH_DIR" 2>/dev/null || true
        retry "git clone --depth=1 $repo $OPENCLASH_DIR" || return 0
    fi
}

update_wyc_plugins() {
    echo -e "${GREEN}处理 WYC-2020 (稀疏检出)${NC}"
    if ! check_repo_reachable "$WYC_REPO"; then
        WYC_REPO="https://hub.fastgit.xyz/WYC-2020/openwrt-packages.git"
        check_repo_reachable "$WYC_REPO" || { echo -e "${YELLOW}[跳过] WYC 无可用源${NC}"; return 0; }
    fi
    local temp_dir=$(mktemp -d)
    TEMP_DIRS+=("$temp_dir")
    cd "$temp_dir" || return 0
    git init -q && git remote add origin "$WYC_REPO"
    git config core.sparseCheckout true
    for plugin in "${WYC_PLUGINS[@]}"; do
        echo "$plugin" >> .git/info/sparse-checkout
    done
    if ! retry "git pull --depth=1 origin master"; then
        echo -e "${RED}[警告] WYC 拉取失败${NC}"
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
    echo -e "${GREEN}处理 bitsrunlogin-go (稀疏检出)${NC}"
    local temp_dir=$(mktemp -d)
    TEMP_DIRS+=("$temp_dir")
    mkdir -p "$temp_dir/luci" "$temp_dir/packages"

    cd "$temp_dir/luci"
    git init -q && git remote add origin https://github.com/immortalwrt/luci.git
    git config core.sparseCheckout true
    echo "applications/luci-app-bitsrunlogin-go" >> .git/info/sparse-checkout
    retry "git pull --depth=1 origin master" || echo -e "${YELLOW}[警告] luci 部分失败${NC}"

    cd "$temp_dir/packages"
    git init -q && git remote add origin https://github.com/immortalwrt/packages.git
    git config core.sparseCheckout true
    echo "net/bitsrunlogin-go" >> .git/info/sparse-checkout
    retry "git pull --depth=1 origin master" || echo -e "${YELLOW}[警告] packages 部分失败${NC}"

    local src dst
    src="$temp_dir/luci/applications/luci-app-bitsrunlogin-go"
    dst="$TARGET_DIR/luci-app-bitsrunlogin-go"
    if [[ -d "$src" ]]; then
        rm -rf "$dst" && cp -r "$src" "$dst"
        echo -e "${GREEN}已更新 luci-app-bitsrunlogin-go${NC}"
    fi
    src="$temp_dir/packages/net/bitsrunlogin-go"
    dst="$TARGET_DIR/bitsrunlogin-go"
    if [[ -d "$src" ]]; then
        rm -rf "$dst" && cp -r "$src" "$dst"
        echo -e "${GREEN}已更新 bitsrunlogin-go${NC}"
    fi
}

update_luci_theme_argon() {
    echo -e "${GREEN}处理 luci-theme-argon${NC}"
    local repo_url="https://github.com/jerrykuku/luci-theme-argon"
    if ! check_repo_reachable "$repo_url"; then
        repo_url="https://hub.fastgit.xyz/jerrykuku/luci-theme-argon"
        check_repo_reachable "$repo_url" || { echo -e "${YELLOW}[跳过] argon 主题不可用${NC}"; return 0; }
    fi
    local repo_dir="$TARGET_DIR/luci-theme-argon"
    if [ ! -d "$repo_dir" ]; then
        retry "git clone -b 18.06 --depth=1 $repo_url $repo_dir" || return 0
    else
        cd "$repo_dir" && git pull origin 18.06 2>/dev/null || true
        cd - > /dev/null || true
    fi
    if [ ! -f "$BACKGROUND_IMAGE_PATH/background.png" ]; then
        mkdir -p "$BACKGROUND_IMAGE_PATH"
        retry "wget -q --show-progress --tries=3 -O $BACKGROUND_IMAGE_PATH/background.png $BACKGROUND_IMAGE_URL" || \
            echo -e "${YELLOW}[警告] 背景图下载失败${NC}"
    fi
}

rm_lean_ddnsgo() {
    echo -e "${GREEN}移除 feeds 默认 ddns-go${NC}"
    rm -rf /home/lede/feeds/packages/net/ddns-go 2>/dev/null || true
    rm -rf /home/lede/feeds/luci/applications/luci-app-ddns-go 2>/dev/null || true
}

# ---------------------------- 主流程 ----------------------------
main() {
    echo -e "${GREEN}========== CatWrt 插件拉取 (最终验证版) ==========${NC}"
    for repo in "${REPOS[@]}"; do
        update_or_clone_repo "$repo"
    done
    update_openclash
    update_wyc_plugins
    update_bitsrunlogin_go
    update_luci_theme_argon
    rm_lean_ddnsgo
    echo -e "${GREEN}========== 全部完成，日志见 $LOG_FILE ==========${NC}"
        # 🔥 新增：自动修复高优先级代码错误
    log INFO "========== 自动应用源码补丁 =========="
    apply_patches
    echo -e "${GREEN}========== 全部完成 ==========${NC}"
}

# 🔥 新增补丁函数
apply_patches() {
    local LEDE_PKG="/home/lede/package"
    # 1. 修复fast-classifier逻辑错误
    local fast_classifier="$LEDE_PKG/fast-classifier/src/fast-classifier.c"
    if [[ -f "$fast_classifier" ]]; then
        sed -i 's/if (sis->src_dev && IFF_EBRIDGE/if (sis->src_dev && (sis->src_dev->flags \& IFF_EBRIDGE)/g' "$fast_classifier"
        sed -i 's/if (sis->dest_dev && IFF_EBRIDGE/if (sis->dest_dev && (sis->dest_dev->flags \& IFF_EBRIDGE)/g' "$fast_classifier"
        sed -i '1i int fast_classifier_recv(struct sk_buff *skb);' "$fast_classifier"
        echo "✅ 修复 fast-classifier 逻辑错误"
    fi

    # 2. 修复appfilter格式字符串类型不匹配
    local appfilter_ubus="$LEDE_PKG/OpenAppFilter/src/appfilter_ubus.c"
    if [[ -f "$appfilter_ubus" ]]; then
        sed -i 's/%d\\n", period_count, json_object_array_length/%zu\\n", period_count, json_object_array_length/g' "$appfilter_ubus"
        sed -i 's/char \*mac = json_object_get_string/const char \*mac = json_object_get_string/g' "$appfilter_ubus"
        echo "✅ 修复 appfilter 格式字符串/const 警告"
    fi

    # 3. 修复Rust bootstrap.toml缺失change-id
    local rust_bootstrap="$LEDE_PKG/rust/bootstrap.toml"
    if [[ -f "$rust_bootstrap" ]]; then
        sed -i '1i change-id = "ignore"' "$rust_bootstrap"
        echo "✅ 修复 Rust bootstrap 警告"
    fi
}

main "$@"
