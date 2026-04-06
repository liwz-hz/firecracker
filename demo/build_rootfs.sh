#!/bin/bash
# 构建 rootfs 镜像
# 用法: ./build_rootfs.sh

set -e

cd "$(dirname "$0")"

ROOTFS_TAR="alpine-rootfs.tar.gz"
ROOTFS_IMG="alpine-rootfs.img"
TMP_DIR="/tmp/rootfs-content"

if [ ! -f "$ROOTFS_TAR" ]; then
    echo "✗ 缺少 $ROOTFS_TAR"
    echo "请先下载: wget https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.0-x86_64.tar.gz"
    exit 1
fi

echo "构建 rootfs 镜像..."

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
tar -xzf "$ROOTFS_TAR" -C "$TMP_DIR"

cat > "$TMP_DIR/init" << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo "=== Firecracker MicroVM 启动成功 ==="
echo "Alpine Linux microVM 正在运行"
echo ""
exec /bin/sh
EOF
chmod +x "$TMP_DIR/init"

mke2fs -t ext4 -d "$TMP_DIR" -L rootfs "$ROOTFS_IMG" 128M 2>&1 | tail -2
rm -rf "$TMP_DIR"

echo "✓ rootfs 镜像已创建: $ROOTFS_IMG"
ls -lh "$ROOTFS_IMG"