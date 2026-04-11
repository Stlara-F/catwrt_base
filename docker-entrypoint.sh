#!/bin/sh
set -e

# 信号处理：优雅关闭容器
handle_signal() {
    echo "Received signal to stop container, shutting down gracefully..."
    # 尝试优雅关闭
    if [ -x /sbin/init ]; then
        /sbin/init 0 2>/dev/null || true
    fi
    exit 0
}

# 注册信号捕获
trap handle_signal SIGINT SIGTERM

# 初始化检查
echo "=========================================="
echo "  CatWrt Docker Container"
echo "  Architecture: $(uname -m)"
echo "  Date: $(date)"
echo "=========================================="

# 确保必要目录存在
mkdir -p /tmp /var/run /var/log

# 启动核心服务
echo "Starting CatWrt services..."
if [ -x /sbin/init ]; then
    exec /sbin/init
else
    echo "ERROR: /sbin/init not found!"
    exit 1
fi
