#!/bin/bash
# 在 Linux 容器内构建 libflclash.so（mihomo 内核 for HarmonyOS）
#
# 背景：go-ohos 工具链 fork（gitee wefuture/golang_go @ feature/tlsgd_mode_support）
# 重写了 src/runtime/tls_arm64.s（OHOS/musl TLS GD 模式），darwin 下无条件执行该路径，
# 因此 macOS 上无法编译/运行 go-ohos，必须在 Linux 主机（或容器）内构建。
#
# 前置条件（宿主机，一次性准备，挂载到容器 /build）：
#   /build/go-ohos/                        go-ohos 工具链源码（gitee wefuture/golang_go, feature/tlsgd_mode_support）
#   /build/go1.24.6.linux-arm64.tar.gz     bootstrap Go（linux）
#   /build/ohos-sysroot/                   OHOS NDK sysroot（自 DevEco .../native/sysroot 复制）
#   /build/ohos-ndk-lib/                   crtbeginS.o/crtendS.o/libclang_rt.builtins.a/libunwind.a
#                                         （自 DevEco .../native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos 复制，
#                                          crtbeginS.o=clang_rt.crtbegin.o，crtendS.o=clang_rt.crtend.o）
#   /build/build-core-in-linux.sh          本脚本
#
# 运行（macOS + colima；colima 默认仅挂载 home 目录）：
#   docker run --rm \
#     -v ~/clashbox-build:/build \
#     -v ~/Desktop/openGit/ClashBox:/clashbox \
#     docker.m.daocloud.io/library/ubuntu:24.04 \
#     bash /build/build-core-in-linux.sh
set -e

export DEBIAN_FRONTEND=noninteractive
# 国内网络加速 apt
sed -i 's|http://archive.ubuntu.com|https://mirrors.aliyun.com|g; s|http://security.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null || true
sed -i 's|http://archive.ubuntu.com|https://mirrors.aliyun.com|g; s|http://security.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
apt-get update -qq
apt-get install -y -qq clang lld git ca-certificates > /dev/null
echo "[OK] clang: $(clang --version | head -1)"

# 1. 解压 linux bootstrap go
if [ ! -x /build/go-bootstrap-linux/bin/go ]; then
  mkdir -p /build/go-bootstrap-linux
  tar -xzf /build/go1.24.6.linux-arm64.tar.gz -C /build/go-bootstrap-linux --strip-components=1
fi

# 2. 构建 go-ohos 工具链 (linux/arm64)
if [ ! -x /build/go-ohos/bin/go ]; then
  echo "[INFO] Building go-ohos toolchain (this takes a few minutes)..."
  export GOROOT_BOOTSTRAP=/build/go-bootstrap-linux
  cd /build/go-ohos/src
  ./make.bash
fi
export GOROOT=/build/go-ohos
export PATH=$GOROOT/bin:$PATH
echo "[OK] go-ohos: $(go version)"

export GOPROXY=https://goproxy.cn,direct
export GOTOOLCHAIN=local
export GOCACHE=/build/gocache
export GOMODCACHE=/build/gomodcache

# 3. 更新依赖
cd /clashbox/proxy_core/src/flclash
go mod tidy
echo "[OK] go mod tidy done"

# 3.5 幂等应用 OHOS 补丁（补丁文件保存在 patches/ 目录）
apply_patch() { # $1=submodule-dir $2=patch-file
  if (cd "$1" && git apply --check "$2" >/dev/null 2>&1); then
    (cd "$1" && git apply "$2")
    echo "[OK] applied $(basename "$2")"
  else
    echo "[SKIP] $(basename "$2") (already applied or not applicable)"
  fi
}
apply_patch gvisor-ohos patches/gvisor-ohos-fstat-fix.patch
apply_patch core patches/core-dns-ohos.patch
apply_patch core patches/core-iface-ohos.patch

# 4. 构建共享库
# Ubuntu clang 缺少 OHOS CRT/运行时对象，安装到工具链自身搜索目录
# （clang 的 GetFilePath 不搜索 -L 路径）
LLVM_TRIPLE_LIB=/usr/lib/llvm-18/lib/aarch64-linux-ohos
RT_DIR=/usr/lib/llvm-18/lib/clang/18/lib/aarch64-linux-ohos
mkdir -p "$LLVM_TRIPLE_LIB" "$RT_DIR"
cp -n /build/ohos-ndk-lib/crtbeginS.o /build/ohos-ndk-lib/crtendS.o "$LLVM_TRIPLE_LIB/" 2>/dev/null || true
cp -n /build/ohos-ndk-lib/libclang_rt.builtins.a "$RT_DIR/" 2>/dev/null || true
export GOOS=linux
export GOARCH=arm64
export CGO_ENABLED=1
export CC=clang
export CGO_CFLAGS="-Wno-error --target=aarch64-linux-ohos --sysroot=/build/ohos-sysroot"
export CGO_LDFLAGS="--sysroot=/build/ohos-sysroot --target=aarch64-linux-ohos -L/build/ohos-ndk-lib"
go build -tlsmodegd -buildmode c-shared -tags "ohos with_gvisor" -o libflclash.so .
cp -f libflclash.so /clashbox/proxy_core/libs/arm64-v8a/libflclash.so
echo "[BUILD SUCCESS] libflclash.so -> /clashbox/proxy_core/libs/arm64-v8a/"
ls -lh /clashbox/proxy_core/libs/arm64-v8a/libflclash.so
