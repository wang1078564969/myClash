import { accessControlRdb, AppInfo } from '../../../common/datasources/AccessControlRdb'
import TopBuilder from '../../Settings/TopBuilder'
import { SymbolGlyphModifier } from '@kit.ArkUI'
import { checkoutRowListItem, theRowCustomDialog } from '../../Common/Common'
import { CONTENT_END_OFFSET_150 } from '../../../common/entity/Constants'
import { PageMargin } from '../../../common/breakpoint/BreakPoint'
import { EventHub, Xb_ImageUtils, Xb_ToastUtil } from 'xb_components'
import { http } from '@kit.NetworkKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { AppConfig, UIConfig } from '../../../entryability/AppState'
import { EventKey } from '../../../common/EventHub'
import { customAnimationUtil } from '../../../common/utils/Animation'
import { EmptySearchResult } from './SubmitApp'

@Builder
export function OnlineSearchBuilder(name: string, param: Object) {
  OnlineSearch()
}

const TAG = "OnlineSearch"

/**
 * 服务状态枚举
 * @description 用于表示在线服务的运行状态
 */
enum ServiceStatus {
  /** 故障 */
  DOWN = 0,
  /** 正常 */
  UP = 1,
  /** 重试 */
  RETRY = 2,
  /** 维护中 */
  MAINTENANCE = 3
}

/**
 * @projectName:    clashnext
 * @fileName:      OnlineSearch
 * @author:     SummerKaze
 * @description:  在线搜索
 * @date:    2026/1/13 16:19
 * @version:    1.0
 */

@Component
struct OnlineSearch {
  @StorageLink('OnlineSearchPageInfos') addPageInfos: NavPathStack = new NavPathStack()
  // 高度断点
  @StorageLink('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  // 宽度断点
  @StorageLink('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  // 主题色
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  // UI控制变量
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  // 搜索文本
  @State searchText: string = ''
  // 搜索结果列表
  @State apps: SearchAppInfo[] = []
  @StorageLink('appConfig') appConfig: AppConfig = new AppConfig()
  // 是否正在搜索（本次查询首页加载中）
  @State isSearch: boolean = false;
  // 是否正在加载更多
  @State isLoadMore: boolean = false;
  // 本次搜索是否失败（网络/服务异常）-> 展示失败态与重试入口，避免一直转圈
  @State searchError: boolean = false;
  // 是否还有下一页数据
  @State hasMore: boolean = false;
  /* 是否开启 `Index` 页面的前景模糊 */
  @Consume('isEnableIndexForegroundBlur') isEnableIndexForegroundBlur: boolean
  // 在线服务状态（0: 故障, 2: 重试, 1: 正常, 3: 维护）
  @State serviceStatus: ServiceStatus = ServiceStatus.RETRY
  // 防抖定时器ID
  private debounceTimerId: number = -1
  // 防抖延迟时间（毫秒）
  private readonly DEBOUNCE_DELAY: number = 400
  // 待删除的应用信息
  private pendingDeleteApp: SearchAppInfo | null = null
  // 服务状态请求定时器ID
  private serviceStatusTimerId: number = -1
  // 服务状态请求间隔 (5分钟/次)
  private readonly SERVICE_STATUS_INTERVAL: number = 5 * 60 * 1000
  // 红绿灯状态指示器尺寸
  private readonly INDICATOR_SIZE: number = 16
  // 每页数量
  private readonly PAGE_SIZE: number = 20
  // 当前已加载页码
  private currentPage: number = 1
  // 结果总数（用于判断是否还有下一页）
  private totalCount: number = 0
  // 当前搜索关键词（已归一化）
  private currentKeyword: string = ''
  // 搜索请求序号 -> 丢弃过期请求的返回，避免旧结果覆盖新结果
  private searchSeq: number = 0
  // 图标缓存（icon_url -> 图标数据）-> 刷新列表时避免重复下载
  private iconCache: Map<string, Uint8Array | undefined> = new Map<string, Uint8Array | undefined>()
  // API 主机：官方 API 主机优先，官网主机兜底（官网主机走 CDN，部分网络环境下不可达）
  private readonly API_HOSTS: string[] = ['https://api.next.vcck.cn', 'https://next.vcck.cn']
  // 连接超时（毫秒）
  private readonly CONNECT_TIMEOUT: number = 10 * 1000
  // 读取超时（毫秒）
  private readonly READ_TIMEOUT: number = 15 * 1000

  aboutToAppear(): void {
    this.fetchServiceStatus()

    // 5分钟获取一次服务状态
    this.serviceStatusTimerId = setInterval(() => {
      this.fetchServiceStatus()
    }, this.SERVICE_STATUS_INTERVAL)
  }

  aboutToDisappear(): void {
    this.clearDebounceTimer()
    clearInterval(this.serviceStatusTimerId)
    this.iconCache.clear()
  }

  build() {
    NavDestination() {
      TopBuilder({
        showBackButton: true,
        title: $r('app.string.online_search'),
        pathStack: this.addPageInfos,
        extraBuilder: () => {
          this.statusIndicatorBuilder()
        }
      })

      Column() {
        Search({ value: this.searchText, placeholder: $r('app.string.the_app_name') })
          .enterKeyType(EnterKeyType.Search)
          .copyOption(CopyOptions.LocalDevice)
          .searchIcon(new SymbolGlyphModifier($r('sys.symbol.magnifyingglass')).fontColor([this.icon_emphasize]))
          .margin({ left: PageMargin(this.widthBp, this.heightBp), right: PageMargin(this.widthBp, this.heightBp) })
          .cancelButton({
            style: CancelButtonStyle.CONSTANT,
            icon: new SymbolGlyphModifier($r('sys.symbol.xmark')).fontColor([this.icon_emphasize])
          })
          .onChange((value: string) => {
            // 同步搜索文本（空态提示需要用到最新关键词）
            this.searchText = value
            // 使用防抖 (Debounce) 进行搜索
            this.debounceSearch(value)
          })
          .onSubmit(async (value: string) => {
            // 提交时立即执行搜索（清除防抖定时器）
            this.searchText = value
            this.clearDebounceTimer()
            await this.searchApps(value)
          })

        if (this.isSearch) {
          // 搜索动画
          Row() {
            LoadingProgress()
              .color(this.icon_emphasize)
              .width("20%")
              .aspectRatio(1)
              .transition(customAnimationUtil.isOpacity(this.uiConfig))
          }
          .justifyContent(FlexAlign.Center)
          .layoutWeight(1)
        } else if (this.searchError) {
          // 网络/服务异常：展示失败态并提供重试入口，避免一直停留在转圈状态
          this.searchErrorBuilder()
        } else if (this.apps.length === 0 && this.searchText.trim() !== '') {
          // 搜索结果为空，显示提交应用建议
          EmptySearchResult({
            searchText: this.searchText,
            onSubmitSuccess: () => {
              // 提交成功后的回调（可选：重新搜索）
            }
          })
        } else {
          List() {
            ForEach(this.apps, (app: SearchAppInfo) => {
              ListItem() {
                checkoutRowListItem({
                  icon: Xb_ImageUtils.uint8ArrayToPixelMap(app.iconUintArr) || $r('app.media.box_cat_round'),
                  title: app.name,
                  endSymbol: app.isExists ? $r('sys.symbol.xmark_circle') : $r('sys.symbol.plus_circle'),
                  symbolColor: app.isExists ? "#FFE84026" : this.icon_emphasize,
                  subtitle: app.package_name,
                  needBackgroundColor: false,
                  enabledClick: true
                })
              }
              .onClick(async () => {
                // 点击逻辑
                const newPackageName = app.package_name;
                const newAppName = app.name;
                const iconUintArr = app.iconUintArr

                if (!app.isExists) {
                  // 1. --- 新增逻辑 ---
                  const newApp: AppInfo = {
                    name: newAppName,
                    package_name: newPackageName,
                    iconUintArr,
                    time: Date.now(),
                    isSelected: false
                  };
                  // 确定添加到哪个域
                  const domain = this.appConfig.accessControlMode === 'AcceptSelected' ? 'WHITE' : 'BLACK'
                  await accessControlRdb.addAppToDomain(newApp, domain)
                  Xb_ToastUtil.showToast({ message: $r('app.string.add_success'), duration: 1000 })

                  // 重新加载列表（仅新增时执行）
                  await this.refreshExistsFlags()
                  EventHub.sendEvent(EventKey.ReLoadAccessControl)
                } else {
                  // 2. 删除逻辑 - 显示确认弹窗防止误操作
                  this.pendingDeleteApp = app
                  this.deleteDialogController.open()
                }
              })
            })
            // 分页加载状态 -> 滚动到底部自动加载更多，也可点击底部区域加载
            if (this.apps.length > 0) {
              ListItem() {
                Row({ space: 8 }) {
                  if (this.isLoadMore) {
                    LoadingProgress()
                      .color(this.icon_emphasize)
                      .width(18)
                      .aspectRatio(1)
                  }
                  Text(this.isLoadMore ? $r('app.string.loading_more') :
                    (this.hasMore ? $r('app.string.load_more') : $r('app.string.no_more_data')))
                    .fontSize(13)
                    .fontColor($r('sys.color.font_secondary'))
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 10, bottom: 10 })
                .onClick(() => {
                  this.loadMore()
                })
              }
            }
          }
          .width('100%')
          .contentStartOffset(5)
          .alignListItem(ListItemAlign.Center)
          .contentEndOffset(CONTENT_END_OFFSET_150 - 55)
          .padding({ left: PageMargin(this.widthBp, this.heightBp), right: PageMargin(this.widthBp, this.heightBp) })
          .onReachEnd(() => {
            this.loadMore()
          })
        }
      }
      .padding({ bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .hideTitleBar(true)
    .backgroundColor($r('app.color.background'))
  }

  /** 红绿灯状态指示器 */
  @Builder
  statusIndicatorBuilder() {
    Row() {
      // 外层泛光效果容器
      Stack() {
        // 泛光层（底层发光效果）
        Row()
          .borderRadius("50%")
          .backgroundColor(this.getStatusColor())
          .width(this.INDICATOR_SIZE * 0.75)
          .aspectRatio(1)
          .shadow({
            radius: this.INDICATOR_SIZE * 0.5,
            color: this.getStatusColor(),
            offsetX: 0,
            offsetY: 0
          })
          .opacity(0.6)

        // 主指示灯
        Row()
          .borderRadius("50%")
          .backgroundColor(this.getStatusColor())
          .width(this.INDICATOR_SIZE * 0.58)
          .aspectRatio(1)
          .shadow({
            radius: this.INDICATOR_SIZE * 0.25,
            color: this.getStatusColor(),
            offsetX: 0,
            offsetY: 0
          })
        // 高光点（增加立体感）
        Row()
          .borderRadius("50%")
          .backgroundColor('#FFFFFF')
          .width(this.INDICATOR_SIZE / 6)
          .aspectRatio(1)
          .opacity(0.7)
          .offset({ x: -this.INDICATOR_SIZE / 8, y: -this.INDICATOR_SIZE / 8 })
      }
      .width(this.INDICATOR_SIZE)
      .aspectRatio(1)
      .margin({ left: 8 })
    }
    .alignItems(VerticalAlign.Center)
  }

  /** 搜索失败态（网络异常 / 服务不可用） */
  @Builder
  searchErrorBuilder() {
    Column({ space: 16 }) {
      SymbolGlyph($r('sys.symbol.xmark_circle'))
        .fontSize(48)
        .fontColor(['#FFE84026'])
      Text($r('app.string.search_failed_network'))
        .fontSize(15)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
      Button($r('app.string.retry'))
        .width(160)
        .height(40)
        .backgroundColor(this.icon_emphasize)
        .fontColor(Color.White)
        .fontSize(16)
        .onClick(() => {
          this.searchApps(this.searchText)
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .transition(customAnimationUtil.isOpacity(this.uiConfig))
  }

  /** 删除确认弹窗控制器 */
  deleteDialogController: CustomDialogController = new CustomDialogController({
    builder: theRowCustomDialog({
      contentText: $r('app.string.delete_app_confirm'),
      cancel: () => {
        this.onDeleteCancel()
      },
      confirm: () => {
        this.onDeleteConfirm()
      },
      leftButton: () => {
        this.deleteBuilder()
      }
    }),
    onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
      if (dismissDialogAction.reason === DismissReason.TOUCH_OUTSIDE) {
        // 点击遮蔽层不响应，防误触
      } else {
        dismissDialogAction.dismiss()
        this.isEnableIndexForegroundBlur = false
      }
    }
  })

  /** 删除按钮样式 */
  @Builder
  deleteBuilder() {
    Button($r('app.string.delete'))
      .width('100%')
      .height(39)
      .fontColor(Color.Red)
      .backgroundColor($r('app.color.container_background'))
  }

  /** 取消删除回调 */
  onDeleteCancel(): void {
    this.pendingDeleteApp = null
    this.isEnableIndexForegroundBlur = false
  }

  /** 确认删除回调 */
  async onDeleteConfirm(): Promise<void> {
    if (this.pendingDeleteApp) {
      const domain = this.appConfig.accessControlMode === 'AcceptSelected' ? 'WHITE' : 'BLACK'
      try {
        await accessControlRdb.removeAppFromDomain(this.pendingDeleteApp.package_name, domain)
        Xb_ToastUtil.showToast({ message: $r('app.string.delete_success'), duration: 1000 })

        // 刷新列表（仅更新已存在状态，避免重复下载图标）
        await this.refreshExistsFlags()
        EventHub.sendEvent(EventKey.ReLoadAccessControl)
      } catch (error) {
        hilog.error(0xFF00, TAG, "删除失败: %{public}s", error.message)
        Xb_ToastUtil.showToast({ message: $r('app.string.delete_failed') })
      }
    }
    this.pendingDeleteApp = null
    this.isEnableIndexForegroundBlur = false
  }

  /**
   * 根据服务状态获取对应颜色
   * @returns 状态对应的颜色值
   */
  private getStatusColor(): ResourceColor {
    switch (this.serviceStatus) {
      case ServiceStatus.UP:
        // 正常 - 绿色
        return '#00C853'
      case ServiceStatus.DOWN:
        // 故障 - 红色
        return '#FF1744'
      case ServiceStatus.MAINTENANCE:
        // 维护 - 黄色/橙色
        return '#FFAB00'
      case ServiceStatus.RETRY:
      default:
      // 加载/重试状态 - 灰色
        return '#9E9E9E'
    }
  }

  /**
   * 获取在线服务状态
   * @description 从 API 获取心跳数据，解析服务状态
   */
  private fetchServiceStatus(): void {
    const httpRequest = http.createHttp()
    const url = 'https://jk.vcck.cn/api/status-page/heartbeat/clashbox'

    httpRequest.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: this.CONNECT_TIMEOUT,
      readTimeout: this.READ_TIMEOUT
    }, (err: Error, data: http.HttpResponse) => {
      if (!err && data.responseCode === http.ResponseCode.OK && typeof data.result === 'string') {
        try {
          const response = JSON.parse(data.result) as HeartbeatResponse
          // 获取 key 为 "8" 的心跳列表
          const heartbeatList8 = response.heartbeatList['8']
          if (heartbeatList8 && heartbeatList8.length > 0) {
            // 取最后一个对象的 status 值
            const lastHeartbeat = heartbeatList8[heartbeatList8.length - 1]
            this.serviceStatus = lastHeartbeat.status as ServiceStatus
            hilog.info(0xFF00, TAG, "服务状态获取成功: %{public}d", this.serviceStatus)
          }
        } catch (parseErr) {
          hilog.error(0xFF00, TAG, "解析服务状态失败: %{public}s", (parseErr as Error).message)
          this.serviceStatus = ServiceStatus.DOWN
        }
      } else {
        hilog.error(0xFF00, TAG, "获取服务状态失败")
        this.serviceStatus = ServiceStatus.DOWN
      }
      httpRequest.destroy()
    })
  }

  /** 清除防抖定时器 */
  private clearDebounceTimer(): void {
    if (this.debounceTimerId !== -1) {
      clearTimeout(this.debounceTimerId)
      this.debounceTimerId = -1
    }
  }

  /**
   * 归一化搜索关键词
   * @description 去除首尾空白、全角转半角、合并连续空白
   *              服务端是按应用名做子串匹配的，任何多余空白（如输入法带出的空格）都会导致 0 命中
   * @param raw 原始输入
   * @returns 归一化后的关键词
   */
  private normalizeKeyword(raw: string): string {
    if (!raw) {
      return ''
    }
    let result = ''
    for (let i = 0; i < raw.length; i++) {
      const code = raw.charCodeAt(i)
      if (code === 0x3000) {
        // 全角空格
        result += ' '
      } else if (code >= 0xFF01 && code <= 0xFF5E) {
        // 全角 ASCII 字符转半角
        result += String.fromCharCode(code - 0xFEE0)
      } else {
        result += raw.charAt(i)
      }
    }
    return result.replace(/\s+/g, ' ').trim()
  }

  /** 重置搜索状态（清空输入时使用） */
  private resetSearchState(): void {
    // 序号自增 -> 进行中的请求返回后会被丢弃
    this.searchSeq++
    this.isSearch = false
    this.isLoadMore = false
    this.searchError = false
    this.hasMore = false
    this.currentPage = 1
    this.totalCount = 0
    this.currentKeyword = ''
    this.apps = []
  }

  /**
   * 防抖搜索 - 延迟执行搜索，避免频繁请求
   * @param value 搜索关键词
   */
  private debounceSearch(value: string): void {
    // 清除之前的定时器
    this.clearDebounceTimer()

    // 如果归一化后为空，直接清空结果
    if (this.normalizeKeyword(value).length === 0) {
      this.resetSearchState()
      return
    }

    // 设置新的定时器
    this.debounceTimerId = setTimeout(async () => {
      this.debounceTimerId = -1
      await this.searchApps(value)
    }, this.DEBOUNCE_DELAY)
  }

  /**
   * 加载已添加的应用列表
   * @returns Promise<AppInfo[]> 应用列表
   */
  private async loadAppsInfo(): Promise<AppInfo[]> {
    // 确定当前域
    const domain = this.appConfig.accessControlMode === 'AcceptSelected' ? 'WHITE' : 'BLACK'
    // 确定排序方式
    const sortBy = this.appConfig.accessControlSort === 'name' ? 'name' : 'time'
    // 直接查询数据库，数据库已处理排序和选中状态
    const appListData = await accessControlRdb.getAppsByDomain(domain, sortBy)

    return appListData
  }

  /**
   * 执行在线搜索应用（重新查询第一页）
   * @param value 搜索关键词
   */
  private async searchApps(value: string): Promise<void> {
    const keyword = this.normalizeKeyword(value)
    if (keyword.length === 0) {
      this.resetSearchState()
      return
    }

    // 序号自增 -> 旧请求的结果会被丢弃，避免覆盖新结果
    const seq = ++this.searchSeq
    this.currentKeyword = keyword
    this.currentPage = 1
    this.totalCount = 0
    this.apps = []
    this.hasMore = false
    this.searchError = false
    this.isLoadMore = false
    this.isSearch = true
    try {
      const response = await this.getAppList(keyword, 1, this.PAGE_SIZE)
      if (seq !== this.searchSeq) {
        return
      }
      if (!response.success) {
        throw new Error(response.message ?? '搜索服务返回失败')
      }
      await this.applyResult(response, false, seq)
      hilog.info(0xFF00, TAG, "搜索成功，关键词: %{public}s, 已加载: %{public}d / %{public}d",
        keyword, this.apps.length, this.totalCount)
    } catch (error) {
      if (seq !== this.searchSeq) {
        return
      }
      // 请求失败/服务异常 -> 展示失败态，避免一直转圈
      this.searchError = true
      hilog.error(0xFF00, TAG, "搜索失败: %{public}s", (error as Error).message)
    } finally {
      // 无论成功失败都要结束加载态
      if (seq === this.searchSeq) {
        this.isSearch = false
      }
    }
  }

  /** 加载下一页（滚动到底部 / 点击底部时触发） */
  private async loadMore(): Promise<void> {
    if (this.isSearch || this.isLoadMore || !this.hasMore || this.currentKeyword.length === 0) {
      return
    }
    const seq = this.searchSeq
    const nextPage = this.currentPage + 1
    this.isLoadMore = true
    try {
      const response = await this.getAppList(this.currentKeyword, nextPage, this.PAGE_SIZE)
      if (seq !== this.searchSeq) {
        return
      }
      if (!response.success) {
        throw new Error(response.message ?? '搜索服务返回失败')
      }
      this.currentPage = nextPage
      await this.applyResult(response, true, seq)
    } catch (error) {
      if (seq === this.searchSeq) {
        hilog.error(0xFF00, TAG, "加载更多失败: %{public}s", (error as Error).message)
        Xb_ToastUtil.showToast({ message: $r('app.string.search_failed_network') })
      }
    } finally {
      if (seq === this.searchSeq) {
        this.isLoadMore = false
      }
    }
  }

  /**
   * 将接口响应追加/替换到列表中
   * @param response 搜索响应
   * @param isAppend 是否追加到现有列表
   * @param seq 请求序号（用于丢弃过期结果）
   */
  private async applyResult(response: SearchResponse, isAppend: boolean, seq: number): Promise<void> {
    const data: SearchAppItem[] = response.data ?? []
    if (data.length === 0) {
      if (!isAppend) {
        this.apps = []
        this.totalCount = 0
      }
      // 兜底：没有更多数据时停止分页，避免空页导致反复请求
      this.hasMore = false
      return
    }
    const converted = await this.convertToAppInfo(data)
    // 图标下载是异步的，这里再校验一次序号
    if (seq !== this.searchSeq) {
      return
    }
    this.apps = isAppend ? this.apps.concat(converted) : converted
    this.totalCount = typeof response.total === 'number' ? response.total : this.apps.length
    this.hasMore = this.apps.length < this.totalCount
  }

  /**
   * 获取应用列表（多主机容错 + 超时控制）
   * @param q 搜索关键词
   * @param page 页码
   * @param pageSize 每页数量
   * @returns Promise<SearchResponse> 搜索响应
   */
  private async getAppList(q: string, page: number, pageSize: number): Promise<SearchResponse> {
    const query = `?q=${encodeURIComponent(q)}&page=${page}&page_size=${pageSize}`
    let lastError: Error = new Error('请求失败')
    for (let i = 0; i < this.API_HOSTS.length; i++) {
      const host = this.API_HOSTS[i]
      try {
        const response = await this.requestAppList(`${host}/api/apps/search-by-name${query}`)
        hilog.info(0xFF00, TAG, "搜索接口请求成功，主机: %{public}s", host)
        return response
      } catch (error) {
        lastError = error as Error
        hilog.warn(0xFF00, TAG, "主机 %{public}s 请求失败: %{public}s", host, (error as Error).message)
      }
    }
    throw lastError
  }

  /**
   * 发起单次搜索请求（带连接/读取超时，避免长时间无响应）
   * @param url 完整请求地址
   * @returns Promise<SearchResponse>
   */
  private requestAppList(url: string): Promise<SearchResponse> {
    return new Promise<SearchResponse>((resolve, reject) => {
      const httpRequest = http.createHttp()

      httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: this.CONNECT_TIMEOUT,
        readTimeout: this.READ_TIMEOUT,
        expectDataType: http.HttpDataType.STRING,
        header: { 'Content-Type': 'application/json' }
      }, (err: Error, data: http.HttpResponse) => {
        httpRequest.destroy()
        if (err) {
          reject(err)
          return
        }
        if (data.responseCode !== http.ResponseCode.OK) {
          reject(new Error(`HTTP 状态码异常: ${data.responseCode}`))
          return
        }
        // 确保 data.result 是字符串类型
        if (typeof data.result !== 'string') {
          hilog.warn(0xFF00, TAG, "返回值不是string")
          reject(new Error('返回值不是string'))
          return
        }
        try {
          // 将 data.result 字符串解析为 JSON 对象
          const response = JSON.parse(data.result) as SearchResponse
          resolve(response)
        } catch (parseErr) {
          hilog.error(0xFF00, TAG, "无法解析响应: %{public}s", (parseErr as Error).message)
          reject(new Error('无法解析响应: ' + (parseErr as Error).message))
        }
      })
    })
  }

  /**
   * 将接口返回的应用数据转换为列表数据
   * @description 图标数据走缓存 + 并行下载，避免串行下载多个图标造成明显等待
   * @param items 接口返回的应用信息
   * @returns Promise<SearchAppInfo[]>
   */
  async convertToAppInfo(items: SearchAppItem[]): Promise<SearchAppInfo[]> {
    const appInfoList: SearchAppInfo[] = []
    // 获取当前列表中的所有包名
    const appListData = await this.loadAppsInfo()
    const appPackageList = appListData.map(app => app.package_name)

    // 并行获取图标
    const iconTasks: Promise<Uint8Array | undefined>[] = []
    for (const item of items) {
      iconTasks.push(this.getIcon(item.icon_url))
    }
    const icons = await Promise.all(iconTasks)

    for (let i = 0; i < items.length; i++) {
      const item = items[i]
      appInfoList.push({
        name: item.name,
        package_name: item.pkg_name,
        iconUintArr: icons[i],
        time: Date.now(),
        isSelected: false,
        // 检查包名是否已存在于当前列表中
        isExists: appPackageList.includes(item.pkg_name)
      } as SearchAppInfo)
    }

    return appInfoList
  }

  /**
   * 获取应用图标（优先取缓存）
   * @param iconUrl 图标地址
   * @returns Promise<Uint8Array | undefined>
   */
  private getIcon(iconUrl: string): Promise<Uint8Array | undefined> {
    if (this.iconCache.has(iconUrl)) {
      return Promise.resolve(this.iconCache.get(iconUrl))
    }
    return new Promise<Uint8Array | undefined>((resolve) => {
      Xb_ImageUtils.downloadImageAsUint8Array(iconUrl).then((data: Uint8Array | undefined) => {
        this.iconCache.set(iconUrl, data)
        resolve(data)
      }).catch(() => {
        // 图标下载失败不阻塞列表展示
        this.iconCache.set(iconUrl, undefined)
        resolve(undefined)
      })
    })
  }

  /**
   * 刷新列表中应用的「是否已添加」状态
   * @description 不重新下载图标，避免添加/删除后整列表重新请求图片
   */
  private async refreshExistsFlags(): Promise<void> {
    const appListData = await this.loadAppsInfo()
    const existsPackages = new Set<string>(appListData.map(app => app.package_name))
    const updatedApps: SearchAppInfo[] = []
    for (const app of this.apps) {
      updatedApps.push({
        name: app.name,
        package_name: app.package_name,
        iconUintArr: app.iconUintArr,
        time: app.time,
        isSelected: app.isSelected,
        isExists: existsPackages.has(app.package_name)
      } as SearchAppInfo)
    }
    this.apps = updatedApps
  }
}

/** API 返回的单个应用信息 */
interface SearchAppItem {
  name: string
  pkg_name: string
  icon_url: string
  download_count: number
  download_count_desc: string
}

/** API 搜索响应结构 */
interface SearchResponse {
  success: boolean
  data: SearchAppItem[]
  message: string | null
  total: number
  limit: number
  timestamp: string
}

interface SearchAppInfo extends AppInfo {
  // 此应用是否存在
  isExists: boolean
}

/** 心跳响应数据结构 */
interface HeartbeatItem {
  status: number
  time: string
  msg: string
  ping: number
}

/** 心跳 API 响应结构 */
interface HeartbeatResponse {
  heartbeatList: Record<string, HeartbeatItem[]>
  uptimeList: Record<string, number>
}
