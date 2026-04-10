#!/bin/sh
set -e

# 启动 syslogd 和 klogd（日志服务）
[ -x /sbin/syslogd ] && /sbin/syslogd
[ -x /sbin/klogd ] && /sbin/klogd

# 启动 SSH 服务（如果安装了 dropbear）
[ -x /etc/init.d/dropbear ] && /etc/init.d/dropbear start

# 如果有自定义启动脚本，可以放在这里

# 最后执行容器主进程
exec /sbin/init
