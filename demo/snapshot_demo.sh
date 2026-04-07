#!/bin/bash
# Firecracker 快照功能演示
# 用法:
#   ./snapshot_demo.sh create  - 创建快照
#   ./snapshot_demo.sh restore - 从快照恢复
#   ./snapshot_demo.sh demo    - 完整演示（创建+恢复+对比）

set -e

cd "$(dirname "$0")"

FIRECRACKER="./release-v1.10.0-x86_64/firecracker-v1.10.0-x86_64"
SOCKET="/tmp/fc-snapshot.sock"
SNAPSHOT_DIR="./snapshots"
KERNEL="./vmlinux-ci"
ROOTFS="./alpine-rootfs.img"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    pkill -9 firecracker 2>/dev/null || true
    rm -f "$SOCKET"
}

check_files() {
    for f in "$FIRECRACKER" "$KERNEL" "$ROOTFS"; do
        if [ ! -f "$f" ]; then
            echo -e "${RED}✗ 缺少文件: $f${NC}"
            exit 1
        fi
    done
}

create_snapshot() {
    echo -e "${GREEN}=== 创建快照 ===${NC}"
    echo ""
    
    check_files
    mkdir -p "$SNAPSHOT_DIR"
    cleanup
    
    echo "1. 启动 Firecracker VM..."
    $FIRECRACKER --api-sock "$SOCKET" &
    FC_PID=$!
    sleep 0.5
    
    echo "2. 配置 VM..."
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/machine-config' \
        -H 'Content-Type: application/json' \
        -d '{"vcpu_count": 1, "mem_size_mib": 128}' 2>/dev/null
    
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/boot-source' \
        -H 'Content-Type: application/json' \
        -d "{\"kernel_image_path\": \"$KERNEL\", \"boot_args\": \"console=ttyS0 reboot=k panic=1 init=/init\"}" 2>/dev/null
    
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/drives/rootfs' \
        -H 'Content-Type: application/json' \
        -d "{\"drive_id\": \"rootfs\", \"path_on_host\": \"$ROOTFS\", \"is_root_device\": true, \"is_read_only\": false}" 2>/dev/null
    
    echo "3. 启动 VM（等待内核启动...）..."
    START=$(date +%s.%N)
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/actions' \
        -H 'Content-Type: application/json' \
        -d '{"action_type": "InstanceStart"}' 2>/dev/null
    
    sleep 3
    END=$(date +%s.%N)
    BOOT_TIME=$(echo "$END - $START" | bc)
    echo -e "${GREEN}✓ VM 启动完成，耗时: ${BOOT_TIME}秒${NC}"
    
    echo ""
    echo "4. 暂停 VM..."
    curl --unix-socket "$SOCKET" -X PATCH 'http://localhost/vm' \
        -H 'Content-Type: application/json' \
        -d '{"state": "Paused"}' 2>/dev/null
    echo -e "${GREEN}✓ VM 已暂停${NC}"
    
    echo ""
    echo "5. 创建快照..."
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/snapshot/create' \
        -H 'Content-Type: application/json' \
        -d "{\"snapshot_path\": \"$SNAPSHOT_DIR/vm.vmstate\", \"mem_file_path\": \"$SNAPSHOT_DIR/vm.mem\", \"snapshot_type\": \"Full\"}" 2>/dev/null
    
    sleep 0.5
    
    if [ -f "$SNAPSHOT_DIR/vm.vmstate" ] && [ -f "$SNAPSHOT_DIR/vm.mem" ]; then
        VMSTATE_SIZE=$(du -h "$SNAPSHOT_DIR/vm.vmstate" | cut -f1)
        MEM_SIZE=$(du -h "$SNAPSHOT_DIR/vm.mem" | cut -f1)
        echo -e "${GREEN}✓ 快照创建成功${NC}"
        echo "  - vm.vmstate: $VMSTATE_SIZE"
        echo "  - vm.mem: $MEM_SIZE"
    else
        echo -e "${RED}✗ 快照创建失败${NC}"
        cleanup
        exit 1
    fi
    
    echo ""
    echo "6. 关闭 Firecracker 进程..."
    kill $FC_PID 2>/dev/null || true
    wait $FC_PID 2>/dev/null || true
    rm -f "$SOCKET"
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}快照已保存到 $SNAPSHOT_DIR/${NC}"
    echo -e "${GREEN}现在运行以下命令体验快照恢复速度:${NC}"
    echo -e "${YELLOW}  ./snapshot_demo.sh restore${NC}"
    echo -e "${GREEN}========================================${NC}"
}

restore_snapshot() {
    echo -e "${GREEN}=== 从快照恢复 ===${NC}"
    echo ""
    
    if [ ! -f "$SNAPSHOT_DIR/vm.vmstate" ] || [ ! -f "$SNAPSHOT_DIR/vm.mem" ]; then
        echo -e "${RED}✗ 快照文件不存在，请先运行: ./snapshot_demo.sh create${NC}"
        exit 1
    fi
    
    cleanup
    
    echo "启动 Firecracker 并加载快照..."
    echo ""
    
    START=$(date +%s.%N)
    
    $FIRECRACKER --api-sock "$SOCKET" &
    FC_PID=$!
    sleep 0.1
    
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/snapshot/load' \
        -H 'Content-Type: application/json' \
        -d "{\"snapshot_path\": \"$SNAPSHOT_DIR/vm.vmstate\", \"mem_backend\": {\"backend_path\": \"$SNAPSHOT_DIR/vm.mem\", \"backend_type\": \"File\"}, \"resume_vm\": true}" 2>/dev/null
    
    END=$(date +%s.%N)
    RESTORE_TIME=$(echo "$END - $START" | bc)
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✓ 快照恢复完成${NC}"
    printf "${GREEN}  耗时: %.3f 秒${NC}\n" $RESTORE_TIME
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}VM 正在运行，按 Ctrl+C 停止${NC}"
    
    trap cleanup EXIT
    wait
}

run_demo() {
    echo -e "${GREEN}=== 完整演示 ===${NC}"
    echo ""
    
    check_files
    mkdir -p "$SNAPSHOT_DIR"
    cleanup
    
    echo -e "${YELLOW}【第一步】正常启动 VM 并创建快照${NC}"
    echo "----------------------------------------"
    
    $FIRECRACKER --api-sock "$SOCKET" &
    FC_PID=$!
    sleep 0.5
    
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/machine-config' \
        -H 'Content-Type: application/json' \
        -d '{"vcpu_count": 1, "mem_size_mib": 128}' 2>/dev/null
    
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/boot-source' \
        -H 'Content-Type: application/json' \
        -d "{\"kernel_image_path\": \"$KERNEL\", \"boot_args\": \"console=ttyS0 reboot=k panic=1 init=/init\"}" 2>/dev/null
    
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/drives/rootfs' \
        -H 'Content-Type: application/json' \
        -d "{\"drive_id\": \"rootfs\", \"path_on_host\": \"$ROOTFS\", \"is_root_device\": true, \"is_read_only\": false}" 2>/dev/null
    
    echo "启动 VM..."
    START=$(date +%s.%N)
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/actions' \
        -H 'Content-Type: application/json' \
        -d '{"action_type": "InstanceStart"}' 2>/dev/null
    
    sleep 3
    END=$(date +%s.%N)
    BOOT_TIME=$(echo "$END - $START" | bc)
    echo -e "${GREEN}✓ VM 启动完成，耗时: ${BOOT_TIME}秒${NC}"
    
    echo "暂停 VM..."
    curl --unix-socket "$SOCKET" -X PATCH 'http://localhost/vm' \
        -H 'Content-Type: application/json' \
        -d '{"state": "Paused"}' 2>/dev/null
    
    echo "创建快照..."
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/snapshot/create' \
        -H 'Content-Type: application/json' \
        -d "{\"snapshot_path\": \"$SNAPSHOT_DIR/vm.vmstate\", \"mem_file_path\": \"$SNAPSHOT_DIR/vm.mem\", \"snapshot_type\": \"Full\"}" 2>/dev/null
    sleep 0.5
    
    echo -e "${GREEN}✓ 快照创建成功${NC}"
    
    echo "关闭原 VM..."
    kill $FC_PID 2>/dev/null || true
    wait $FC_PID 2>/dev/null || true
    rm -f "$SOCKET"
    
    echo ""
    echo -e "${YELLOW}【第二步】从快照恢复 VM${NC}"
    echo "----------------------------------------"
    cleanup
    
    echo "从快照恢复..."
    START=$(date +%s.%N)
    
    $FIRECRACKER --api-sock "$SOCKET" &
    FC_PID=$!
    sleep 0.1
    
    curl --unix-socket "$SOCKET" -X PUT 'http://localhost/snapshot/load' \
        -H 'Content-Type: application/json' \
        -d "{\"snapshot_path\": \"$SNAPSHOT_DIR/vm.vmstate\", \"mem_backend\": {\"backend_path\": \"$SNAPSHOT_DIR/vm.mem\", \"backend_type\": \"File\"}, \"resume_vm\": true}" 2>/dev/null
    
    END=$(date +%s.%N)
    RESTORE_TIME=$(echo "$END - $START" | bc)
    echo -e "${GREEN}✓ 快照恢复完成，耗时: ${RESTORE_TIME}秒${NC}"
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}           启动时间对比${NC}"
    echo -e "${GREEN}========================================${NC}"
    printf "${YELLOW}正常启动:    %.3f 秒${NC}\n" $BOOT_TIME
    printf "${GREEN}快照恢复:    %.3f 秒${NC}\n" $RESTORE_TIME
    SPEEDUP=$(echo "scale=1; $BOOT_TIME / $RESTORE_TIME" | bc)
    echo -e "${GREEN}加速比:      ${SPEEDUP}x${NC}"
    echo ""
    
    kill $FC_PID 2>/dev/null || true
    cleanup
    
    echo -e "${YELLOW}提示: 单独运行以下命令体验快照恢复:${NC}"
    echo -e "${YELLOW}  ./snapshot_demo.sh restore${NC}"
}

usage() {
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  create   - 创建快照（正常启动 VM，暂停，保存快照，关闭进程）"
    echo "  restore  - 从快照恢复（启动进程，加载快照，立即恢复 VM）"
    echo "  demo     - 完整演示（创建快照 + 恢复 + 对比）"
    echo ""
    echo "示例:"
    echo "  $0 create    # 创建快照"
    echo "  $0 restore   # 从快照恢复"
}

case "$1" in
    create)
        create_snapshot
        ;;
    restore)
        restore_snapshot
        ;;
    demo)
        run_demo
        ;;
    *)
        usage
        exit 1
        ;;
esac