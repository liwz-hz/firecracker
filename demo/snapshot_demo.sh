#!/bin/bash
# Firecracker 快照功能演示
# 对比正常启动 vs 快照恢复的启动时间

set -e

cd "$(dirname "$0")"

FIRECRACKER="./release-v1.10.0-x86_64/firecracker-v1.10.0-x86_64"
SOCKET="/tmp/fc-snapshot.sock"
SNAPSHOT_DIR="./snapshots"
KERNEL="./vmlinux-ci"
ROOTFS="./alpine-rootfs.img"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Firecracker 快照功能演示 ===${NC}"
echo ""

# 检查必要文件
for f in "$FIRECRACKER" "$KERNEL" "$ROOTFS"; do
    if [ ! -f "$f" ]; then
        echo -e "${RED}✗ 缺少文件: $f${NC}"
        exit 1
    fi
done

# 创建快照目录
mkdir -p "$SNAPSHOT_DIR"

# 清理旧进程
cleanup() {
    pkill -9 firecracker 2>/dev/null || true
    rm -f "$SOCKET"
}
cleanup

echo -e "${YELLOW}【第一步】正常启动 VM 并创建快照${NC}"
echo "----------------------------------------"

# 启动 VM（API模式，不使用配置文件）
echo "启动 Firecracker VM..."
$FIRECRACKER --api-sock "$SOCKET" &
FC_PID=$!

# 等待 socket 就绪
sleep 0.5

# 配置 VM
echo "配置 VM..."
curl --unix-socket "$SOCKET" -X PUT 'http://localhost/machine-config' \
    -H 'Content-Type: application/json' \
    -d '{
        "vcpu_count": 1,
        "mem_size_mib": 128
    }' 2>/dev/null

curl --unix-socket "$SOCKET" -X PUT 'http://localhost/boot-source' \
    -H 'Content-Type: application/json' \
    -d "{
        \"kernel_image_path\": \"$KERNEL\",
        \"boot_args\": \"console=ttyS0 reboot=k panic=1 init=/init\"
    }" 2>/dev/null

curl --unix-socket "$SOCKET" -X PUT 'http://localhost/drives/rootfs' \
    -H 'Content-Type: application/json' \
    -d "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"$ROOTFS\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }" 2>/dev/null

# 启动 VM
echo "启动 VM 实例..."
START_TIME=$(date +%s.%N)
curl --unix-socket "$SOCKET" -X PUT 'http://localhost/actions' \
    -H 'Content-Type: application/json' \
    -d '{"action_type": "InstanceStart"}' 2>/dev/null

# 等待 VM 完全启动（等待 shell 可用）
echo "等待 VM 启动完成..."
sleep 3
END_TIME=$(date +%s.%N)
BOOT_TIME=$(echo "$END_TIME - $START_TIME" | bc)
echo -e "${GREEN}✓ VM 启动完成，耗时: ${BOOT_TIME}秒${NC}"

# 暂停 VM（快照前必须暂停）
echo ""
echo "暂停 VM..."
curl --unix-socket "$SOCKET" -X PATCH 'http://localhost/vm' \
    -H 'Content-Type: application/json' \
    -d '{"state": "Paused"}' 2>/dev/null
echo -e "${GREEN}✓ VM 已暂停${NC}"

# 创建快照
echo ""
echo "创建快照..."
curl --unix-socket "$SOCKET" -X PUT 'http://localhost/snapshot/create' \
    -H 'Content-Type: application/json' \
    -d "{
        \"snapshot_path\": \"$SNAPSHOT_DIR/vm.vmstate\",
        \"mem_file_path\": \"$SNAPSHOT_DIR/vm.mem\",
        \"snapshot_type\": \"Full\"
    }" 2>/dev/null

sleep 1

# 检查快照文件
if [ -f "$SNAPSHOT_DIR/vm.vmstate" ] && [ -f "$SNAPSHOT_DIR/vm.mem" ]; then
    VMSTATE_SIZE=$(du -h "$SNAPSHOT_DIR/vm.vmstate" | cut -f1)
    MEM_SIZE=$(du -h "$SNAPSHOT_DIR/vm.mem" | cut -f1)
    echo -e "${GREEN}✓ 快照创建成功${NC}"
    echo "  - vm.vmstate: $VMSTATE_SIZE"
    echo "  - vm.mem: $MEM_SIZE (VM内存)"
else
    echo -e "${RED}✗ 快照创建失败${NC}"
    cleanup
    exit 1
fi

# 停止 VM
echo ""
echo "停止原 VM..."
kill $FC_PID 2>/dev/null || true
wait $FC_PID 2>/dev/null || true
rm -f "$SOCKET"

echo ""
echo -e "${YELLOW}【第二步】从快照恢复 VM${NC}"
echo "----------------------------------------"

# 清理，准备恢复
cleanup

echo "从快照恢复..."
START_TIME=$(date +%s.%N)

# 启动 Firecracker（不启动任何VM，只用API）
$FIRECRACKER --api-sock "$SOCKET" &
FC_PID=$!

# 等待 socket 就绪
sleep 0.1

# 通过 API 加载快照
curl --unix-socket "$SOCKET" -X PUT 'http://localhost/snapshot/load' \
    -H 'Content-Type: application/json' \
    -d "{
        \"snapshot_path\": \"$SNAPSHOT_DIR/vm.vmstate\",
        \"mem_backend\": {
            \"backend_path\": \"$SNAPSHOT_DIR/vm.mem\",
            \"backend_type\": \"File\"
        },
        \"resume_vm\": true
    }" 2>/dev/null

END_TIME=$(date +%s.%N)
RESTORE_TIME=$(echo "$END_TIME - $START_TIME" | bc)

echo -e "${GREEN}✓ 快照恢复完成，耗时: ${RESTORE_TIME}秒${NC}"

# 对比结果
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}           启动时间对比${NC}"
echo -e "${GREEN}========================================${NC}"
printf "${YELLOW}正常启动（内核启动）:  %.3f 秒${NC}\n" $BOOT_TIME
printf "${GREEN}快照恢复:             %.3f 秒${NC}\n" $RESTORE_TIME
SPEEDUP=$(echo "scale=1; $BOOT_TIME / $RESTORE_TIME" | bc)
echo -e "${GREEN}加速比:               ${SPEEDUP}x${NC}"
echo ""
echo -e "${YELLOW}提示: 快照恢复了已启动的VM状态，跳过了内核启动过程${NC}"
echo -e "${YELLOW}      VM内存中的shell会话也被保留${NC}"

# 保持 VM 运行，让用户可以交互
echo ""
echo -e "${YELLOW}VM 正在运行，你可以通过以下方式连接:${NC}"
echo "  curl --unix-socket $SOCKET http://localhost/"
echo ""
echo "按 Ctrl+C 停止 VM..."

# 等待用户中断
trap cleanup EXIT
wait