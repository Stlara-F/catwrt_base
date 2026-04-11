#!/bin/sh
set -e

# 信号处理：优雅关闭容器
handle_signal() {
    echo "Received signal to stop container, shutting down gracefully..."
    /sbin/init 0
}

# 注册信号捕获
trap handle_signal SIGINT SIGTERM

# 启动核心服务
echo "Starting CatWrt services..."
/sbin/init &

# 等待信号或服务退出
wait $!
