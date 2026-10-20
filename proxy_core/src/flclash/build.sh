#!/bin/bash
# 构建 libflclash.so (HarmonyOS mihomo 内核)
#
# ⚠️ 前置条件（一次性，详见仓库 README / docs）：
#   1. git submodule update --init --recursive          # core / gvisor-ohos / xb_components
#   2. 准备 go-ohos 工具链（gitee wefuture/golang_go @ feature/tlsgd_mode_support，Linux 主机构建）
#   3. 准备 Linux x86_64/arm64 容器环境（go-ohos 的 tls_arm64.s 改动导致 macOS 无法编译运行）
#
# 本脚本在 Linux 容器内运行（推荐方式），或在本机 Linux + go-ohos 工具链下运行。
# 默认从环境变量读取 go-ohos 路径：GO_OHOS_HOME（默认 /build/go-ohos）
#
# 参考容器命令（macOS + colima）：
#   docker run --rm \
#     -v ~/clashbox-build:/build \
#     -v <仓库根目录>:/clashbox \
#     docker.m.daocloud.io/library/ubuntu:24.04 \
#     bash /build/build-core-in-linux.sh
# （完整脚本见 ~/clashbox-build/build-core-in-linux.sh 或仓库 docs）

set -e

# go-ohos 工具链位置（容器内为 /build/go-ohos）
GO_OHOS_HOME="${GO_OHOS_HOME:-/build/go-ohos}"

# OHOS sysroot 位置（容器内为 /build/ohos-sysroot；本机 Linux 可指向 DevEco 的 sysroot）
OHOS_SYSROOT="${OHOS_SYSROOT:-/build/ohos-sysroot}"

# OHOS CRT/运行时补充目录（crtbeginS.o / crtendS.o / libclang_rt.builtins.a / libunwind.a）
OHOS_NDK_LIB="${OHOS_NDK_LIB:-/build/ohos-ndk-lib}"

arch="arm64"          # 可选值：amd64, arm64
target="aarch64"      # 可选值：x86_64, aarch64
outdir="arm64-v8a"    # 可选值：x86_64, arm64-v8a

export CC=clang
export GOOS="linux"
export GOARCH="$arch"
export GOARM=""
export CGO_ENABLED="1"
export CGO_CFLAGS="-Wno-error --target=$target-linux-ohos --sysroot=$OHOS_SYSROOT"
export CGO_LDFLAGS="--sysroot=$OHOS_SYSROOT --target=$target-linux-ohos -L$OHOS_NDK_LIB"

# 应用 OHOS 补丁（幂等）
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

outputFile="libflclash.so"
"$GO_OHOS_HOME/bin/go" build -tlsmodegd -buildmode c-shared -tags "ohos with_gvisor" -o "$outputFile" .

cp -f "$outputFile" "$PWD/../../libs/$outdir/$outputFile"
rm -f "$outputFile"
echo "success: libs/$outdir/$outputFile"

# ubex > gvisor@v0.0-20240320004321-933faba989ec > pkg>tcpip>link >fdbased>~60 endpoint.go
 #isSocketFD
