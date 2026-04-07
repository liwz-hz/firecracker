# Firecracker 快照功能技术文档

## 概述

Firecracker 快照功能允许将运行中的 VM 状态保存到磁盘，后续可以从快照快速恢复 VM，跳过完整的内核启动过程。这是实现毫秒级 VM 启动的关键技术。

---

## 技术分析

### 1. 启动方式对比

| 启动方式 | 耗时 | 过程 | 适用场景 |
|---------|------|------|---------|
| 正常启动 | 1-3秒 | Firecracker启动 → 内核初始化 → init → 用户空间 | 首次创建 VM |
| 快照恢复 | 100-200ms | Firecracker启动 → 加载快照 → VM立即恢复 | 预热后的快速启动 |

### 2. 快照原理

**正常启动流程：**
```
┌─────────────────────────────────────────────────────────────┐
│  启动 Firecracker                                          │
│       ↓                                                     │
│  加载 Linux 内核 (vmlinux)                                  │
│       ↓                                                     │
│  内核初始化 (设备、内存、调度器...)     ← 主要耗时          │
│       ↓                                                     │
│  挂载 rootfs                                                │
│       ↓                                                     │
│  启动 init 进程                                             │
│       ↓                                                     │
│  用户空间就绪                                               │
│                                                             │
│  总耗时: 1-3秒                                              │
└─────────────────────────────────────────────────────────────┘
```

**快照恢复流程：**
```
┌─────────────────────────────────────────────────────────────┐
│  启动 Firecracker                                          │
│       ↓                                                     │
│  加载快照文件 (vm.vmstate + vm.mem)                        │
│       ↓                                                     │
│  恢复 CPU 状态、设备状态、内存内容                          │
│       ↓                                                     │
│  VM 立即恢复到暂停时的状态                                  │
│                                                             │
│  总耗时: 100-200ms                                          │
└─────────────────────────────────────────────────────────────┘
```

### 3. 快照文件组成

| 文件 | 大小 | 内容 |
|-----|------|------|
| `vm.vmstate` | ~16KB | VM 状态元数据（CPU寄存器、设备状态） |
| `vm.mem` | VM内存大小 | VM 内存内容（默认128MB → 129MB文件） |

**文件大小与内存配置关系：**
- 128MB 内存 → ~129MB 快照文件
- 256MB 内存 → ~257MB 快照文件
- 快照文件大小 ≈ 内存大小 + 少量元数据

### 4. 快照类型

Firecracker 支持两种快照类型：

| 类型 | 说明 | 适用场景 |
|-----|------|---------|
| Full（完整快照） | 保存完整的 VM 状态和内存 | 首次快照、跨机器迁移 |
| Diff（差异快照） | 仅保存自上次快照后的内存变化 | 连续快照、节省存储空间 |

### 5. API 接口

**创建快照：**
```
PUT /snapshot/create

{
    "snapshot_path": "/path/to/vm.vmstate",
    "mem_file_path": "/path/to/vm.mem",
    "snapshot_type": "Full"
}
```

**加载快照：**
```
PUT /snapshot/load

{
    "snapshot_path": "/path/to/vm.vmstate",
    "mem_backend": {
        "backend_path": "/path/to/vm.mem",
        "backend_type": "File"
    },
    "resume_vm": true
}
```

**关键要求：**
- 创建快照前，VM 必须处于 **Paused** 状态
- 加载快照时，Firecracker 必须是**新启动的进程**（未配置任何 VM）

---

## 操作指导

### 前置条件

1. Firecracker 二进制文件
2. Linux 内核镜像 (vmlinux)
3. Root 文件系统镜像 (rootfs)
4. KVM 权限（/dev/kvm）

### 方式一：使用演示脚本

```bash
cd demo

# 1. 创建快照（正常启动 VM，暂停，保存快照，关闭进程）
./snapshot_demo.sh create

# 2. 从快照恢复（启动新进程，加载快照，VM 立即恢复）
./snapshot_demo.sh restore

# 3. 完整演示（创建 + 恢复 + 时间对比）
./snapshot_demo.sh demo
```

### 方式二：手动操作

#### 步骤 1：正常启动 VM

```bash
# 启动 Firecracker
./firecracker --api-sock /tmp/fc.sock &

# 配置 VM
curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/machine-config' \
    -H 'Content-Type: application/json' \
    -d '{"vcpu_count": 1, "mem_size_mib": 128}'

curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/boot-source' \
    -H 'Content-Type: application/json' \
    -d '{"kernel_image_path": "./vmlinux", "boot_args": "console=ttyS0"}'

curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/drives/rootfs' \
    -H 'Content-Type: application/json' \
    -d '{"drive_id": "rootfs", "path_on_host": "./rootfs.img", "is_root_device": true}'

# 启动 VM
curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/actions' \
    -H 'Content-Type: application/json' \
    -d '{"action_type": "InstanceStart"}'
```

#### 步骤 2：创建快照

```bash
# 暂停 VM（必须先暂停）
curl --unix-socket /tmp/fc.sock -X PATCH 'http://localhost/vm' \
    -H 'Content-Type: application/json' \
    -d '{"state": "Paused"}'

# 创建快照
curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/snapshot/create' \
    -H 'Content-Type: application/json' \
    -d '{
        "snapshot_path": "./snapshots/vm.vmstate",
        "mem_file_path": "./snapshots/vm.mem",
        "snapshot_type": "Full"
    }'

# 关闭 Firecracker 进程
pkill firecracker
```

#### 步骤 3：从快照恢复

```bash
# 启动新的 Firecracker 进程
./firecracker --api-sock /tmp/fc.sock &

# 加载快照
curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/snapshot/load' \
    -H 'Content-Type: application/json' \
    -d '{
        "snapshot_path": "./snapshots/vm.vmstate",
        "mem_backend": {
            "backend_path": "./snapshots/vm.mem",
            "backend_type": "File"
        },
        "resume_vm": true
    }'

# VM 已恢复运行
```

---

## 时间观测

### 测试环境

- CPU: Intel Xeon @ 1.60GHz
- 内存: 128MB
- 内核: Linux 6.1.155+
- RootFS: Alpine Linux (精简版)

### 测试结果

| 启动方式 | 耗时 | 说明 |
|---------|------|------|
| 正常启动 | 3.073秒 | 完整内核启动过程 |
| 快照恢复 | 0.132秒 | 从快照文件恢复 |
| **加速比** | **23.2x** | |

### 时间分解

**正常启动耗时分解：**
```
Firecracker 进程启动:     ~10ms
加载内核镜像:             ~50ms
内核初始化:               ~2000ms    ← 主要耗时
挂载 rootfs:              ~200ms
启动 init:                ~800ms
------------------------------
总计:                     ~3000ms
```

**快照恢复耗时分解：**
```
Firecracker 进程启动:     ~10ms
读取 vm.vmstate:          ~1ms
加载内存快照 (128MB):     ~100ms     ← 主要耗时
恢复设备状态:             ~10ms
恢复 CPU 状态:            ~1ms
------------------------------
总计:                     ~120ms
```

### 影响因素

**影响快照恢复速度的因素：**

1. **内存大小** - 内存越大，快照文件越大，加载越慢
   - 128MB → ~130ms
   - 256MB → ~200ms
   - 512MB → ~350ms

2. **存储介质** - 快照文件读取速度
   - NVMe SSD: 最快
   - SATA SSD: 较快
   - HDD: 较慢

3. **CPU 性能** - 解析快照元数据

---

## 生产应用

### AWS Lambda 的实现

AWS Lambda 使用 Firecracker 快照实现毫秒级冷启动：

```
┌─────────────────────────────────────────────────────────────┐
│  预热阶段（离线准备）                                        │
│                                                             │
│  1. 为每种运行时创建基础 VM (Python, Node.js, Java...)      │
│  2. 启动 VM，初始化运行时环境                                │
│  3. 暂停 VM，创建快照文件                                    │
│  4. 将快照文件存储到 S3 或本地缓存                           │
│                                                             │
│  此阶段不消耗在线资源                                        │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  在线服务（请求到达时）                                      │
│                                                             │
│  请求到达 →                                                 │
│  1. 从缓存加载对应运行时的快照                               │
│  2. Firecracker 启动 + 加载快照 (~100ms)                    │
│  3. VM 立即可用，执行用户代码                                │
│                                                             │
│  总冷启动时间: ~100-200ms                                    │
└─────────────────────────────────────────────────────────────┘
```

### 最佳实践

1. **快照管理**
   - 按运行时/语言版本分类存储快照
   - 定期更新快照（安全补丁、依赖更新）
   - 使用差异快照减少存储占用

2. **资源优化**
   - 使用最小的内存配置（减少快照大小）
   - 精简 rootfs（减少不必要的包）
   - 使用只读 rootfs（多个 VM 共享）

3. **安全性**
   - 快照文件包含内存内容，需加密存储
   - 定期轮换快照，避免长期使用同一快照

---

## 常见问题

### Q: 快照可以在不同机器间迁移吗？

A: 可以，但需要满足条件：
- 相同 CPU 架构（Intel → Intel, AMD → AMD）
- 相同或兼容的 CPU 特性集
- Firecracker 版本兼容

### Q: 快照恢复后 VM 内的应用状态如何？

A: 完全保留创建快照时的状态：
- 文件系统状态
- 进程状态
- 网络连接（可能需要重新建立）
- 内存中的变量和数据

### Q: 为什么创建快照前必须暂停 VM？

A: Firecracker 需要确保 VM 状态的一致性：
- 暂停会停止所有 vCPU
- 确保内存不再变化
- 设备状态稳定

### Q: 快照恢复时间能更快吗？

A: 可以通过以下方式优化：
- 减少内存配置（更小的快照文件）
- 使用更快的存储（NVMe SSD）
- 使用 UFFD（User Fault FD）延迟加载内存

---

## 参考资料

- [Firecracker 官方文档](https://github.com/firecracker-microvm/firecracker)
- [Firecracker API 规范](../src/firecracker/swagger/firecracker.yaml)
- [快照功能设计文档](../docs/snapshotting)