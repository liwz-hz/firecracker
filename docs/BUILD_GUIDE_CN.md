# Firecracker 构建指南

本文档详细介绍如何从源码构建 Firecracker，包括两种构建方法：本地 Rust 构建和 Docker/devtool 构建。

## 构建成果

成功构建后会生成以下二进制文件：

| 二进制文件 | 说明 | 大约大小 |
|-----------|------|---------|
| `firecracker` | Firecracker VMM 主程序 | ~5MB |
| `jailer` | 安全隔离包装器（仅 musl 构建） | ~2MB |
| `seccompiler-bin` | seccomp 规则编译器 | ~2.4MB |
| `cpu-template-helper` | CPU 模板辅助工具 | ~4MB |
| `snapshot-editor` | 快照编辑工具 | ~2.5MB |
| `rebase-snap` | 快照重定位工具 | ~1.8MB |

---

## 方法一：本地 Rust 构建（推荐）

本地构建有两种目标：glibc（动态链接）和 musl（静态链接）。

### 1.1 安装依赖

```bash
# 安装 Rust（如果未安装）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env

# 安装构建依赖
sudo apt install -y \
    build-essential \
    clang \
    libclang-dev \
    libseccomp-dev \
    linux-libc-dev \
    musl-tools  # 仅 musl 构建需要

# 安装 Rust 组件
rustup component add rustfmt
```

### 1.2 glibc 构建（动态链接）

glibc 构建生成的二进制依赖系统动态库，适合开发环境使用。

```bash
# 进入仓库目录
cd firecracker

# 构建 release 版本
cargo build --release
```

构建产物位于：
```
build/cargo_target/release/
├── firecracker         # VMM 主程序
├── seccompiler-bin     # seccomp 编译器
├── cpu-template-helper
├── snapshot-editor
├── rebase-snap
└── clippy-tracing
```

**注意**：glibc 构建不会生成 `jailer` 二进制，因为 jailer 仅支持 musl 目标。

### 1.3 musl 构建（静态链接）

musl 构建生成完全静态链接的二进制，适合生产环境部署。

```bash
# 安装 musl 目标
rustup target add x86_64-unknown-linux-musl

# 构建 musl release 版本
cargo build --release --target x86_64-unknown-linux-musl
```

构建产物位于：
```
build/cargo_target/x86_64-unknown-linux-musl/release/
├── firecracker         # VMM 主程序
├── jailer              # 安全隔离包装器
├── seccompiler-bin
├── cpu-template-helper
├── snapshot-editor
└── rebase-snap
```

### 1.4 验证构建

```bash
# 检查版本
./build/cargo_target/release/firecracker --version
# 输出: Firecracker v1.16.0-dev

# 检查依赖（glibc 构建）
ldd ./build/cargo_target/release/firecracker
# 应显示动态库依赖

# 检查依赖（musl 构建）
ldd ./build/cargo_target/x86_64-unknown-linux-musl/release/firecracker
# 应显示 "statically linked" 或无动态依赖
```

---

## 方法二：Docker/devtool 构建

Firecracker 提供了 devtool 脚本，在 Docker 容器中进行标准化构建。

### 2.1 安装 Docker

```bash
# Ubuntu/Debian
sudo apt install -y docker.io
sudo usermod -aG docker $USER
# 重新登录以生效

# 验证 Docker
docker ps
```

### 2.2 使用 devtool 构建

```bash
# 进入仓库目录
cd firecracker

# 构建 release 版本（清除代理设置避免容器网络问题）
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
./tools/devtool build --release
```

构建产物位于：
```
build/cargo_target/x86_64-unknown-linux-musl/release/
```

### 2.3 devtool 其他命令

```bash
# 构建 debug 版本
./tools/devtool build

# 运行测试
./tools/devtool test

# 进入容器 shell（用于调试）
./tools/devtool shell
```

### 2.4 Docker 构建常见问题

#### 问题：容器内网络无法访问 GitHub

**症状**：
```
fatal: unable to access 'https://github.com/...': GnuTLS recv error (-110)
fatal: unable to access 'https://github.com/...': Failed to connect to github.com port 443
```

**原因**：容器继承了主机的代理配置，但代理地址（如 `127.0.0.1:7897`）在容器内不可访问。

**解决方案**：
```bash
# 构建前清除代理环境变量
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
./tools/devtool build --release
```

#### 问题：镜像拉取缓慢

**症状**：Docker pull `public.ecr.aws/firecracker/fcuvm:v88` 超时或极慢。

**原因**：镜像较大（约 2GB），网络带宽受限。

**解决方案**：
- 使用本地构建替代
- 配置 Docker 镜像加速器
- 等待镜像拉取完成后再执行构建

---

## 构建时间参考

| 构建类型 | 首次构建 |增量构建 | 说明 |
|---------|---------|---------|------|
| glibc release | ~5-6 分钟 | ~30秒 | 依赖下载+编译 |
| musl release | ~6-8 分钟 | ~30秒 | musl 工具链编译稍慢 |
| Docker devtool | ~10-15 分钟 | ~1分钟 | 含镜像拉取时间 |

---

## 构建依赖详解

### 必需依赖

| 依赖包 | 说明 | 用途 |
|-------|------|-----|
| `build-essential` | GCC、make 等 | C 代码编译 |
| `clang` / `libclang-dev` | LLVM/Clang | bindgen 生成 Rust FFI |
| `libseccomp-dev` | seccomp 库 | 系统调用过滤 |
| `linux-libc-dev` | Linux内核头文件 | 内核 API 定义 |

### musl 构建额外依赖

| 依赖包 | 说明 |
|-------|------|
| `musl-tools` | musl C 工具链（x86_64-linux-musl-gcc） |

### Rust 工具链

Firecracker 要求特定 Rust 版本：
- 查看 `src/firecracker/Cargo.toml` 或运行 `cargo pkgid`
- 当前版本：Rust 1.93.0

---

## 生产环境部署建议

1. **使用 musl 构建**：静态链接，无运行时依赖
2. **使用 jailer**：提供 chroot、namespace、cgroup 隔离
3. **使用 seccomp**：限制系统调用，增强安全
4. **参考官方文档**：
   - `docs/prod-host-setup.md` - 生产主机配置
   - `docs/jailer.md` - Jailer 使用指南

---

## 构建产物对比

| 特性 | glibc 构建 | musl 构建 |
|-----|-----------|----------|
| 链接方式 | 动态链接 | 静态链接 |
| 运行依赖 | 需要 glibc | 无依赖 |
| jailer | ❌ 不生成 | ✅ 生成 |
| 二进制大小 | 较小 | 较大 |
| 适用场景 | 开发环境 | 生产部署 |
| 启动速度 | 稍慢（动态加载） | 稍快 |

---

## 附录：完整构建脚本

```bash
#!/bin/bash
# Firecracker 构建脚本

set -e

echo "=== Firecracker 构建脚本 ==="

# 1. 安装依赖
echo "[1/4] 安装系统依赖..."
sudo apt install -y \
    build-essential \
    clang \
    libclang-dev \
    libseccomp-dev \
    linux-libc-dev \
    musl-tools \
    docker.io

# 2. 安装 Rust
echo "[2/4] 安装 Rust..."
if ! command -v cargo &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env
fi
rustup component add rustfmt
rustup target add x86_64-unknown-linux-musl

# 3. glibc 构建
echo "[3/4] glibc 构建..."
cargo build --release
echo "glibc 构建完成: build/cargo_target/release/"

# 4. musl 构建
echo "[4/4] musl 构建..."
cargo build --release --target x86_64-unknown-linux-musl
echo "musl 构建完成: build/cargo_target/x86_64-unknown-linux-musl/release/"

# 验证
echo "=== 构建验证 ==="
./build/cargo_target/release/firecracker --version
./build/cargo_target/x86_64-unknown-linux-musl/release/firecracker --version

echo "=== 构建完成 ==="
```

---

## 参考链接

- [Firecracker 官方文档](https://github.com/firecracker-microvm/firecracker/tree/main/docs)
- [Rust 安装指南](https://rustup.rs/)
- [musl-libc](https://musl.libc.org/)
- [Docker 官方文档](https://docs.docker.com/)