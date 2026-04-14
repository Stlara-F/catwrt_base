#!/bin/bash
# CatWrt 容器入口点 (优化版+全局变量适配)
# 支持调试模式、自动权限修复、信号处理、全局架构变量

set -euo pipefail

# 颜色输出
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

# ===================== 新增：全局环境变量定义 =====================
CATWRT_ARCH="${CATWRT_ARCH:-"amd64"}"
CATWRT_VER="${CATWRT_VER:-"v24.9"}"
CATWRT_USER="${CATWRT_USER:-"builder"}"
# ================================================================

log_info()  { echo -e "${GREEN}[ENTRY]${NC} $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[ENTRY]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_error() { echo -e "${RED}[ENTRY]${NC} $(date '+%H:%M:%S') $*" >&2; exit 1; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" || true; }

# 信号处理（确保清理）
cleanup() {
    log_info "接收到信号，执行清理..."
    # 保存 ccache 缓存
    sync || true
    exit 0
}
trap cleanup SIGINT SIGTERM

# 检查目录结构
check_directories() {
    local dirs=("/home/lede" "/home/catwrt_base" "/output" "/var/log/catwrt-build")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_info "创建目录: $dir"
            mkdir -p "$dir"
        fi
    done
}

# 智能权限修复（仅当必要时）
fix_permissions() {
    local owner=$(stat -c '%u:%g' /home/lede 2>/dev/null || echo "0:0")
    if [[ "$owner" != "1000:1000" ]]; then
        log_info "修复目录权限（builder:builder）..."
        # 使用 chown 的参考文件选项加速
        chown -R builder:builder /home/lede /home/catwrt_base /output /var/log/catwrt-build 2>/dev/null || {
            log_warn "权限修复失败，尝试使用 sudo..."
            sudo chown -R builder:builder /home/lede /home/catwrt_base /output /var/log/catwrt-build || true
        }
    fi
}

# 验证环境
validate_environment() {
    # 检查必要命令
    local cmds=("git" "make" "gcc" "curl" "sudo")
    for cmd in "${cmds[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || log_error "缺少必要命令: $cmd"
    done
    
    # 🔥 修复：Git 安全目录配置容错
    log_info "全局配置Git安全目录..."
    git config --global --add safe.directory '*' 2>/dev/null || true
    sudo -u builder git config --global --add safe.directory '*' 2>/dev/null || true
    
    # 检查磁盘空间（至少 10GB 可用）
    local avail=$(df -BG /output | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ "$avail" -lt 10 ]]; then
        log_warn "警告: /output 可用空间不足 10GB (当前: ${avail}GB)"
    fi
    
    # 检查内存
    local mem=$(free -g | awk '/^Mem:/{print $2}')
    log_info "系统内存: ${mem}GB"
    
    # ===================== 新增：打印全局架构/版本 =====================
    log_info "环境验证通过 | 全局架构: ${CATWRT_ARCH} | 全局版本: ${CATWRT_VER}"
    # ================================================================
}

# 主流程
main() {
    log_info "CatWrt Docker Builder 启动"
    log_debug "参数: $*"
    log_debug "用户: $(id)"
    # ===================== 新增：启动日志打印全局配置 =====================
    log_info "全局配置 -> 架构: ${CATWRT_ARCH} | 版本: ${CATWRT_VER}"
    # ================================================================
    
    check_directories
    fix_permissions
    validate_environment
    
    # 如果参数为空或 --help，显示帮助
    if [[ $# -eq 0 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        echo "CatWrt 全自动编译容器"
        echo ""
        echo "用法: docker run --rm -v ./output:/output catwrt/builder [选项]"
        echo ""
        echo "常用命令:"
        # ===================== 修改：动态显示全局变量，不写死 =====================
        echo "  --auto --arch=${CATWRT_ARCH} --ver=${CATWRT_VER}          全自动编译（当前全局配置）"
        echo "  --auto --arch=mt7621 --ver=v24.9         全自动编译 mt7621"
        echo "  --auto --arch=diy/theme-whu              编译 DIY 主题版本"
        echo "  --clean-build --auto --arch=amd64        干净构建（清理后编译）"
        # ================================================================
        echo ""
        echo "环境变量:"
        echo "  DEBUG=true                              启用调试输出"
        echo "  MAKE_JOBS=8                             设置并行编译数"
        echo "  DISCORD_WEBHOOK=url                     编译完成通知"
        # ===================== 新增：帮助文档标注全局变量 =====================
        echo "  CATWRT_ARCH=amd64                       全局指定编译架构"
        echo "  CATWRT_VER=v24.9                        全局指定编译版本"
        # ================================================================
        echo ""
        exit 0
    fi
    
    # 使用 gosu 切换到 builder 用户执行（保留环境变量）
    log_info "切换到 builder 用户执行编译..."
    export HOME=/home/builder
    export USER=builder
    # ===================== 新增：导出全局变量，子进程100%继承 =====================
    export CATWRT_ARCH CATWRT_VER CATWRT_USER
    # ================================================================
    
    # 传递所有参数给编译脚本
    # ===================== 修复：sudo -E 保留环境变量（解决变量失效核心！） =====================
    exec gosu builder sudo -E /usr/local/bin/catwrt-build "$@"
}

main "$@"
