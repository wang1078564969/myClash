# ClashBox

#### 介绍

ClashBox是一个HarmonyOS NEXT(OpenHarmony)平台的代理软件，内核基于 [FlClash](https://github.com/chen08209/ClashMeta)（mihomo）+ OHOS 补丁

注意：本仓库仅包含前端部分，改版的后端部分暂不开源

#### 食用方法

需要使用Auto-installer(https://github.com/likuai2010/auto-installer/)进行安装

#### 编译内核（proxy_core/src/flclash）

内核为 mihomo（FlClash 分支）cgo 编译产物 `libflclash.so`，需使用 [go-ohos](https://gitee.com/wefuture/golang_go)（`feature/tlsgd_mode_support` 分支）工具链在 **Linux** 环境（或容器）内构建：

```bash
git submodule update --init --recursive
bash build-in-container.sh   # 详见脚本头部注释（colima/docker 容器方式）
```

涉及三处 OHOS 补丁（保存在 `patches/`，构建脚本幂等应用）：
- `gvisor-ohos-fstat-fix.patch`：gvisor fdbased endpoint 在 harmonyos 下 fstat 无权限的修复
- `core-dns-ohos.patch`：dns 包 OHOS 系统 DNS 注入（UpdateSystemDNS / FlushCacheWithDefaultResolver）
- `core-iface-ohos.patch`：iface/anet 包网络接口注入（SetNetInterfaces）
