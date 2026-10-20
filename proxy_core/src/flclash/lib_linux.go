//go:build ohos && cgo

package main

import "C"
import (
	"core/platform"
	"core/state"
	t "core/tun"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"net"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type ProcessMap struct {
	m sync.Map
}

type FdMap struct {
	m sync.Map
}

type FdWaitMap struct {
	m sync.Map
}

func (wm *FdWaitMap) Store(key int64, ch chan struct{}) {
	wm.m.Store(key, ch)
}

func (wm *FdWaitMap) Load(key int64) (chan struct{}, bool) {
	value, ok := wm.m.Load(key)
	if !ok || value == nil {
		return nil, false
	}
	return value.(chan struct{}), true
}

func (wm *FdWaitMap) Delete(key int64) {
	wm.m.Delete(key)
}

type Fd struct {
	Id    int64 `json:"id"`
	Value int64 `json:"value"`
}

var (
	tunListener      *sing_tun.Listener
	fdMap            FdMap
	fdWaitMap        FdWaitMap
	fdCounter        int64 = 0
	counter          int64 = 0
	processMap       ProcessMap
	tunLock          sync.Mutex
	runTime          *time.Time
	errBlocked       = errors.New("blocked")
	keepaliveStop    chan struct{}
	keepaliveOnce    sync.Once
)

func (cm *ProcessMap) Store(key int64, value string) {
	cm.m.Store(key, value)
}

func (cm *ProcessMap) Load(key int64) (string, bool) {
	value, ok := cm.m.Load(key)
	if !ok || value == nil {
		return "", false
	}
	return value.(string), true
}

func (cm *FdMap) Store(key int64) {
	cm.m.Store(key, struct{}{})
}

func (cm *FdMap) Load(key int64) bool {
	_, ok := cm.m.Load(key)
	return ok
}

func StartTUN(fd int, markSocket func(Fd)) {
	if fd == 0 {
		tunLock.Lock()
		defer tunLock.Unlock()
		now := time.Now()
		runTime = &now
		return
	}
	initSocketHook(markSocket)
	go func() {
		tunLock.Lock()
		defer tunLock.Unlock()
		f := int(fd)
		var startErr error
		tunListener, startErr = t.Start(f, currentConfig.General.Tun.Device, currentConfig.General.Tun.Stack, currentConfig.General.Tun.DNSHijack)
		if startErr != nil {
			// 旧版此处吞掉错误，TUN 启动失败时 VPN 仍显示已连接但无网络。
			// 现在必须落 hilog（hdc shell hilog | grep flclashGo）。
			log.Errorln("[TUN] start failed: %v (fd=%d device=%s stack=%s)", startErr, f, currentConfig.General.Tun.Device, currentConfig.General.Tun.Stack)
		} else if tunListener != nil {
			log.Infoln("TUN address: %v", tunListener.Address())
		}
		now := time.Now()
		runTime = &now
	}()
	// 启动后台保活 goroutine：每 60s 关闭空闲连接防止 NAT 超时
	startKeepalive()
}

// keepaliveLastBytes/keepaliveIdleSince 以连接为单位记录字节数快照与最近变化时间，
// 替代旧内核 Tracker.LastActivity()（新内核已移除）实现空闲检测。
var (
	keepaliveMu        sync.Mutex
	keepaliveLastBytes = map[string]int64{}
	keepaliveIdleSince = map[string]time.Time{}
)

func startKeepalive() {
	keepaliveOnce.Do(func() {
		keepaliveStop = make(chan struct{})
	})
	// 先停止已有保活
	stopKeepalive()
	keepaliveStop = make(chan struct{})
	go func() {
	 ticker := time.NewTicker(60 * time.Second)
	 defer ticker.Stop()
	 log.Infoln("[Keepalive] TUN 保活 goroutine 已启动")
	 for {
	  select {
	  case <-ticker.C:
	       // 直连模式下不需要健康检查和空闲连接清理
	       if currentConfig != nil && string(currentConfig.General.Mode) == "direct" {
	        continue
	       }
	       // 仅在有活跃连接时才做健康检查, 无流量时跳过以降低功耗
	       connSnapshot := statistic.DefaultManager.Snapshot()
	       if connSnapshot != nil && len(connSnapshot.Connections) > 0 {
	        go handleHealthCheckAll()
	       }
	   func() {
	    runLock.Lock()
	    defer runLock.Unlock()
	    if tunListener == nil {
	     return
	    }
	    // 关闭所有空闲连接，强制 NAT 重新建立映射
	    now := time.Now()
	    n := 0
	    liveIds := make(map[string]bool, 16)
	    statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
	     info := c.Info()
	     id := c.ID()
	     liveIds[id] = true
	     total := info.UploadTotal.Load() + info.DownloadTotal.Load()
	     keepaliveMu.Lock()
	     prev, ok := keepaliveLastBytes[id]
	     if !ok || prev != total {
	      keepaliveLastBytes[id] = total
	      keepaliveIdleSince[id] = now
	      keepaliveMu.Unlock()
	      return true
	     }
	     idle := now.Sub(keepaliveIdleSince[id])
	     keepaliveMu.Unlock()
	     // 仅关闭已空闲超过 120s 的连接(字节总数两个采样周期未变化)
	     if idle > 120*time.Second {
	      _ = c.Close()
	      n++
	     }
	     return true
	    })
	    keepaliveMu.Lock()
	    for id := range keepaliveLastBytes {
	     if !liveIds[id] {
	      delete(keepaliveLastBytes, id)
	      delete(keepaliveIdleSince, id)
	     }
	    }
	    keepaliveMu.Unlock()
	    if n > 0 {
	     log.Infoln("[Keepalive] 已关闭 %d 个空闲连接", n)
	    }
	   }()
			case <-keepaliveStop:
				log.Infoln("[Keepalive] TUN 保活 goroutine 已停止")
				return
			}
		}
	}()
}

func stopKeepalive() {
	if keepaliveStop != nil {
		select {
		case <-keepaliveStop:
			// 已关闭
		default:
			close(keepaliveStop)
		}
	}
	keepaliveOnce = sync.Once{}
}

func GetRunTime() string {
	if runTime == nil {
		return "clash服务未启动"
	}
	return strconv.FormatInt(runTime.UnixMilli(), 10)
}
func ConfigInited() string {
	if currentConfig != nil {
		return "true"
	}
	return "false"
}

func StopTun() {
	stopKeepalive()
	go func() {
		tunLock.Lock()
		defer tunLock.Unlock()

		runTime = nil

		if tunListener != nil {
			_ = tunListener.Close()
		}
		removeSocketHook()
		// 关闭 VPN 时立即刷新 DNS 缓存，避免 HarmonyOS 系统 10 分钟 DNS 缓存 TTL
		// 导致应用继续使用 VPN DNS 解析的过期记录
		dns.FlushCacheWithDefaultResolver()
	}()
}

// NotifyFdProtected 由 NAPI setFdMap（main_cgo.go）调用，参数为 Fd.Id。
// 记录 fdMap 并唤醒 initSocketHook 中等待的 channel。
// 修复说明：旧 SetFdMap(C.long) 无 //export 也无调用方，属死代码；
// channel 等待从未被唤醒 → 每个出站 socket 等满 5s 超时 → 未保护 →
// 流量回环进 TUN → VPN 显示已连接但无网络。
func NotifyFdProtected(id int64) {
	fdMap.Store(id)
	if ch, ok := fdWaitMap.Load(id); ok {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

func initSocketHook(markSocket func(Fd)) {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if platform.ShouldBlockConnection() {
			return errBlocked
		}
		return conn.Control(func(fd uintptr) {
			fdInt := int64(fd)
			id := atomic.AddInt64(&fdCounter, 1)

			// 直连模式下无需保护 socket，直接返回
			if currentConfig != nil && string(currentConfig.General.Mode) == "direct" {
				return
			}

			// 创建等待 channel，替代忙等待轮询
			waitCh := make(chan struct{}, 1)
			fdWaitMap.Store(id, waitCh)

			markSocket(Fd{
				Id:    id,
				Value: fdInt,
			})

			// 等待 SetFdMap 通知。
			// 等待发生在 conn.Control（connect 之前），会消耗拨号超时预算，
			// 绝不能超过 500ms：等满 5s 会吃掉整个拨号 deadline，所有出站
			// 连接 i/o timeout（VPN 显示已连接但无网络）。
			// protect 慢于 500ms（后台 JS 被限流）时放弃等待直接放行：
			// HarmonyOS 不回收 VPN 扩展进程自身流量，未 protect 的出站
			// socket 仍可直连（旧 100M 内核即全程未 protect 正常工作）。
			select {
			case <-waitCh:
			case <-time.After(500 * time.Millisecond):
				log.Warnln("[SocketHook] protect wait timeout, fd=%d id=%d socket un-protected, may loop into TUN", fdInt, id)
			}
			fdWaitMap.Delete(id)
		})
	}
}

func removeSocketHook() {
	dialer.DefaultSocketHook = nil
}

func init() {
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		if metadata == nil {
			return "", process.ErrInvalidNetwork
		}
		id := atomic.AddInt64(&counter, 1)

		timeout := time.After(200 * time.Millisecond)

		// SendMessage(Message{
		// 	Type: ProcessMessage,
		// 	Data: Process{
		// 		Id:       id,
		// 		Metadata: metadata,
		// 	},
		// })

		for {
			select {
			case <-timeout:
				return "", errors.New("package resolver timeout")
			default:
				value, exists := processMap.Load(id)
				if exists {
					return value, nil
				}
				time.Sleep(20 * time.Millisecond)
			}
		}
	}
}

func SetProcessMap(s string) string {
	paramsString := s
	go func() {
		var processMapItem = &ProcessMapItem{}
		err := json.Unmarshal([]byte(paramsString), processMapItem)
		if err == nil {
			processMap.Store(processMapItem.Id, processMapItem.Value)
		}
	}()
	return ""
}

func GetCurrentProfileName() string {
	if state.CurrentState == nil {
		return ""
	}
	return state.CurrentState.CurrentProfileName
}

func GetVpnOptions() string {
	tunLock.Lock()
	defer tunLock.Unlock()
	port := 7980
	if currentConfig != nil {
		port = currentConfig.General.MixedPort
	}
	options := state.AndroidVpnOptions{
		Enable:           state.CurrentState.Enable,
		Port:             port,
		Ipv4Address:      state.CurrentState.TunIp,
		Ipv6Address:      state.GetIpv6Address(),
		AccessControl:    state.CurrentState.AccessControl,
		SystemProxy:      state.CurrentState.SystemProxy,
		AllowBypass:      state.CurrentState.AllowBypass,
		RouteAddress:     state.CurrentState.RouteAddress,
		BypassDomain:     state.CurrentState.BypassDomain,
		DnsServerAddress: state.GetDnsServerAddress(),
		Mtu:              state.CurrentState.Mtu,
	}
	data, err := json.Marshal(options)
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

func SetState(s *C.char) {
	paramsString := C.GoString(s)
	err := json.Unmarshal([]byte(paramsString), state.CurrentState)
	if err != nil {
		return
	}
}

func UpdateDns(s *C.char) {
	dnsList := C.GoString(s)
	go func() {
		log.Infoln("[DNS] updateDns %s", dnsList)
		dns.UpdateSystemDNS(strings.Split(dnsList, ","))
		dns.FlushCacheWithDefaultResolver()
	}()
}

func UpdateSystemDns(dnsList string) error {
	log.Infoln("[DNS] updateDns %s", dnsList)
	go func() {
		log.Infoln("[DNS] updateDns %s", dnsList)
		dns.UpdateSystemDNS(strings.Split(dnsList, ","))
		dns.FlushCacheWithDefaultResolver()
	}()
	return nil
}

type NetIpMacInfo struct {
	IpAddress  NetAddress `json:"ipAddress"`
	Iface      string     `json:"iface"`
	MacAddress string     `json:"macAddress"`
}
type NetAddress struct {
	Address string `json:"address"` // IP地址
	Family  int    `json:"family"`  // 地址族：4(IPv4)或6(IPv6)
	Port    int    `json:"port"`    // 端口号（如果有）
}

func (info *NetIpMacInfo) ToNetInterface() (*net.Interface, error) {
	// 解析 MAC 地址
	var mac net.HardwareAddr
	if info.MacAddress != "" {
		var err error
		mac, err = net.ParseMAC(info.MacAddress)
		if err != nil {
			return nil, fmt.Errorf("parse MAC address failed: %w", err)
		}
	}

	// 获取接口索引（通过接口名）
	var index int
	if info.Iface != "" {
		iface, err := net.InterfaceByName(info.Iface)
		if err == nil && iface != nil {
			index = iface.Index
		}
	}

	return &net.Interface{
		Index:        index,
		MTU:          1500, // 默认值，你可能需要从其他地方获取
		Name:         info.Iface,
		HardwareAddr: mac,
		Flags:        getInterfaceFlags(info), // 需要实现这个函数
	}, nil
}
func getInterfaceFlags(info *NetIpMacInfo) net.Flags {
	var flags net.Flags

	// 如果 MAC 地址存在，通常接口是启用的
	if info.MacAddress != "" {
		flags |= net.FlagUp
		flags |= net.FlagBroadcast
		flags |= net.FlagMulticast
	}

	// 检查是否为回环接口
	if info.Iface == "lo" || info.Iface == "lo0" {
		flags |= net.FlagLoopback
	}
	return flags
}

func SetInterfaces(paramsString string) error {
	var interfaces []net.Interface
	var infos []NetIpMacInfo
	err := json.Unmarshal([]byte(paramsString), &infos)
	if err != nil {
		return err
	}
	seen := make(map[string]bool) // 去重
	for _, info := range infos {
		if seen[info.Iface] {
			continue
		}
		ifa, err := info.ToNetInterface()
		if err != nil {
			continue // 或者返回错误
		}

		if ifa != nil {
			interfaces = append(interfaces, *ifa)
			seen[info.Iface] = true
		}
	}
	iface.SetNetInterfaces(interfaces)
	return nil
}
