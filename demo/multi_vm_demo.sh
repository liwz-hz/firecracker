#!/bin/bash
# 多 microVM 管理演示
# 用法: ./multi_vm_demo.sh [start|stop|status|list]

set -e

VM_COUNT=${VM_COUNT:-3}
DEMO_DIR="/home/lmm/github_test/firecracker/demo"
FC_BIN="$DEMO_DIR/release-v1.10.0-x86_64/firecracker-v1.10.0-x86_64"
KERNEL="$DEMO_DIR/vmlinux-ci"
ROOTFS="$DEMO_DIR/alpine-rootfs.img"

start_vms() {
    echo "=== 启动 $VM_COUNT 台 microVM ==="
    echo ""

    for i in $(seq 1 $VM_COUNT); do
        local socket="/tmp/fc-$i.sock"
        local pidfile="/tmp/fc-$i.pid"

        if [ -S "$socket" ]; then
            echo "⚠ VM #$i 已存在，跳过"
            continue
        fi

        echo "启动 VM #$i..."

        $FC_BIN --api-sock "$socket" &
        local pid=$!
        echo $pid > "$pidfile"
        sleep 0.3

        curl -s --unix-socket "$socket" -X PUT http://localhost/boot-source \
            -d "{\"kernel_image_path\": \"$KERNEL\", \"boot_args\": \"console=ttyS0 reboot=k panic=1 init=/init\"}"

        curl -s --unix-socket "$socket" -X PUT http://localhost/drives/rootfs \
            -d "{\"drive_id\": \"rootfs\", \"path_on_host\": \"$ROOTFS\", \"is_root_device\": true, \"is_read_only\": false}"

        curl -s --unix-socket "$socket" -X PUT http://localhost/machine-config \
            -d '{"vcpu_count": 1, "mem_size_mib": 128}'

        curl -s --unix-socket "$socket" -X PUT http://localhost/actions \
            -d '{"action_type": "InstanceStart"}'

        echo "✓ VM #$i 已启动 (PID: $pid)"
    done

    echo ""
    echo "总计启动 $VM_COUNT 台 microVM"
    list_vms
}

stop_vms() {
    echo "=== 停止所有 microVM ==="
    echo ""

    for i in $(seq 1 $VM_COUNT); do
        local pidfile="/tmp/fc-$i.pid"
        local socket="/tmp/fc-$i.sock"

        if [ -f "$pidfile" ]; then
            local pid=$(cat "$pidfile")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid"
                echo "✓ VM #$i 已停止 (PID: $pid)"
            fi
            rm -f "$pidfile" "$socket"
        fi
    done

    pkill -9 firecracker 2>/dev/null || true
    rm -f /tmp/fc-*.sock /tmp/fc-*.pid

    echo ""
    echo "✓ 所有 VM 已停止"
}

status_vms() {
    echo "=== microVM 状态 ==="
    echo ""

    for i in $(seq 1 $VM_COUNT); do
        local socket="/tmp/fc-$i.sock"

        if [ -S "$socket" ]; then
            local status=$(curl -s --unix-socket "$socket" http://localhost/ 2>/dev/null)
            if [ $? -eq 0 ]; then
                local state=$(echo "$status" | python3 -c "import sys, json; print(json.load(sys.stdin)['state'])" 2>/dev/null || echo "Unknown")
                echo "VM #$i: $state"
            else
                echo "VM #$i: 无响应"
            fi
        else
            echo "VM #$i: 未运行"
        fi
    done
}

list_vms() {
    echo ""
    echo "=== 运行中的 microVM 进程 ==="
    echo ""

    ps aux | grep firecracker | grep -v grep | awk 'NR==1 || /firecracker/ {
        printf "%-6s %-6s %-6s %-10s %s\n", "PID", "CPU", "MEM", "SOCKET", "COMMAND"
        printf "%-6s %-5s%% %-5s%% %-10s %s\n", $2, $3, $4, "", $11
        exit
    }'

    echo ""
    ps aux | grep firecracker | grep -v grep | awk '{printf "PID %-6s: CPU %-5s%%  MEM %-5s%%  Socket: /tmp/fc-%s.sock\n", $2, $3, $4, NR}'

    echo ""
    local total=$(ps aux | grep firecracker | grep -v grep | wc -l)
    local mem=$(ps aux | grep firecracker | grep -v grep | awk '{sum+=$6} END {printf "%.1f", sum/1024}')
    echo "总计: $total 台 VM，占用内存: ${mem} MB"
}

case "$1" in
    start)
        start_vms
        ;;
    stop)
        stop_vms
        ;;
    status)
        status_vms
        ;;
    list)
        list_vms
        ;;
    *)
        echo "用法: $0 {start|stop|status|list}"
        echo ""
        echo "环境变量:"
        echo "  VM_COUNT=3  启动的 VM 数量（默认 3）"
        echo ""
        echo "示例:"
        echo "  VM_COUNT=5 $0 start   # 启动 5 台 VM"
        echo "  $0 status              # 查看状态"
        echo "  $0 stop                # 停止所有 VM"
        exit 1
        ;;
esac