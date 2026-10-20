//go:build !ohos

package main

// OHOS 与旧内核 constant/features 包中的 features.OHOS 等价：
// 非 ohos 构建标签编译时为 false。
const OHOS = false
