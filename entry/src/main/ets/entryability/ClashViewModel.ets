import { ProfileRepo } from "proxy_core/src/main/ets/ProfileRepo";
import { Context, Want, common } from "@kit.AbilityKit";
import { SocketProxyService, Profile, ProfileType, UpdateConfigParams, ClashConfig, getHome,
  LogInfo,
  Provider,
  ProxyMode,
  ProxySort} from "proxy_core";
import { socket, vpnExtension } from "@kit.NetworkKit";
import { ConfigData } from "../common/entity/PageArgumentEntity";
import { convertTimeGapToMilliseconds } from "../common/entity/Constants";
import { PromptAction } from "@kit.ArkUI";
import { ProxyGroup } from "proxy_core/src/main/ets/models/Common";
import { ConfigExtendedParams } from "proxy_core/src/main/ets/models/ClashConfig";
import { EventHub, EventKey } from "../common/EventHub";
import { AppConfig, AppState, ClashCore, getPackageInfo } from "./AppState";
import  fs from  "@ohos.file.fs"
import { sleep } from "./EntryAbility";
import { ProxyItem } from "../common/datasources/ProxyData";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { readText } from "proxy_core/src/main/ets/fileUtils";
import { AccessControl, VpnRawOptions } from "proxy_core/src/main/ets/rpc/IClashManager";
import { cardManager } from "../common/utils/CardManageUtil";
import { PROXY_STARTED_DURATION_INIT_VALUE } from "../common/entity/Constants";
import { Timer } from "../common/utils/HHmmssTimer";
import { number2Time } from "../common/utils/TimeConvertUtil";
import { picker } from "@kit.CoreFileKit"
import { Xb_GetResourceString, Xb_ToastUtil } from "xb_components";
import { accessControlRdb } from "../common/datasources/AccessControlRdb";

export interface DelayInfo{
    name: string
    delay: number
}

export class ClashViewModel {
  vpnRequestId = 0;
  profileRepo = new ProfileRepo()
  socketProxy = new SocketProxyService()
  context: Context | undefined
  proxyStartedTimer = new Timer()
  static promptAction: PromptAction
  async init(context: Context, promptAction: PromptAction) {
    AppState.globalUA =  "clash.meta/1.19.5"
    this.context = context
    ClashViewModel.promptAction = promptAction
    await this.profileRepo.init(context)
    this.socketProxy.init(context)
    await this.initGeoIp()
  }
  // 添加配置 url
  async addOrUpdateProfileByUrl(data: ConfigData, id: string | null) {
    const ua = AppStorage.get<ClashConfig>("clashConfig")?.["global-ua"]
    let profile = new Profile(ProfileType.Url, data.configUrl)
    if(id) {
      const old = await this.profileRepo.query(id)
      if(old)
        profile = old
    }
    profile.loadContext(this.context, ua)
    profile.url = data.configUrl
    profile.name = data.configName
    profile.isUpdating = data.disableUpdate
    profile.autoUpdate = data.isConfigAutoUpdate
    // 转换为毫秒
    profile.autoUpdateDuration = convertTimeGapToMilliseconds(
      data.configAutoUpdateTimeGapValue ?? 10,
      data.configAutoUpdateTimeGapTextPickerIndex
    )
    await profile.checkAndUpdate( this.socketProxy)
    const isExists = await profile.check();
    let value: number
    if (isExists) { // 本地文件存在
      value = await this.profileRepo.addOrUpdate(profile)
    } else {
      value = -1
      console.error("ClashBox文件保存失败");
      Xb_ToastUtil.showToast({message: "文件保存失败！"})
    }
    EventHub.sendEvent(EventKey.FetchProfile, null)
    console.info("EditConfig&UpdateConfig&ConfigSort configSaveTestTag", `文件名${profile.name} URL: ${profile.url} 保存结果: ${value}`)
  }

  // 批量插入配置
  async addOrUpdateProfiles(data: Profile[]) {
    for (const profile of data) {
      let newProfile = new Profile(profile.type, profile.url)
      const old = await this.profileRepo.query(profile.id)
      console.log(`old配置 ${old ? old.name : '本地没有old配置'}`)
      if (old) {
        console.log(`配置${profile.name}在数据库中已存在`)
        newProfile = old
      }
      if (profile.type === ProfileType.Url) {
        // URL配置
        newProfile.loadContext(this.context)
        newProfile.name = profile.name
        newProfile.autoUpdate = profile.autoUpdate
        newProfile.autoUpdateDuration = profile.autoUpdateDuration ?? 10
        console.log(`配置${profile.name}基础设置完成`)
        await newProfile.checkAndUpdate(this.socketProxy)
      } else {
        // 本地文件配置
        try {
          let filePicker = new picker.DocumentViewPicker(this.context!)
          let options = new picker.DocumentSelectOptions()
          ClashViewModel.promptAction.showToast({ message: `${Xb_GetResourceString($r('app.string.file_config_restore_toast_1'), this.context)} ${profile.name}` })
          const documentSelectResult = await filePicker.select(options)
          newProfile.url = documentSelectResult[0]
          newProfile.name = decodeURIComponent(newProfile.url.substring(newProfile.url.lastIndexOf('/') + 1)) ?? profile.name
          console.log(`ClashBox Restore 配置${newProfile.name} 地址: ${newProfile.url} 选择完成`)
        } catch (err) {
          console.error(`ClashBox Restore 文件选择失败 ${err.name} ${err.message}`)
          // 导入失败后跳过
          continue
        }
        newProfile.loadContext(this.context)
        console.log(`配置${profile.name}基础设置完成`)
        try {
          await newProfile.saveByUri(profile.url)
        } catch (err) {
          console.error(`ClashBox Restore 配置移动读取失败 ${err.name} ${err.message}`)
        }
      }
      const isExists = await newProfile.check();
      if (isExists) {
        console.log(`配置${newProfile.name}已发现`)
        this.profileRepo.addOrUpdate(newProfile)
          .then((value) => {
            hilog.info(0xFF00, "Restore configSaveTestTag", `文件名${newProfile.name} URL: ${newProfile.url} 保存结果${value}`)
            EventHub.sendEvent(EventKey.FetchProfile, null)
          })
          .catch((err: Error) => {
            console.error(`ClashBox Restore 配置插入失败 ${err.name} ${err.message}`)
          })
      } else {
        console.error("ClashBox 配置文件不存在，保存失败");
        ClashViewModel.promptAction.showToast({message: "文件保存失败！"})
      }
    }
  }

  async addOrUpdateProfileByFile(name: string, path: string, id: string | null) {
    let profile = new Profile(ProfileType.File, path)
    if (id) {
      const old = await this.profileRepo.query(id)
      if (old)
        profile = old
    }
    profile.loadContext(this.context)
    profile.name = name // decodeURIComponent(path.substring(path.lastIndexOf('/') + 1))
    await profile.saveByUri(path);
    const isExists = await profile.check();
    if (isExists) {
      try {
        const value = await this.profileRepo.addOrUpdate(profile)
        hilog.info(0xFF00, "EditConfig configSaveTestTag", `文件名${profile.name} URL: ${profile.url} 保存结果${value}`)
        EventHub.sendEvent(EventKey.FetchProfile, null)
      } catch (err) {
        throw new Error(err.message)
      }
    } else {
      ClashViewModel.promptAction.showToast({message: "文件保存失败！"})
    }
  }

  async updateProfileConfig(id: string | null): Promise<void> {
    const ua = AppStorage.get<ClashConfig>("clashConfig")?.["global-ua"]
    if (id) {
      const profile = await this.getProfile(id)
      if (profile && profile.type == ProfileType.Url && !profile.isUpdating) {
        try {
          profile.loadContext(this.context, ua)
          await profile.update(this.socketProxy)
          await this.profileRepo.addOrUpdate(profile)
          if (this.context) {
            ClashViewModel.promptAction.showToast({ message: `${Xb_GetResourceString($r('app.string.Configuration'), this.context)} ${profile.name} ${Xb_GetResourceString($r('app.string.update_success'), this.context)}`})
          }
        } catch (e) {
          let message = ""
          if (this.context) {
            message = `${Xb_GetResourceString($r('app.string.Configuration'), this.context)} ${profile.name} ${Xb_GetResourceString($r('app.string.update_failed'), this.context)}: ${e.message} ${Xb_GetResourceString($r('app.string.check_configured_URL'), this.context)}`
            Xb_ToastUtil.showToast({message: message})
          }
          return Promise.reject(message)
        }
      }
    } else {
      const list = (await this.getProfiles()).filter(d => d.type == ProfileType.Url)
      for(let p of list) {
        if (!p.isUpdating) {
          p.loadContext(this.context, ua)
          await p.update(this.socketProxy)
          await this.profileRepo.addOrUpdate(p)
        }
      }
    }
    EventHub.sendEvent(EventKey.FetchProfile, null)
  }
  async VailConfig(config: string): Promise<string>{
    return await this.socketProxy.vailConfig(config)
  }
  async changeProxy(profile: Profile, g:string, p: string){
    try {
      profile.proxySelected?.set(g, p)
      await this.profileRepo.addOrUpdate(profile)
      await this.socketProxy.changeProxy(g, p)
      EventHub.sendEvent(EventKey.checkIpInfo)
    } catch (e) {
      ClashViewModel.promptAction.showToast({message: e.message, duration:3000})
    }
  }
  async setVpnOptions(options: VpnRawOptions){
    try {
      let result = await this.socketProxy.setOptionStates(options)
      console.log("setVpnOptions", result)
    } catch (e) {
      ClashViewModel.promptAction.showToast({message: e.message, duration:3000})
    }
  }


  delayMap: Map<string, DelayInfo> = new Map()

  async testDelay(proxyName: string, showError: boolean = true): Promise<number>{
    try {
      EventHub.sendEvent(EventKey.TestDelay, { name: proxyName, delay: 0 } as DelayInfo)
      let delay = await this.socketProxy.healthCheck(proxyName)

      EventHub.sendEvent(EventKey.TestDelay, { name: proxyName, delay: delay } as DelayInfo)
      this.delayMap.set(proxyName, { name: proxyName, delay: delay } as DelayInfo)
      return delay;
    } catch (e) {
      // sendMessageRequest 内部 reject 的是字符串（"请求超时" / "VPN服务未启动"），
      // 不是 Error，取 e.message 会拿到 undefined，
      // 再传给 showToast 会抛 401「The type of message is incorrect」，
      // 把真正的失败原因完全掩盖掉。这里统一取字符串形式。
      const message = `${e?.message ?? e}`
      console.error(`ProxySort testDelay [${proxyName}] 测速失败: ${message}`)
      if (showError) {
        ClashViewModel.promptAction.showToast({ message: message, duration: 3000 })
      }
    }
    return -1;
  }

  async testAllDelay(list: ProxyItem[]): Promise<number[]>{
    // 批量测速时不逐个弹 toast（几十个节点会刷屏），失败统一在调用方提示
    const result = await Promise.all(list.map((l)=> this.testDelay(l.name, false)))
    let appConfig = AppStorage.get<AppConfig>("appConfig")
    if (appConfig?.proxySort === ProxySort.Delay) {
      EventHub.sendEvent(EventKey.FetchProxyGroup)
    }
    return result;
  }

  async updateGeoData( geoType: string, geoName: string): Promise<string>{
    return this.socketProxy.updateGeoData(geoType, geoName)
  }
  async getTraffic(onlyProxy: boolean){
    return await this.socketProxy.queryTrafficNow(onlyProxy)
  }
  async getTotalTraffic(onlyProxy: boolean){
    return await this.socketProxy.queryTrafficTotal(onlyProxy)
  }
  async getProviders(): Promise<Provider[]>{
    return await this.socketProxy.queryProviders()
  }
  async checkIpInfo(){
    return await this.socketProxy.checkIpInfo()
  }
  async queryProviders(){
    return this.socketProxy.queryProviders()
  }
  async updateProvider(provider: Provider){
    let result = await this.socketProxy.updateProvider(provider)
    if(result && result != ""){
      ClashViewModel.promptAction.showToast({message: provider.name + ":" + result})
    }
  }
  async upLoadProvider(provider: Provider, fileUri: string) {
    if(!fileUri){
      return
    }
    let result = await this.socketProxy.upLoadProvider(provider, fileUri)
    if (result && result != ""){
      ClashViewModel.promptAction.showToast({message: provider.name + ":" + result})
    }
  }

  job?: (()=>void)
  async startLog(enable: boolean, callback: (d: LogInfo) => void){
      if(enable){
        this.job = await this.socketProxy.setLogObserver((message)=>{
          callback(message)
        })
      }else{
        this.job?.()
      }
  }

  async updateProfile(profile: Profile){
    await this.profileRepo.addOrUpdate(profile)
  }
  async getProfiles(): Promise<Profile[]>{
    return await this.profileRepo.queryAll()
  }
  async getProfile(id: string): Promise<Profile | null>{
    return await this.profileRepo.query(id)
  }
  async deleteProfile(id: string): Promise<void>{
    let p = await this.getProfile(id)
    p?.delete()
    await this.profileRepo.delete(id)
    EventHub.sendEvent(EventKey.FetchProfile, null)
  }
  async getConnections(){
     return await this.socketProxy.queryConnections()
  }
  async closeConnection(id:string){
    return await this.socketProxy.closeConnection(id)
  }
  async clearConnections(){
    return await this.socketProxy.clearConnections()
  }
  async getRequestList(){
    return await this.socketProxy.getRequestList()
  }
  async clearRequestList(){
    return await this.socketProxy.clearRequestList()
  }
  async getProxyGroups(model: ProxyMode): Promise<ProxyGroup[]>{
    try {
      let list = await this.socketProxy.queryProxyGroups(model)
      let favoriteProxys = AppStorage.get<Map<string, string>>("favoriteProxys")
      const groups = list.map((g)=>{
        g.proxies = g.proxies.map((p) => {
          // p.isShowFavoriteProxy = favoriteProxys?.get(g.name + "|" + p.name) != null
          p.latency = -1
          p.g = g.name
          return p
        })
        return g
      })
      return groups
    } catch (e) {
      console.error(" 获取代理失败: ", e.stack)
      ClashViewModel.promptAction.showToast({message: "获取代理失败: " + (e.message || e) + e.stack})
    }
    return []
  }
  //BUG 第一次启动，参数传不过去
  // 第一次要权限弹窗
  async ChangeCore(coreType: ClashCore | undefined = undefined, restart: boolean = true) {
    let requestId = Date.now();
    this.vpnRequestId = requestId;
    const vpnWant = {
      deviceId: "",
      bundleName: this.context?.applicationInfo.name, // release: org.xbgroup.clashbox, debug: org.xbgroup.clashboxb
      abilityName: "ClashVpnAbility",
      parameters: { "ClashCore" : coreType, requestId }
    } as Want
    // 若vpn进程没启动直接停止，会导致卡死或闪退， 不同系统不同现象
    if (restart) {
      // 停止vpn进程
      try {
        await vpnExtension.stopVpnExtensionAbility(vpnWant)
      } catch (error) {
        console.error(`ClashViewModel.ChangeCore restart过程中VPN进程终止失败: ${JSON.stringify(error)}`)
      }
    }
    await new Promise<void>((resolve) => {
      let settled = false
      let timeoutId: number = -1
      const finish = () => {
        if (settled) {
          return
        }
        settled = true
        if (timeoutId !== -1) {
          clearTimeout(timeoutId)
        }
        resolve()
      }
      timeoutId = setTimeout(() => {
        if (settled) {
          return
        }
        settled = true
        console.error('ClashViewModel.ChangeCore 启动VPN扩展超时')
        resolve()
      }, 10000)
      vpnExtension.startVpnExtensionAbility(vpnWant).then(() => {
        finish()
      }).catch((e: Error) => {
        console.error(`ClashViewModel.ChangeCore 启动VPN扩展失败: ${e.message}`)
        this.context?.getApplicationContext().killAllProcesses().catch((err: Error) => {
          console.error(`ClashViewModel.ChangeCore 应用进程终止失败: ${JSON.stringify(err)}`)
        })
        finish()
      })
    })
    await sleep(600)
    let result = await this.checkVpnVpnAbility(requestId)
    if (!result && restart) {
      ClashViewModel.promptAction.showToast({message:"VpnAbility请求失败! 请重启应用"})
    }
    return result;
  }

  private async checkVpnVpnAbility(reqId: number): Promise<boolean>{
    let lockPath = this.context?.filesDir + '/vpn_ipc.lock';
    // startVpnExtensionAbility 返回时 onCreate 可能还没执行完，给 lock 写入留出轮询时间
    for (let attempt = 0; attempt < 6; attempt++) {
      try {
        if (await fs.access(lockPath, fs.AccessModeType.EXIST)) {
          let requestId = await readText(lockPath)
          if (requestId == reqId + "") {
            console.log('ClashViewModel.checkVpnVpnAbility lock 校验成功')
            return true
          }
        }
      } catch (error) {
        console.error('ClashViewModel.checkVpnVpnAbility 检查 vpn_ipc.lock 失败：', error)
      }
      await sleep(300)
    }
    console.log('ClashViewModel.checkVpnVpnAbility vpn_ipc.lock 不存在或 requestId 不匹配，判定启动失败')
    return false
  }

  async loadProfileAndConfig(id: string, config: ClashConfig | null = null, params: ConfigExtendedParams | null= null){
    let result = await this.socketProxy.loadConfig({
      "profile-id": id,
      config: config ?? new ClashConfig(),
      params: params ?? {} as ConfigExtendedParams
    } as UpdateConfigParams)
    if (result != ""){
      ClashViewModel.promptAction.showToast({message: result, duration: 3000 })
    }
    EventHub.sendEvent(EventKey.FetchProxyGroup, null)
  }
  async ReStartVpn(): Promise<boolean> {
    if (!this.vpnStarted) {
      return true
    }
    try {
      const configLoaded = await this.loadConfig(false, 'ReStartVpn')
      if (!configLoaded) {
        console.error('ClashViewModel.ReStartVpn 配置加载失败')
        return false
      }
      await this.loadVpnOptions()
      await this.socketProxy.stopClash()
      const started = await this.socketProxy.startClash()
      if (!started) {
        console.error('ClashViewModel.ReStartVpn startClash 失败')
      }
      return started
    } catch (e) {
      console.error(`ClashViewModel.ReStartVpn 失败: ${e.message}`)
      return false
    }
  }
  vpnStarted = false
  private stopEntryListenerRegistered: boolean = false

  // 启动前要加载配置
  // loadConfig
  async StartVpn(): Promise<boolean> {
    if (this.vpnStarted) {
      return true
    }
    this.vpnStarted = true
    try {
      const optionsLoaded = await this.loadVpnOptions()
      if (!optionsLoaded) {
        console.error('ClashViewModel.StartVpn loadVpnOptions 失败')
        this.vpnStarted = false
        return false
      }
      let result = await this.socketProxy.startClash()
      // 核心崩溃 小钥匙一直在，要重启两量变
      if (!result){
        result = await this.socketProxy.startClash()
      }
      if (!result) {
        console.error('ClashViewModel.StartVpn startClash 失败')
        this.vpnStarted = false
        return false
      }
      EventHub.sendEvent(EventKey.StartedClash)
      EventHub.sendEvent(EventKey.checkIpInfo)
      const runTime = await this.getRuntime()
      hilog.info(0x001, "EntryAbility", "StartVpn时间戳: " + runTime)
      // 启动前先初始化卡片显示文本
      cardManager.pushCartVpnServiceTime(PROXY_STARTED_DURATION_INIT_VALUE)
      // 计算时间
      const vpnServiceStartTime = Number(runTime)
      this.proxyStartedTimer.start((time)=>{
        EventHub.sendEvent(EventKey.ProxyDuration, time)
        cardManager.pushCartVpnServiceTime(number2Time(time))
      },vpnServiceStartTime)
      if (!this.stopEntryListenerRegistered) {
        EventHub.on(EventKey.StopedClashEntry,()=>{
          hilog.info(0x001, "ClashViewModel", "StopedClashEntry事件")
          this.proxyStartedTimer.reset()
        })
        this.stopEntryListenerRegistered = true
      }
      cardManager.pushCartProxyMode(this.vpnStarted)
      const appConfig = AppStorage.get<AppConfig>('appConfig')
      if (appConfig !== undefined) {
        appConfig.vpnDesiredOn = true
      }
      return true
    } catch (e) {
      console.error(`ClashViewModel.StartVpn 失败: ${e.message}`)
      this.vpnStarted = false
      return false
    }
  }
  async loadVpnOptions(): Promise<boolean> {
    // 使用首选项持久化单个节点信息供卡片拉起服务
    const appConfig = AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig()
    const clashConfig = AppStorage.get<ClashConfig>("clashConfig") || cardManager.getClashConfig()
    if (appConfig == null) {
      return false
    }
    let acceptList: string[] = []
    let rejectList: string[] = []
    if (appConfig.accessControl) {
      try {
        if (this.context !== undefined) {
          await accessControlRdb.init(this.context as common.UIAbilityContext)
        }
        // 从数据库加载白名单
        const whiteApps = await accessControlRdb.getAppsByDomain('WHITE', 'name');
        acceptList = whiteApps.filter(a => a.isSelected).map(a => a.package_name);
        // 补充强制放行的包名
        const protectedPackages = [
          this.context?.applicationInfo.name as string,
          'com.atomicservice.5765880207855877209'
        ];
        protectedPackages.forEach(pkg => {
          if (pkg && !acceptList.includes(pkg)) {
            acceptList.push(pkg);
          }
        });
        // 从数据库加载黑名单
        const blackApps = await accessControlRdb.getAppsByDomain('BLACK', 'name');
        rejectList = blackApps.filter(a => a.isSelected).map(a => a.package_name);
        console.log(`AccessControl 将加载 acceptList ${acceptList.length} 个，rejectList ${rejectList.length} 个`)
      } catch (e) {
        // 访问控制数据库异常不能阻塞 VPN 启动，降级为空名单
        console.error(`ClashViewModel.loadVpnOptions 访问控制加载失败，降级为仅保护自身: ${e.message}`)
        acceptList = []
        const selfPkg = this.context?.applicationInfo.name
        if (selfPkg) {
          acceptList.push(selfPkg)
        }
        rejectList = []
      }
    }
    const accessControl = {
      tunIp : clashConfig?.tun?.["tun-ip"],
      // Capture IPv6 at the VPN layer even when Mihomo DNS/outbound IPv6 remains disabled.
      ipv6: true,
      routeAddress: clashConfig?.["route-address"] ?? [],
      accessControl: { mode:appConfig?.accessControlMode ?? "", acceptList: acceptList, rejectList: rejectList } as AccessControl
    } as VpnRawOptions
    try {
      const result = await this.socketProxy.setOptionStates(accessControl)
      return result !== undefined
    } catch (e) {
      console.error(`ClashViewModel.loadVpnOptions setOptionStates 失败: ${e.message}`)
      return false
    }
    // 在日志控制台 过滤关键字 vpnConfig, 验证是否配置成功
  }

  async StopVpn(){
    this.vpnStarted = false
    const appConfig = AppStorage.get<AppConfig>('appConfig')
    if (appConfig !== undefined) {
      appConfig.vpnDesiredOn = false
    }
    this.socketProxy.stopClash()
    // Index里的停止后操作
    EventHub.sendEvent(EventKey.StopedClash)
    // EntryAbility里的停止后操作
    EventHub.sendEvent(EventKey.StopedClashEntry)
    EventHub.sendEvent(EventKey.checkIpInfo)
    cardManager.pushCartProxyMode(this.vpnStarted)
    this.proxyStartedTimer.reset()
  }

  async getRuntime(){
    return await this.socketProxy.getRuntime()
  }
  // 校验是否配置成功
  async vpnConfigIsLoad(){
    const flag = await this.socketProxy.vpnConfigIsLoad()
    return flag
  }

  async initProfile() {
    let appConfig = AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig()
    EventHub.sendEvent(EventKey.StartLog, appConfig?.enableLogger)
    const configLoaded = await this.loadConfig(false, 'initProfile')
    if (!configLoaded) {
      console.error("ClashViewModel.initProfile 配置加载失败")
    }
    EventHub.sendEvent(EventKey.FetchProxyGroup)
    console.error("ClashViewModel.initProfile 初始化完成");
  }

  proxyGroups :ProxyGroup[] = []

  async loadConfig(patch: boolean = true, name?: string): Promise<boolean> {
    console.error(`ClashViewModel.loadConfig 调用方：${name} patch：${patch} 配置开始加载`)
    let appConfig = AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig()
    let clashConfig = AppStorage.get<ClashConfig>("clashConfig") || cardManager.getClashConfig()
    const profile = await this.profileRepo.query(appConfig?.currentProfileId)
    try {
      await this.loadProfileAndConfig(appConfig?.currentProfileId ?? "", clashConfig, {
        "is-patch": patch,
        "is-compatible": true,
        "override-dns": clashConfig?.overrideDns,
        "selected-map": profile?.getSelectedMap()
      } as ConfigExtendedParams)
      console.log(`ClashViewModel.loadConfig 调用方：${name} patch：${patch} 配加载成功`)
      return true
    } catch (e) {
      console.error('ClashViewModel.loadConfig 配置加载失败：', e)
      return false
    }
  }

  async initGeoIp(){
    let geoIp = await readFile(this.context?.resourceDir + "/geoip.metadb")
    let home = await getHome(this.context)
    writeFile(home+ "/geoip.metadb", geoIp)
    let geoip = await readFile(this.context?.resourceDir + "/GeoIP.dat")
    writeFile(home + "/GeoIP.dat", geoip)
    let geoSite = await readFile(this.context?.resourceDir + "/GeoSite.dat")
    writeFile(home + "/GeoSite.dat", geoSite)
    let Country = await readFile(this.context?.resourceDir + "/ASN.mmdb")
    writeFile(home + "/ASN.mmdb", Country)

  }
}
export async  function readFile(filePath: string): Promise<Uint8Array | null> {
  if(!await fs.access(filePath))
    return null;
  const file = await fs.open(filePath)
  const stats = await fs.stat(filePath)
  let bufSize = stats.size;
  let buf = new ArrayBuffer(bufSize);
  await fs.read(file.fd, buf, { offset: 0, length: bufSize });
  await fs.close(file);
  return new Uint8Array(buf);
}
export function writeFile(filePath: string, data: Uint8Array | null) {
  try {
    // 防止资源被覆盖
    if (fs.accessSync(filePath, fs.AccessModeType.EXIST))
      return;
    if(data != null && data.byteLength > 0){
      const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE| fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, data.buffer);
      fs.fsyncSync(file.fd)
      fs.closeSync(file);
    }
  }catch (e) {
    hilog.error(0x0000, 'EntryAbility', '%{public}s', 'write ' + filePath + ' failure: ' + e.message + e.stack);
  }

}

export default new ClashViewModel()
