# Firecracker MicroVM 快速启动指南

本文档记录了在 WSL2 环境下成功运行 Firecracker microVM 的完整步骤。每一步都包含详细解释，帮助理解背后的原理。

## 目录

1. [快速启动（推荐）](#快速启动推荐)
2. [背景知识](#背景知识)
3. [前置要求](#前置要求)
4. [准备工作](#准备工作)
5. [步骤详解](#步骤详解)
6. [运行验证](#运行验证)
7. [问题排查](#问题排查)

---

## 快速启动（推荐）

**好消息：仓库已包含运行 demo 所需的大部分文件！**

本仓库 `demo/` 目录已包含：
- ✅ `vmlinux-ci` - Firecracker CI 内核（28MB）
- ✅ `alpine-rootfs.img` - Alpine rootfs 镜像（16MB）
- ✅ `start_microvm.sh` - 启动脚本

**你只需要下载 Firecracker 二进制（约 1MB）：**

```bash
cd demo

# 下载 Firecracker v1.10.0
ARCH="x86_64"
VERSION="v1.10.0"
curl -L https://github.com/firecracker-microvm/firecracker/releases/download/${VERSION}/firecracker-${VERSION}-${ARCH}.tgz | tar -xz

# 重命名目录
mv release-${VERSION}-${ARCH} release-${VERSION}-${ARCH}

# 启动 microVM
./start_microvm.sh
```

看到 `~ #` 提示符即可进入 VM shell 交互！

---

## 背景知识

### 什么是 Firecracker？

Firecracker 是 AWS 开发的开源虚拟化技术，专为 serverless 和容器工作负载设计。它创建轻量级的虚拟机（称为 microVM），结合了：

- **硬件虚拟化的安全性**：每个 microVM 有独立的虚拟化边界
- **容器的速度和灵活性**：极低开销（每个VM仅~5MB内存），毫秒级快照恢复

### 关键概念

1. **microVM**：轻量级虚拟机，没有完整 VM 的多余设备（如显示器、USB）
2. **VMM (Virtual Machine Monitor)**：Firecracker 进程，管理 microVM
3. **virtio**：虚拟化 I/O 设备的标准协议（块设备、网络等）
4. **KVM**：Linux 内核虚拟化模块，提供硬件级虚拟化支持

### 与 Docker 的关系

Firecracker **不是** Docker 的替代品，而是：

- **底层技术**：Docker 容器可以在 Firecracker microVM 中运行（如 Kata Containers）
- **安全隔离**：提供比容器更强的隔离边界
- **不同场景**：适合多租户 serverless，不适合传统容器部署

### 启动时间详解（重要！）

Firecracker 官方指标是 **< 125ms**，但你实际启动时可能看到"几秒"。这需要澄清：

#### 启动时间的两层含义

| 层面 | 时间 | 含义 |
|------|------|------|
| **Firecracker VMM 启动** | **< 125ms** | API调用 → VM开始执行第一条指令 |
| **Guest OS 启动** | **~1-2秒** | Linux内核初始化 → shell可用 |

你看到的"几秒"是 **整个系统启动**，不是 Firecracker 本身的启动时间。

#### 启动流程分解

```
你看到的完整启动流程：

[~100ms]  Firecracker进程启动（毫秒级）
    ↓         ← 这是官方125ms指标的测量范围
[~500ms]  内核解压与早期初始化
    ↓
[~300ms]  设备驱动加载（virtio_blk等）
    ↓
[~200ms]  rootfs挂载（ext4文件系统）
    ↓
[~100ms]  init脚本执行
    ↓
[VM shell可用]

总时间：~1.2-1.5秒
```

**关键点**：Firecracker的125ms指标只包含**第一段**（VMM启动），不包含内核启动。

#### 真正的毫秒级启动：快照恢复

Firecracker 的毫秒级优势体现在 **快照恢复**：

| 启动方式 | 流程 | 时间 |
|---------|------|------|
| **正常启动** | VMM启动 + 内核启动 + rootfs挂载 | ~1.5秒 |
| **快照恢复** | VMM启动 + 加载内存快照 | **< 150ms** |

快照恢复跳过了内核启动阶段，直接恢复已运行的 VM 状态。

#### 生产环境的做法

AWS Lambda / Fargate 等生产环境做法：

```
                    预热池（Warm Pool）
                     ↓
             [已启动的VM + 应用代码]
                     ↓
用户请求 → 从快照恢复 → 立即执行
          (< 100ms)
```

而不是每次请求都从头启动内核。

#### 如何测试 Firecracker 真实启动速度

```bash
cd demo
rm -f /tmp/fc.sock

# 测试 Firecracker 进程启动时间（不含内核）
time ( ./release-v1.10.0-x86_64/firecracker-v1.10.0-x86_64 \
       --api-sock /tmp/fc.sock \
       --config-file vm_config.json & )

# 等待启动后立即 kill
sleep 0.1
pkill firecracker

# 查看输出
# real: ~0.1s = Firecracker进程启动时间
```

#### 优化启动时间的方法

如果追求极致速度：

| 方法 | 效果 | 适用场景 |
|------|------|---------|
| 使用快照恢复 | **< 150ms** | Serverless生产环境 |
| 减小内核（裁剪驱动） | ~0.3秒 | 自定义内核 |
| 减小 rootfs（32MB） | ~0.1秒 | 极简镜像 |
| 禁用串口输出 | ~0.05秒 | 生产环境（不方便调试） |
| VM预热池 | **0ms**（直接可用） | 高并发场景 |

**结论**：
- Firecracker 启动确实是毫秒级（~100ms）
- Linux 内核启动是秒级（~1秒），这才是你看到的"慢"
- 真正的毫秒级启动需要 **快照恢复** 或 **预热池**

---

## 前置要求

### 系统要求

- Linux 环境（本指南基于 WSL2，内核 >= 5.10）
- KVM 支持：检查 `/dev/kvm` 是否存在

### 权限要求

```bash
# 检查 KVM 设备
ls -l /dev/kvm
# 输出应类似：crw-rw-rw- 1 root kvm 10, 232 ...

# 检查是否有读写权限
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "OK" || echo "需要配置权限"
```

如果权限不足，添加用户到 kvm 组：

```bash
sudo usermod -aG kvm $USER
# 然后重新登录使组权限生效
```

---

## 准备工作

### 目录结构

```bash
mkdir -p demo
cd demo
```

我们将使用以下文件：

| 文件 | 来源 | 用途 | 仓库包含 |
|------|------|------|---------|
| `firecracker` | 官方 release | VMM 二进制程序 | ❌ 需下载 |
| `vmlinux-ci` | Firecracker CI | 专为 microVM 编译的内核 | ✅ 已包含 |
| `alpine-rootfs.img` | 本仓库 | Alpine rootfs 镜像 | ✅ 已包含 |
| `start_microvm.sh` | 本仓库 | 启动脚本 | ✅ 已包含 |

**只需下载 Firecracker 二进制，其他文件已准备就绪！**

---

## 步骤详解

### 步骤 1：获取 Firecracker 二进制

**操作**：下载官方预编译版本

```bash
ARCH="x86_64"
release_url="https://github.com/firecracker-microvm/firecracker/releases"
latest=$(basename $(curl -fsSLI -o /dev/null -w %{url_effective} ${release_url}/latest))

# 下载并解压
curl -L ${release_url}/download/${latest}/firecracker-${latest}-${ARCH}.tgz | tar -xz

# 重命名目录为 release
mv release-${latest}-${ARCH} release-${latest}-${ARCH}
```

**解释**：

- **为什么下载预编译版本？**
  - 源码编译需要 Docker + Rust 环境，耗时较长
  - 预编译版本经过官方测试，更稳定
  
- **二进制包含什么？**
  - `firecracker`：VMM 主程序
  - `jailer`：安全隔离工具（生产环境用）

**验证**：

```bash
./release-*/firecracker-* --version
# 输出：Firecracker v1.10.0
```

---

### 步骤 2：获取正确的内核镜像

> **✅ 已包含在仓库！** `demo/vmlinux-ci` 文件已存在，可直接跳过此步骤。
> 
> 如需使用其他版本内核，请参考下方说明。

**这是关键步骤！普通内核无法在 Firecracker 中启动。**

#### 为什么需要特殊内核？

Firecracker microVM 需要内核包含特定配置：

| 配置项 | x86_64 要求 | 作用 |
|--------|-------------|------|
| `CONFIG_VIRTIO_BLK` | 必须 (=y) | virtio 块设备驱动 |
| `CONFIG_ACPI` | 必须 (=y) | 系统设备发现机制 |
| `CONFIG_PCI` | 必须 (=y) | 设备总线支持 |
| `CONFIG_KVM_GUEST` | 必须 (=y) | KVM 客户端优化 |
| `CONFIG_SERIAL_8250_CONSOLE` | 推荐 (=y) | 串口输出 |

**普通 Linux 内核（如 Alpine vmlinuz）的问题**：
- 可能缺少 `CONFIG_VIRTIO_BLK=y`（virtio 块设备驱动）
- 可能缺少 Firecracker 特定的 ACPI 配置
- 导致内核无法识别虚拟块设备，报错：`VFS: Unable to mount root fs on unknown-block(0,0)`

#### 操作：下载 Firecracker CI 内核

```bash
ARCH="x86_64"
release_url="https://github.com/firecracker-microvm/firecracker/releases"
latest_version=$(basename $(curl -fsSLI -o /dev/null -w %{url_effective} ${release_url}/latest))
CI_VERSION=${latest_version%.*}

# 查找最新的 CI 内核
latest_kernel_key=$(curl "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI_VERSION/$ARCH/vmlinux-&list-type=2" \
    | grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
    | sort -V | tail -1)

# 下载内核（已经是 ELF 格式，无需转换）
wget "https://s3.amazonaws.com/spec.ccfc.min/${latest_kernel_key}" -O vmlinux-ci
```

**解释**：

- **为什么用 CI 内核？**
  - Firecracker 团队专门为 microVM 编译
  - 包含所有必要配置，确保兼容性
  - 已是 ELF 格式，直接可用
  
- **vmlinux vs vmlinuz？**
  - `vmlinuz`：压缩的内核镜像（bzImage），需要解压
  - `vmlinux`：未压缩的 ELF 格式，Firecracker 直接使用
  - CI 内核已经是 `vmlinux` 格式

**验证**：

```bash
file vmlinux-ci
# 输出：ELF 64-bit LSB executable, x86-64...

ls -lh vmlinux-ci
# 约 42MB（包含所有驱动）
```

---

### 步骤 3：准备 rootfs（根文件系统）

> **✅ 已包含在仓库！** `demo/alpine-rootfs.img` 文件已存在，可直接跳过此步骤。
> 
> 如需自定义 rootfs（如添加软件包），请参考下方说明。

#### 什么是 rootfs？

rootfs 是 microVM 启动后看到的根目录，包含：
- `/bin`, `/sbin`：可执行程序
- `/etc`：配置文件
- `/lib`：库文件
- `/init`：启动脚本（**关键！**）

#### 操作：创建 ext4 格式的 rootfs

```bash
# 下载 Alpine 最小化 rootfs（约 3MB）
wget https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.0-x86_64.tar.gz -O alpine-rootfs.tar.gz

# 解压到临时目录
mkdir -p /tmp/rootfs-content
tar -xzf alpine-rootfs.tar.gz -C /tmp/rootfs-content

# 创建 init 脚本（重要！）
cat > /tmp/rootfs-content/init << 'EOF'
#!/bin/sh
# 挂载必要的虚拟文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "=== Firecracker MicroVM 启动成功 ==="
echo "Alpine Linux microVM 正在运行"
echo ""
echo "输入命令进行交互，输入 'exit' 退出"

# 启动交互式 shell
exec /bin/sh
EOF
chmod +x /tmp/rootfs-content/init

# 创建 ext4 格式的磁盘镜像
mke2fs -t ext4 -d /tmp/rootfs-content -L rootfs alpine-rootfs.img 128M
```

**解释**：

- **为什么用 Alpine？**
  - 极小（约 3MB），适合 demo
  - 包含 busybox，提供基本 shell 命令
  
- **为什么需要 /init 脚本？**
  - 内核启动后执行第一个程序 `/init`
  - 必须挂载 `/proc`, `/sys`, `/dev` 才能正常运行
  - 最后 `exec /bin/sh` 提供交互 shell
  
- **为什么用 ext4 格式？**
  - Firecracker 要求 ext4 格式的块设备
  - `mke2fs -d` 直接从目录创建，比手动复制更可靠

**验证**：

```bash
# 检查镜像内容
debugfs alpine-rootfs.img -R "ls /" 2>/dev/null
# 应看到：bin, dev, etc, init, lib, ...

ls -lh alpine-rootfs.img
# 应为 128MB
```

---

### 步骤 4：配置 Firecracker

#### Firecracker 的启动方式

Firecracker 支持两种配置方式：

1. **API socket 方式**：通过 HTTP API 动态配置（适合自动化）
2. **配置文件方式**：一次性配置后启动（适合简单 demo）

我们使用配置文件方式，更直观。

#### 操作：创建配置文件

```bash
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
```

**解释**：

- **boot-source**：内核配置
  - `kernel_image_path`：内核文件路径
  - `boot_args`：内核启动参数
    - `console=ttyS0`：输出到串口（这样我们能看到输出）
    - `reboot=k`：重启时关闭 VM（而不是真的重启）
    - `panic=1`：内核 panic 后 1 秒重启
    - `init=/init`：指定启动脚本
  
- **drives**：块设备配置
  - `is_root_device: true`：这是根设备（内核会挂载为 `/`）
  - `is_read_only: false`：可读写
  
- **machine-config**：虚拟机配置
  - `vcpu_count: 1`：1 个虚拟 CPU
  - `mem_size_mib: 256`：256 MB 内存

**注意**：`root=/dev/vda rw` 参数由 Firecracker 自动添加，无需手动指定。

---

### 步骤 5：启动 microVM

#### 操作：运行 Firecracker

```bash
# 清理旧的 socket 文件（如果存在）
rm -f /tmp/fc.sock

# 启动 Firecracker
./release-*/firecracker-* \
  --api-sock /tmp/fc.sock \
  --config-file vm_config.json
```

**解释**：

- **--api-sock**：指定 API socket 路径（即使用配置文件启动，也需要指定）
- **--config-file**：读取配置文件并启动 microVM
- **前台运行**：直接看到内核启动输出

#### 预期输出

```
Running Firecracker v1.10.0
[    0.000000] Linux version 6.1.155+ ...
[    1.200000] virtio_blk virtio0: [vda] 262144 512-byte logical blocks
[    1.800000] EXT4-fs (vda): mounted filesystem
[    1.860000] Run /init as init process
=== Firecracker MicroVM 启动成功 ===
Alpine Linux microVM 正在运行

~ #
```

看到 `~ #` 提示符说明成功进入 shell！

---

## 运行验证

### 成功标志

1. **内核启动日志**：看到 Linux version 和设备初始化
2. **块设备识别**：`virtio_blk virtio0: [vda]` 表示识别到 rootfs
3. **rootfs 挂载**：`EXT4-fs (vda): mounted filesystem`
4. **init 执行**：`Run /init as init process`
5. **进入 shell**：看到 `=== Firecracker MicroVM 启动成功 ===` 和 `~ #` 提示符

### 可执行的命令

在 microVM shell 中可以运行：

```bash
# 查看系统信息
uname -a
cat /proc/version

# 查看挂载
mount

# 查看内存
free -m

# 退出
exit
# 或
reboot
```

---

## 问题排查

### 问题 1：Kernel panic - Unable to mount root fs

**症状**：
```
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

**原因**：内核缺少 virtio 块设备驱动

**解决**：使用 Firecracker CI 内核（`vmlinux-ci`），不要用普通 Linux 内核

### 问题 2：can't run '/sbin/openrc'

**症状**：
```
Run /sbin/init as init process
can't run '/sbin/openrc': No such file or directory
```

**原因**：Alpine 的 `/sbin/init` 尝试启动 openrc，但 mini rootfs 不包含完整 init 系统

**解决**：创建自定义 `/init` 脚本，直接启动 shell

### 问题 3：Permission denied on /dev/kvm

**症状**：
```
Error: FailedToOpenKvm: Permission denied
```

**原因**：用户没有 KVM 访问权限

**解决**：
```bash
sudo usermod -aG kvm $USER
# 重新登录
```

### 问题 4：Serial output buffered/delayed

**症状**：看不到实时输出

**解决**：这是正常的，串口输出可能有延迟。等待几秒后应能看到完整输出。

---

## 清理

### 清理临时文件

```bash
# 删除临时 rootfs 解压目录
rm -rf /tmp/rootfs-content

# 删除旧的 socket 文件
rm -f /tmp/fc.sock

# 如果需要重新构建，删除 rootfs 镜像
rm -f alpine-rootfs.img vm_config.json
```

### 保留的文件

建议保留以下文件供下次使用：

| 文件 | 大小 | 说明 |
|------|------|------|
| `release-*/` | ~1MB | Firecracker 二进制（需下载） |
| `vmlinux-ci` | ~28MB | CI 内核（仓库已包含） |
| `alpine-rootfs.img` | ~16MB | rootfs 镜像（仓库已包含） |

---

## 附录：完整复现脚本

### 简化版（仓库已有内核和 rootfs）

以下是简化版脚本，只需下载 Firecracker 二进制：

```bash
#!/bin/bash
set -e

echo "=== Firecracker MicroVM 快速启动 ==="

cd /home/lmm/github_test/firecracker/demo

# 步骤 1：下载 Firecracker（如果不存在）
echo "1. 检查 Firecracker..."
if [ ! -d release-v1.10.0-x86_64 ]; then
    echo "   下载 Firecracker v1.10.0..."
    ARCH="x86_64"
    VERSION="v1.10.0"
    curl -L https://github.com/firecracker-microvm/firecracker/releases/download/${VERSION}/firecracker-${VERSION}-${ARCH}.tgz | tar -xz
    mv release-${VERSION}-${ARCH} release-${VERSION}-${ARCH}
    echo "   ✓ Firecracker 已下载"
else
    echo "   ✓ Firecracker 已存在，跳过"
fi

# 步骤 2：创建配置
echo "2. 创建配置文件..."
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
echo "   ✓ 配置已创建"

# 步骤 3：启动
echo "3. 启动 Firecracker..."
rm -f /tmp/fc.sock
echo "   输出如下："
echo "========================================"

./release-v1.10.0-x86_64/firecracker-v1.10.0-x86_64 \
  --api-sock /tmp/fc.sock \
  --config-file vm_config.json

echo "========================================"
echo "microVM 已退出"
```

使用方法：

```bash
chmod +x setup_and_run.sh
./setup_and_run.sh
```

---

## 总结

成功运行 Firecracker microVM 的关键：

1. **使用正确的内核**：Firecracker CI 内核，包含必要驱动
2. **正确的 rootfs**：ext4 格式 + 自定义 `/init` 脚本
3. **正确的启动参数**：`console=ttyS0` + `init=/init`
4. **KVM 权限**：确保可以访问 `/dev/kvm`

---

## 仓库已包含的文件

为了方便快速体验，本仓库已预置以下文件：

| 文件 | 大小 | 说明 |
|------|------|------|
| `demo/vmlinux-ci` | 28MB | Firecracker CI 内核 |
| `demo/alpine-rootfs.img` | 16MB | Alpine rootfs 镜像 |
| `demo/start_microvm.sh` | 1.5KB | 启动脚本 |
| `demo/QUICKSTART.md` | 本文档 | 快速启动指南 |

**只需下载 Firecracker 二进制（~1MB）即可运行 demo！**

遵循本文档步骤，应该能在 **1 分钟内** 成功启动 Firecracker microVM！