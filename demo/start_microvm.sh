#!/bin/bash
# Firecracker microVM 快速启动脚本
# 用法: ./start_microvm.sh

set -e

cd "$(dirname "$0")"

# 检查必要文件
echo "检查必要文件..."
for f in vmlinux-ci alpine-rootfs.img release-v1.10.0-x86_64/firecracker-v1.10.0-x86_64; do
    if [ ! -f "$f" ]; then
        echo "✗ 缺少文件: $f"
        echo "请先按照 QUICKSTART.md 文档准备必要文件"
        exit 1
    fi
done
echo "✓ 所有必要文件存在"

# 检查 KVM 权限
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "✗ 没有 /dev/kvm 访问权限"
    echo "运行: sudo usermod -aG kvm $USER 然后重新登录"
    exit 1
fi
echo "✓ KVM 权限正常"

# 创建/更新配置文件
cat > vm_config.json << 'EOF'
{
  "boot-source": {
    "kernel_image_path": "./vmlinux-ci",
    "boot_args": "console=ttyS0 reboot=k panic=1 init=/init"
  },
  "drives": [{
    "drive_id": "rootfs",
    "path_on_host": "./alpine-rootfs.img",
    "is_root_device": true,
    "is_read_only": false
  }],
  "machine-config": {
    "vcpu_count": 1,
    "mem_size_mib": 256
  }
}
EOF

# 清理旧进程
rm -f /tmp/fc.sock
pkill -9 firecracker 2>/dev/null || true

echo ""
echo "启动 Firecracker microVM..."
echo "输出："
echo "========================================"

./release-v1.10.0-x86_64/firecracker-v1.10.0-x86_64 \
  --api-sock /tmp/fc.sock \
  --config-file vm_config.json

echo "========================================"
echo "microVM 已退出"