# 优化基础镜像，使用兼容的scratch，添加元数据
FROM scratch

# 镜像元数据
LABEL maintainer="CatWrt Team"
LABEL org.opencontainers.image.title="CatWrt"
LABEL org.opencontainers.image.description="CatWrt Docker Image for x86_64"
LABEL org.opencontainers.image.source="https://github.com/miaoermua/catwrt_base"

# 将编译生成的根文件系统导入镜像
ADD rootfs.tar.gz /

# 复制启动脚本（权限已在宿主机设置，直接ADD保留）
COPY docker-entrypoint.sh /usr/local/bin/

# 声明容器内可用的网络端口
EXPOSE 22 80 443 53/udp 53/tcp 8080 1883

# 设置默认用户为 root
USER root

# 健康检查：修复IP笔误，检查web服务是否正常，增加重试兼容
HEALTHCHECK --interval=30s --timeout=10s --retries=3 CMD wget -q --spider http://127.0.0.1/ || exit 1

# 使用优化后的启动脚本
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/sbin/init"]
