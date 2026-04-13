#!/bin/bash
GREEN='\033[0;32m'
NC='\033[0m'

USER_HOME="/home"
TARGET_DIR="/home/lede/package"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${GREEN}需要 root 才能使用，但是编译需要非 root 用户${NC}"
    exit 1
fi

if [ ! -d "/home/lede" ]; then
    echo -e "${GREEN}/home 目录下未找到 lede 源码仓库，请确保源码仓库在 /home 目录下，请善用 mv 命令移动源码仓库${NC}"
    ls /home
    exit 1
fi

REPOS=(
    "https://github.com/miaoermua/cattools"
    "https://github.com/miaoermua/openwrt-homebox"
    "https://github.com/miaoermua/luci-app-poweroff"
    "https://github.com/destan19/OpenAppFilter"
    "https://github.com/fw876/helloworld"
    "https://github.com/Openwrt-Passwall/openwrt-passwall"
    "https://github.com/Openwrt-Passwall/openwrt-passwall2"
    "https://github.com/Openwrt-Passwall/openwrt-passwall-packages"
    "https://github.com/rufengsuixing/luci-app-adguardhome"
    "https://github.com/linkease/istore"
    "https://github.com/0x676e67/luci-theme-design"
    "https://github.com/Zxilly/UA2F"               ## will use v4.5.0 tag
    "https://github.com/rufengsuixing/luci-app-usb3disable"
    "https://github.com/esirplayground/luci-app-LingTiGameAcc"
    "https://github.com/esirplayground/LingTiGameAcc"
    "https://github.com/messense/openwrt-netbird"
    "https://github.com/sirpdboy/luci-app-eqosplus"
    "https://github.com/sirpdboy/luci-app-autotimeset"
    "https://github.com/sirpdboy/luci-app-lucky"
    "https://github.com/sirpdboy/luci-app-ddns-go" ## will use 6.9.1 tag
    "https://github.com/Erope/openwrt_nezha"
    "https://github.com/sbwml/luci-app-alist"      ## will use v3.40.0 tag
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

# Openclash
OPENCLASH_URL="https://github.com/vernesong/OpenClash/archive/refs/heads/master.zip"
OPENCLASH_DIR="$TARGET_DIR/luci-app-openclash"

# WYC-2020 openwrt-packages
WYC_REPO_URL="https://github.com/WYC-2020/openwrt-packages"
WYC_REPO_DIR="$USER_HOME/openwrt-packages"
WYC_PLUGINS=("ddnsto" "luci-app-ddnsto")

# download kami background
BACKGROUND_IMAGE_URL="https://cdn.miaoer.net/images/bg/kami/background.png"
BACKGROUND_IMAGE_PATH="$TARGET_DIR/luci-theme-argon/htdocs/luci-static/argon/background"

update_or_clone_repo() {
    repo_url=$1
    repo_name=$(basename -s .git "$repo_url")
    repo_dir="$TARGET_DIR/$repo_name"

    if [ ! -d "$repo_dir" ]; then
        echo -e "${GREEN}Cloning $repo_name${NC}"
        
        # 加上 || true 捕获错误，防止失效的仓库导致整个脚本异常退出
        case "$repo_name" in
            UA2F)
                git clone -b v4.5.0 --depth=1 "$repo_url" "$repo_dir" || echo -e "\033[0;31m[警告] 拉取 UA2F 失败，跳过...\033[0m"
                ;;
            luci-app-alist)
                git clone -b v3.40.0 --depth=1 "$repo_url" "$repo_dir" || echo -e "\033[0;31m[警告] 拉取 alist 失败，跳过...\033[0m"
                ;;
            luci-app-ddns-go)
                git clone -b lua --depth=1 "$repo_url" "$repo_dir" || echo -e "\033[0;31m[警告] 拉取 ddns-go 失败，跳过...\033[0m"
                ;;
            *)
                git clone --depth=1 "$repo_url" "$repo_dir" || echo -e "\033[0;31m[警告] 仓库 $repo_name 失效或网络错误，已跳过！\033[0m"
                ;;
        esac
    else
        echo -e "${GREEN}Updating $repo_name${NC}"
        cd "$repo_dir" || return
        # 同样的防错处理
        case "$repo_name" in
            UA2F) git fetch --tags && git checkout v4.5.0 || true ;;
            luci-app-alist) git fetch --tags && git checkout v3.40.0 || true ;;
            luci-app-ddns-go) git fetch origin lua && git checkout lua || true ;;
            *) git pull origin master --rebase || git pull || true ;;
        esac
        cd - > /dev/null || exit
    fi
}

update_openclash() {
    echo -e "${GREEN}Processing luci-app-openclash${NC}"
    if [ -d "$OPENCLASH_DIR" ]; then
        echo -e "${GREEN}Removing old luci-app-openclash${NC}"
        rm -rf "$OPENCLASH_DIR"
    fi
    echo -e "${GREEN}Downloading and extracting OpenClash${NC}"
    wget -O /tmp/master.zip "$OPENCLASH_URL"
    unzip /tmp/master.zip -d /tmp
    mv /tmp/OpenClash-master/luci-app-openclash "$TARGET_DIR/"
    rm -rf /tmp/master.zip /tmp/OpenClash-master
}

update_wyc_plugins() {
    echo -e "${GREEN}Processing WYC-2020 openwrt-packages${NC}"

    if [ -d "$WYC_REPO_DIR" ]; then
        echo -e "${GREEN}Updating WYC-2020 openwrt-packages${NC}"
        cd "$WYC_REPO_DIR" || exit
        git pull
    else
        echo -e "${GREEN}Cloning WYC-2020 openwrt-packages${NC}"
        git clone "$WYC_REPO_URL" "$WYC_REPO_DIR"
    fi

    for plugin in "${WYC_PLUGINS[@]}"; do
        plugin_src="$WYC_REPO_DIR/$plugin"
        plugin_dst="$TARGET_DIR/$plugin"
        if [ -d "$plugin_dst" ]; then
            echo -e "${GREEN}Updating $plugin${NC}"
            rm -rf "$plugin_dst"
        fi
        cp -r "$plugin_src" "$plugin_dst"
    done
}

update_bitsrunlogin_go() {
    echo -e "${GREEN}Processing immortalwrt luci & packages (使用稀疏克隆极速拉取)${NC}"

    TEMP_DIR="/tmp/immortalwrt_bitsrunlogin"
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR/luci" "$TEMP_DIR/packages"

    # 使用 Git 稀疏检出，只拉取特定文件夹，节省数百 MB 流量和大量时间
    cd "$TEMP_DIR/luci"
    git init && git remote add origin https://github.com/immortalwrt/luci.git
    git config core.sparseCheckout true
    echo "applications/luci-app-bitsrunlogin-go" >> .git/info/sparse-checkout
    git pull --depth=1 origin master || echo -e "\033[0;31m[警告] 提取 luci-app-bitsrunlogin-go 失败\033[0m"

    cd "$TEMP_DIR/packages"
    git init && git remote add origin https://github.com/immortalwrt/packages.git
    git config core.sparseCheckout true
    echo "net/bitsrunlogin-go" >> .git/info/sparse-checkout
    git pull --depth=1 origin master || echo -e "\033[0;31m[警告] 提取 bitsrunlogin-go 失败\033[0m"

    # 复制到目标目录
    LUCI_SRC="$TEMP_DIR/luci/applications/luci-app-bitsrunlogin-go"
    LUCI_DST="$TARGET_DIR/luci-app-bitsrunlogin-go"
    if [ -d "$LUCI_SRC" ]; then
        rm -rf "$LUCI_DST" && cp -r "$LUCI_SRC" "$LUCI_DST"
    fi

    PKG_SRC="$TEMP_DIR/packages/net/bitsrunlogin-go"
    PKG_DST="$TARGET_DIR/bitsrunlogin-go"
    if [ -d "$PKG_SRC" ]; then
        rm -rf "$PKG_DST" && cp -r "$PKG_SRC" "$PKG_DST"
    fi

    rm -rf "$TEMP_DIR"
}

update_luci_theme_argon() {
    set -x
    repo_url="https://github.com/jerrykuku/luci-theme-argon"
    repo_name=$(basename -s .git "$repo_url")
    repo_dir="$TARGET_DIR/$repo_name"

    echo -e "${GREEN}Processing $repo_name${NC}"

    if [ ! -d "$repo_dir" ]; then
        echo -e "${GREEN}Cloning $repo_name (branch 18.06)${NC}"
        git clone -b 18.06 "$repo_url" "$repo_dir"
    else
        echo -e "${GREEN}Updating $repo_name${NC}"
        cd "$repo_dir" || exit
        git pull origin 18.06
        rm -rf /home/lede/feeds/luci/themes/luci-theme-argon
        cd - || exit
    fi

    if [ ! -f "$BACKGROUND_IMAGE_PATH/background.png" ]; then
        echo -e "${GREEN}Downloading background image${NC}"
        mkdir -p "$BACKGROUND_IMAGE_PATH"
        wget -O "$BACKGROUND_IMAGE_PATH/background.png" "$BACKGROUND_IMAGE_URL"
    else
        echo -e "${GREEN}Background image already exists, skipping download${NC}"
    fi
    set +x
}

rm_lean_ddnsgo(){
    set -x
    rm -rf /home/lede/feeds/packages/net/ddns-go
    rm -rf /home/lede/feeds/luci/applications/luci-app-ddns-go
    set +x
}

for repo in "${REPOS[@]}"; do
    update_or_clone_repo "$repo"
done

update_openclash
update_wyc_plugins
update_bitsrunlogin_go
update_luci_theme_argon
rm_lean_ddnsgo

echo -e "${GREEN}All repositories are up to date.${NC}"
