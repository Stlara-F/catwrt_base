FROM scratch

# 将编译生成的根文件系统导入镜像
ADD rootfs.tar.gz /

# 声明容器内可用的网络端口
EXPOSE 22 80 443 53/udp 53/tcp

# 设置默认用户为 root
USER root

# 使用 OpenWrt 的标准初始化进程
CMD ["/sbin/init"]
