#!/bin/sh
set -e

# 信号处理：支持SIGTERM，让容器能正确退出
term_handler() {
  echo "Received SIGTERM, shutting down..."
  if [ -x /sbin/init ]; then
    kill -TERM $init_pid
  fi
  exit 0
}

trap 'term_handler' SIGTERM SIGINT

# 启动 syslogd 和 klogd（日志服务）
[ -x /sbin/syslogd ] && /sbin/syslogd -s -b 8
[ -x /sbin/klogd ] && /sbin/klogd

# 初始化网络，修复容器内的网络配置
if [ -x /etc/init.d/network ]; then
  /etc/init.d/network enable
  /etc/init.d/network start
fi

# 启动 SSH 服务（如果安装了 dropbear）
[ -x /etc/init.d/dropbear ] && /etc/init.d/dropbear start

# 启动防火墙
[ -x /etc/init.d/firewall ] && /etc/init.d/firewall start

# 自动清理临时文件
rm -rf /tmp/* /var/run/*

# 最后执行容器主进程，记录PID用于信号处理
exec /sbin/init &
init_pid=$!
wait $init_pid
