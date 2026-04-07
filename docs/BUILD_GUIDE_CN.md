# Firecracker 构建指南

本文档详细介绍如何从源码构建 Firecracker，包括两种构建方法：本地 Rust 构建和 Docker/devtool 构建。

## 构建成果

成功构建后会生成以下二进制文件：

### musl 构建（静态链接，生产环境推荐）

| 二进制文件 | 说明 | 大小 | 链接类型 |
|-----------|------|------|---------|
| `firecracker` | Firecracker VMM 主程序 | 3.3MB | static-pie |
| `jailer` | 安全隔离包装器 | 2.1MB | static-pie |
| `seccompiler-bin` | seccomp 规则编译器 | 1.2MB | static-pie |
| `cpu-template-helper` | CPU 模板辅助工具 | 2.4MB | static-pie |
| `snapshot-editor` | 快照编辑工具 | 1.1MB | static-pie |
| `rebase-snap` | 快照重定位工具 | 488KB | static-pie |
| `clippy-tracing` | 代码检查工具 | 3.4MB | static-pie |

构建产物路径：`build/cargo_target/x86_64-unknown-linux-musl/release/`

### glibc 构建（动态链接，开发环境）

| 二进制文件 | 说明 | 大小 | 链接类型 |
|-----------|------|------|---------|
| `firecracker` | Firecracker VMM 主程序 | 4.7MB | dynamic |
| `seccompiler-bin` | seccomp 规则编译器 | 2.4MB | dynamic |
| `cpu-template-helper` | CPU 模板辅助工具 | 4.0MB | dynamic |
| `snapshot-editor` | 快照编辑工具 | 2.5MB | dynamic |
| `rebase-snap` | 快照重定位工具 | 1.8MB | dynamic |
| `clippy-tracing` | 代码检查工具 | 3.5MB | dynamic |

构建产物路径：`build/cargo_target/release/`

**注意**：glibc 构建不会生成 `jailer`，因为 jailer 仅支持 musl 目标。

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

**原因**：镜像较大（约 4.7GB），网络带宽受限。

**解决方案**：
- 使用本地构建替代
- 配置 Docker 镜像加速器
- 等待镜像拉取完成后再执行构建

---

## 方法三：Docker 缓存构建（加速重复构建）

如果需要多次构建 Firecracker，可以使用缓存镜像避免每次重新下载依赖。此方法将 cargo 依赖缓存到镜像中，后续构建时间从 ~10 分钟缩短至 ~5 分钟。

### 3.1 拉取原始镜像

```bash
# 拉取 Firecracker 官方构建镜像
docker pull public.ecr.aws/firecracker/fcuvm:v88
```

镜像大小约 4.7GB，包含完整的 Rust 工具链和构建环境。

### 3.2 创建缓存镜像

首次构建后，将容器状态保存为新镜像：

```bash
# 1. 首次构建（会下载所有 cargo 依赖）
docker run -d --name fc-build \
    --privileged \
    --workdir /firecracker \
    --volume /dev:/dev \
    --volume $(pwd):/firecracker:z \
    --volume $(pwd)/build/cargo_registry:/usr/local/rust/registry:z \
    --volume $(pwd)/build/cargo_git_registry:/usr/local/rust/git:z \
    --tmpfs /srv:exec,dev,size=32G \
    -v /boot:/boot \
    --env PYTHONDONTWRITEBYTECODE=1 \
    public.ecr.aws/firecracker/fcuvm:v88 \
    bash -c "unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY && ./tools/release.sh --libc musl --profile release"

# 2. 等待构建完成
docker logs -f fc-build

# 3. 将容器提交为缓存镜像
docker commit fc-build firecracker-build:v88-cached

# 4. 清理容器（镜像已保存）
docker rm fc-build
```

### 3.3 使用缓存镜像构建

后续构建直接使用缓存镜像：

```bash
# 使用缓存镜像构建（约 5 分钟）
docker run -d --name fc-build \
    --privileged \
    --workdir /firecracker \
    --volume /dev:/dev \
    --volume $(pwd):/firecracker:z \
    --volume $(pwd)/build/cargo_registry:/usr/local/rust/registry:z \
    --volume $(pwd)/build/cargo_git_registry:/usr/local/rust/git:z \
    --tmpfs /srv:exec,dev,size=32G \
    -v /boot:/boot \
    --env PYTHONDONTWRITEBYTECODE=1 \
    firecracker-build:v88-cached \
    bash -c "unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY && ./tools/release.sh --libc musl --profile release"

# 查看构建日志
docker logs -f fc-build

# 构建完成后清理容器
docker rm fc-build
```

### 3.4 缓存镜像管理

```bash
# 查看可用镜像
docker images | grep firecracker

# 镜像列表示例：
# public.ecr.aws/firecracker/fcuvm:v88          4.68GB  (原始镜像)
# firecracker-build:v88-cached                  4.68GB  (缓存镜像)

# 导出镜像用于迁移
docker save firecracker-build:v88-cached | gzip > firecracker-build-v88-cached.tar.gz

# 导入镜像
docker load < firecracker-build-v88-cached.tar.gz

# 删除缓存镜像（谨慎操作）
docker rmi firecracker-build:v88-cached
```

### 3.5 网络配置说明

#### 代理问题

容器通过 devtool 脚本继承主机的代理环境变量。如果主机使用 `127.0.0.1:端口` 作为代理地址，容器内将无法访问（容器的 localhost 与主机不同）。

**解决方案**：

```bash
# 方案一：构建时清除代理变量（推荐）
docker run ... bash -c "unset http_proxy https_proxy ... && ./tools/release.sh"

# 方案二：使用 Docker 网桥 IP
# 容器内访问主机代理：http://172.17.0.1:端口
# 需要主机代理监听 0.0.0.0 或配置 Docker 网桥
```

#### 主机代理配置

如果主机有多层代理（如 WSL2 + 主机代理），容器内网络请求流程：

```
容器 → Docker 网桥 (172.17.0.1) → 主机代理 → 外网
```

需要确保：
1. 主机代理允许 Docker 网桥 IP 访问
2. 或在容器内禁用代理直连外网

### 3.6 缓存目录说明

构建过程中会在宿主机生成缓存目录：

```
build/
├── cargo_registry/          # crates.io 依赖缓存 (~191MB)
├── cargo_git_registry/      # git 依赖缓存 (~1.1MB)
└── cargo_target/            # 编译产物
    ├── release/             # glibc 构建
    └── x86_64-unknown-linux-musl/release/  # musl 构建
```

**重要**：保留 `cargo_registry` 和 `cargo_git_registry` 目录可加速后续构建。清理 `cargo_target` 目录不会影响缓存。

### 3.7 验证构建产物

```bash
# 检查 musl 构建（静态链接）
./build/cargo_target/x86_64-unknown-linux-musl/release/firecracker --version
# 输出: Firecracker v1.16.0-dev

ldd ./build/cargo_target/x86_64-unknown-linux-musl/release/firecracker
# 输出: statically linked

# 检查 glibc 构建（动态链接）
./build/cargo_target/release/firecracker --version
ldd ./build/cargo_target/release/firecracker
# 输出: 显示动态库依赖列表
```

---

## 构建时间参考

| 构建类型 | 首次构建 | 增量构建 | 说明 |
|---------|---------|---------|------|
| glibc release | ~5-6 分钟 | ~30秒 | 依赖下载+编译 |
| musl release | ~6-8 分钟 | ~30秒 | musl 工具链编译稍慢 |
| Docker devtool（首次） | ~10-15 分钟 | ~1分钟 | 含镜像拉取+依赖下载 |
| Docker 缓存镜像 | ~5 分钟 | ~30秒 | 依赖已缓存，仅编译 |
| Docker 缓存+增量 | ~30秒 | ~30秒 | cargo 编译缓存命中 |

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
| 链接方式 | 动态链接 | 静态链接 (static-pie) |
| 运行依赖 | 需要 glibc 动态库 | 无依赖 |
| jailer | ❌ 不生成 | ✅ 生成 |
| 二进制大小 | 较大 (firecracker 4.7MB) | 较小 (firecracker 3.3MB) |
| 适用场景 | 开发环境 | 生产部署 |
| 启动速度 | 稍慢（动态加载） | 稍快 |
| 部署难度 | 需确保系统有依赖库 | 直接拷贝即可 |

---

## 附录：完整构建脚本

### 本地构建脚本

```bash
#!/bin/bash
# Firecracker 本地构建脚本

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

### Docker 缓存构建脚本

```bash
#!/bin/bash
# Firecracker Docker 缓存构建脚本

set -e

WORKDIR="$(pwd)"
IMAGE_NAME="firecracker-build:v88-cached"
BASE_IMAGE="public.ecr.aws/firecracker/fcuvm:v88"

echo "=== Firecracker Docker 缓存构建 ==="

# 检查缓存镜像是否存在
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "缓存镜像不存在，创建中..."
    
    # 拉取基础镜像
    docker pull "$BASE_IMAGE"
    
    # 首次构建并创建缓存镜像
    docker run -d --name fc-build \
        --privileged \
        --workdir /firecracker \
        --volume /dev:/dev \
        --volume "$WORKDIR:/firecracker:z" \
        --volume "$WORKDIR/build/cargo_registry:/usr/local/rust/registry:z" \
        --volume "$WORKDIR/build/cargo_git_registry:/usr/local/rust/git:z" \
        --tmpfs /srv:exec,dev,size=32G \
        -v /boot:/boot \
        --env PYTHONDONTWRITEBYTECODE=1 \
        "$BASE_IMAGE" \
        bash -c "unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY && ./tools/release.sh --libc musl --profile release"
    
    echo "等待构建完成..."
    docker logs -f fc-build
    
    # 创建缓存镜像
    docker commit fc-build "$IMAGE_NAME"
    docker rm fc-build
    echo "缓存镜像已创建: $IMAGE_NAME"
fi

# 使用缓存镜像构建
echo "使用缓存镜像构建..."
docker run -d --name fc-build \
    --privileged \
    --workdir /firecracker \
    --volume /dev:/dev \
    --volume "$WORKDIR:/firecracker:z" \
    --volume "$WORKDIR/build/cargo_registry:/usr/local/rust/registry:z" \
    --volume "$WORKDIR/build/cargo_git_registry:/usr/local/rust/git:z" \
    --tmpfs /srv:exec,dev,size=32G \
    -v /boot:/boot \
    --env PYTHONDONTWRITEBYTECODE=1 \
    "$IMAGE_NAME" \
    bash -c "unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY && ./tools/release.sh --libc musl --profile release"

echo "等待构建完成..."
docker logs -f fc-build

# 清理容器
docker rm fc-build

# 验证
echo "=== 构建验证 ==="
./build/cargo_target/x86_64-unknown-linux-musl/release/firecracker --version

echo "=== 构建完成 ==="
```

---

## 参考链接

- [Firecracker 官方文档](https://github.com/firecracker-microvm/firecracker/tree/main/docs)
- [Rust 安装指南](https://rustup.rs/)
- [musl-libc](https://musl.libc.org/)
- [Docker 官方文档](https://docs.docker.com/)