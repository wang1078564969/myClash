import { abilityAccessCtrl, Context, Permissions, WantAgent, wantAgent } from "@kit.AbilityKit";
import { backgroundTaskManager } from "@kit.BackgroundTasksKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { geoLocationManager } from "@kit.LocationKit";

/**
 * 模拟定位长时任务
 *
 * 说明：
 * - start() 只有在长时任务和定位订阅都成功后才返回 true；
 * - stop() 会取消定位订阅，避免开关关闭后仍在后台定位；
 * - 长时任务 ID 为 -1 时不会被当成“已启动”。
 */
export class BackgroundLocateService {
  private notificationId: number = -1
  private locationCallback: ((location: geoLocationManager.Location) => void) | undefined = undefined

  isRunning(): boolean {
    return this.notificationId > 0
  }

  async start(context: Context): Promise<boolean> {
    if (this.isRunning()) {
      return true
    }
    const id = await this.startContinuousTask(context)
    if (id < 0) {
      this.notificationId = -1
      hilog.error(0xFF00, 'BackgroundLocateService', '模拟定位长时任务启动失败')
      return false
    }
    this.notificationId = id
    const locationStarted = await this.getLocation(context)
    if (!locationStarted) {
      hilog.error(0xFF00, 'BackgroundLocateService', '定位订阅启动失败，回滚长时任务')
      await this.stop(context)
      return false
    }
    hilog.info(0xFF00, 'BackgroundLocateService', `模拟定位长时任务已启动 id=${id}`)
    return true
  }

  async requestPermissionsFromUser(context: Context): Promise<boolean> {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const permissionList: Permissions[] = [
      'ohos.permission.LOCATION',
      'ohos.permission.APPROXIMATELY_LOCATION'
    ];
    try {
      const result = await atManager.requestPermissionsFromUser(context, permissionList)
      // LOCATION / APPROXIMATELY_LOCATION 任一授权即可继续
      for (let i = 0; i < 2 && i < result.authResults.length; i++) {
        if (result.authResults[i] === 0) {
          return true
        }
      }
      hilog.warn(0xFF00, 'BackgroundLocateService', '定位权限未授予')
      return false
    } catch (e) {
      hilog.error(0xFF00, 'BackgroundLocateService', `申请定位权限失败: ${JSON.stringify(e) ?? ''}`)
      return false
    }
  }

  async getLocation(context: Context): Promise<boolean> {
    try {
      if (!geoLocationManager.isLocationEnabled()) {
        hilog.warn(0xFF00, 'BackgroundLocateService', '系统定位开关未开启')
        return false
      }
      const granted = await this.requestPermissionsFromUser(context)
      if (!granted) {
        return false
      }
      const request: geoLocationManager.LocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
        // 定期回调，避免系统判定“未使用定位”而回收 LOCATION 长时任务
        timeInterval: 60000,
        distanceInterval: 100,
        maxAccuracy: 1000
      }
      this.locationCallback = (location: geoLocationManager.Location) => {
        // 只需要保持定位业务活跃，不消费坐标
      }
      geoLocationManager.on('locationChange', request, this.locationCallback)
      return true
    } catch (e) {
      hilog.error(0xFF00, 'BackgroundLocateService', `启动定位订阅失败: ${JSON.stringify(e) ?? ''}`)
      return false
    }
  }

  async stop(context: Context): Promise<void> {
    if (this.locationCallback !== undefined) {
      try {
        geoLocationManager.off('locationChange', this.locationCallback)
      } catch (e) {
        hilog.warn(0xFF00, 'BackgroundLocateService', `取消定位订阅失败: ${JSON.stringify(e) ?? ''}`)
      }
      this.locationCallback = undefined
    }
    const wasRunning = this.isRunning()
    this.notificationId = -1
    if (!wasRunning) {
      return
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context)
      hilog.info(0xFF00, 'BackgroundLocateService', '模拟定位长时任务已停止')
    } catch (e) {
      hilog.error(0xFF00, 'BackgroundLocateService', `模拟定位长时任务停止失败: ${JSON.stringify(e) ?? ''}`)
    }
  }

  private async startContinuousTask(context: Context): Promise<number> {
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.applicationInfo.name,
          abilityName: "EntryAbility"
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    try {
      const wantAgentObj: WantAgent = await wantAgent.getWantAgent(wantAgentInfo)
      const res = await backgroundTaskManager.startBackgroundRunning(context, ["location"], wantAgentObj)
      return res.notificationId
    } catch (e) {
      hilog.error(0xFF00, 'BackgroundLocateService', `startBackgroundRunning(location) 失败: ${JSON.stringify(e) ?? ''}`)
      return -1
    }
  }
}

export default new BackgroundLocateService()
