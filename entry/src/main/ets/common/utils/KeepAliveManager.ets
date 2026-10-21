import { common } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { deviceInfo } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { AppConfig, ClashCore, UIConfig } from '../../entryability/AppState'
import KeepAliveDiagnostics from './KeepAliveDiagnostics'
import BackgroundLocateService from './BackgroundLocateService'
import BackgroundDownService from './BackgroundDownService'
import { PipManager } from './PipManager'
import TaskKeepingService from './TaskKeepingService'

/** 长时任务类型；同一时刻只保留一种，避免互相 stop */
export enum KeepAliveTaskMode {
  NONE = 0,
  LOCATE = 1,
  DOWNLOAD = 2,
  TASK_KEEPING = 3
}

export interface KeepAliveStatus {
  taskMode: KeepAliveTaskMode
  taskActive: boolean
  pipActive: boolean
  lastError: string
}

/**
 * 后台保活统一管理器
 *
 * 职责：
 * - 按 UIConfig 选择一种主长时任务，并支持失败 fallback；
 * - 管理画中画 autoStart（PiP 与长时任务可并存）；
 * - 监听 continuousTaskCancel，取消原因写入 lastError 并尝试 fallback；
 * - 设置变更时立即重新应用，而不是等下次启动 VPN。
 */
class KeepAliveManager {
  private static instance: KeepAliveManager = new KeepAliveManager()
  private context?: common.Context
  private taskMode: KeepAliveTaskMode = KeepAliveTaskMode.NONE
  private taskActive: boolean = false
  private pipActive: boolean = false
  private lastError: string = ''
  private lastProxyActive: boolean = false
  private applying: boolean = false
  private cancelListenerRegistered: boolean = false
  private lastCancelAt: number = 0

  static getInstance(): KeepAliveManager {
    return KeepAliveManager.instance
  }

  init(context: common.Context): void {
    this.context = context
    if (this.cancelListenerRegistered) {
      return
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        this.lastError = `长时任务被系统取消: reason=${info.reason}`
        const appConfig = AppStorage.get<AppConfig>('appConfig')
        const coreName = appConfig !== undefined ? ClashCore[appConfig.clashCore] : 'unknown'
        KeepAliveDiagnostics.recordDrop(this.lastError, coreName,
          KeepAliveTaskMode[this.taskMode])
        this.taskActive = false
        this.taskMode = KeepAliveTaskMode.NONE
        hilog.warn(0xFF00, 'KeepAliveManager', this.lastError)
        // 防止取消回调导致无限重试
        const now = Date.now()
        if (now - this.lastCancelAt < 5000) {
          return
        }
        this.lastCancelAt = now
        if (this.lastProxyActive && this.context !== undefined) {
          this.apply(this.context, true).catch((e: Error) => {
            hilog.error(0xFF00, 'KeepAliveManager', `取消后 fallback 失败: ${e.message}`)
          })
        }
      })
      this.cancelListenerRegistered = true
    } catch (e) {
      hilog.error(0xFF00, 'KeepAliveManager', `监听 continuousTaskCancel 失败: ${JSON.stringify(e) ?? ''}`)
    }
  }

  getStatus(): KeepAliveStatus {
    return {
      taskMode: this.taskMode,
      taskActive: this.taskActive,
      pipActive: this.pipActive,
      lastError: this.lastError
    }
  }

  /**
   * 根据当前设置应用保活状态。
   * @param context Ability 上下文
   * @param proxyActive VPN 是否处于开启状态
   */
  async apply(context: common.Context, proxyActive: boolean): Promise<boolean> {
    this.init(context)
    this.lastProxyActive = proxyActive
    if (this.applying) {
      // 避免设置页连续点击造成并发 start/stop
      return this.taskActive || this.pipActive
    }
    this.applying = true
    try {
      if (!proxyActive) {
        await this.stopAll()
        return true
      }
      const uiConfig = AppStorage.get<UIConfig>('uiConfig')
      if (uiConfig === undefined) {
        this.lastError = 'UIConfig 未初始化'
        return false
      }

      const desiredTask = this.getDesiredTaskMode(uiConfig)
      if (desiredTask === KeepAliveTaskMode.NONE) {
        await this.stopLongTask()
      } else if (desiredTask !== this.taskMode || !this.taskActive) {
        await this.stopLongTask()
        const started = await this.startWithFallback(context, uiConfig, desiredTask)
        if (!started) {
          this.lastError = '所有长时任务启动失败，尝试画中画'
        }
      }

      // PiP 可以和长时任务并存；由 autoStart 在退后台时生效
      if (uiConfig.backgroundPiPModel) {
        const pipSupported = PipManager.getInstance().init(context)
        if (pipSupported) {
          PipManager.getInstance().setAutoStart(true)
          this.pipActive = true
        } else {
          this.pipActive = false
          this.lastError = '画中画不可用'
          // PiP 不可用时，如果长时任务也失败，再尝试一次长时任务 fallback
          if (!this.taskActive) {
            const fallbackStarted = await this.startWithFallback(context, uiConfig, KeepAliveTaskMode.LOCATE)
            if (!fallbackStarted) {
              this.lastError = '长时任务和画中画均不可用'
            }
          }
        }
      } else {
        PipManager.getInstance().setAutoStart(false)
        PipManager.getInstance().stopPip()
        this.pipActive = false
      }

      const ok = this.taskActive || this.pipActive
      if (ok) {
        hilog.info(0xFF00, 'KeepAliveManager',
          `保活已应用 task=${KeepAliveTaskMode[this.taskMode]} active=${this.taskActive} pip=${this.pipActive}`)
      }
      return ok
    } catch (e) {
      this.lastError = `应用保活失败: ${JSON.stringify(e) ?? ''}`
      hilog.error(0xFF00, 'KeepAliveManager', this.lastError)
      return false
    } finally {
      this.applying = false
    }
  }

  private getDesiredTaskMode(uiConfig: UIConfig): KeepAliveTaskMode {
    // 长时任务必须有通知；通知总开关关闭时不启动长时任务，仅保留可用的 PiP
    if (!uiConfig.Enablednotice) {
      return KeepAliveTaskMode.NONE
    }
    if (uiConfig.backgroundKeepTask && this.isTaskKeepingSupported()) {
      return KeepAliveTaskMode.TASK_KEEPING
    }
    if (uiConfig.backgroundLocateModel) {
      return KeepAliveTaskMode.LOCATE
    }
    if (uiConfig.backgroundDownModel) {
      return KeepAliveTaskMode.DOWNLOAD
    }
    return KeepAliveTaskMode.NONE
  }

  private getFallbackModes(uiConfig: UIConfig, primary: KeepAliveTaskMode): KeepAliveTaskMode[] {
    const modes: KeepAliveTaskMode[] = []
    if (primary !== KeepAliveTaskMode.NONE) {
      modes.push(primary)
    }
    if (uiConfig.backgroundLocateModel && !modes.includes(KeepAliveTaskMode.LOCATE)) {
      modes.push(KeepAliveTaskMode.LOCATE)
    }
    if (uiConfig.backgroundDownModel && !modes.includes(KeepAliveTaskMode.DOWNLOAD)) {
      modes.push(KeepAliveTaskMode.DOWNLOAD)
    }
    if (uiConfig.backgroundKeepTask && this.isTaskKeepingSupported() &&
      !modes.includes(KeepAliveTaskMode.TASK_KEEPING)) {
      modes.push(KeepAliveTaskMode.TASK_KEEPING)
    }
    return modes
  }

  private async startWithFallback(context: common.Context, uiConfig: UIConfig,
    primary: KeepAliveTaskMode): Promise<boolean> {
    const modes = this.getFallbackModes(uiConfig, primary)
    for (const mode of modes) {
      if (await this.startTaskMode(context, mode)) {
        this.taskMode = mode
        this.taskActive = true
        return true
      }
    }
    this.taskMode = KeepAliveTaskMode.NONE
    this.taskActive = false
    return false
  }

  private async startTaskMode(context: common.Context, mode: KeepAliveTaskMode): Promise<boolean> {
    try {
      if (mode === KeepAliveTaskMode.LOCATE) {
        return await BackgroundLocateService.start(context)
      }
      if (mode === KeepAliveTaskMode.DOWNLOAD) {
        return await BackgroundDownService.start(context)
      }
      if (mode === KeepAliveTaskMode.TASK_KEEPING) {
        return await TaskKeepingService.start(context)
      }
      return false
    } catch (e) {
      this.lastError = `启动保活模式 ${KeepAliveTaskMode[mode]} 失败: ${JSON.stringify(e) ?? ''}`
      hilog.error(0xFF00, 'KeepAliveManager', this.lastError)
      return false
    }
  }

  private async stopLongTask(): Promise<void> {
    try {
      if (this.taskMode === KeepAliveTaskMode.LOCATE) {
        await BackgroundLocateService.stop(this.context!)
      } else if (this.taskMode === KeepAliveTaskMode.DOWNLOAD) {
        await BackgroundDownService.stop(this.context!)
      } else if (this.taskMode === KeepAliveTaskMode.TASK_KEEPING) {
        await TaskKeepingService.stop(this.context!)
      }
    } catch (e) {
      hilog.warn(0xFF00, 'KeepAliveManager', `停止长时任务失败: ${JSON.stringify(e) ?? ''}`)
    }
    this.taskMode = KeepAliveTaskMode.NONE
    this.taskActive = false
  }

  private async stopAll(): Promise<void> {
    await this.stopLongTask()
    try {
      PipManager.getInstance().setAutoStart(false)
      PipManager.getInstance().stopPip()
    } catch (e) {
      hilog.warn(0xFF00, 'KeepAliveManager', `停止画中画失败: ${JSON.stringify(e) ?? ''}`)
    }
    this.pipActive = false
  }

  private isTaskKeepingSupported(): boolean {
    return deviceInfo.deviceType === 'tablet' || deviceInfo.deviceType === '2in1'
  }
}

export default KeepAliveManager.getInstance()
