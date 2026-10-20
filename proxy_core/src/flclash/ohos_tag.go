//go:build ohos

package main

// OHOS 与旧内核 constant/features 包中的 features.OHOS 等价：
// 以 ohos 构建标签编译时为 true。新内核不再提供该特性开关，
// 由桥接层（本包）自行维护。
const OHOS = true
