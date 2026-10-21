import { Context, WantAgent, wantAgent } from "@kit.AbilityKit";
import { backgroundTaskManager } from "@kit.BackgroundTasksKit";
import { notificationManager } from "@kit.NotificationKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { AppConfig, AppFlowingState } from "../../entryability/AppState";

/**
 * 长时后台下载服务
 * 负责展示持续的下载进度通知（例如 VPN 流量监控）
 *
 * 说明：start() 必须等到首条进度通知成功发布才返回 true；
 * 否则 DATA_TRANSFER 长时任务会在 10 分钟后被系统取消。
 */
export class BackgroundDownService {
  private notificationId: number = -1;
  private noticeTimer: number = -1;

  isRunning(): boolean {
    return this.notificationId > 0
  }

  /**
   * 启动后台任务与通知
   */
  async start(context: Context): Promise<boolean> {
    if (this.isRunning()) {
      hilog.info(0xFF00, "BackgroundDownService", "任务已在运行，无需重复启动");
      return true;
    }

    const id = await this.startContinuousTask(context);
    if (id < 0) {
      hilog.error(0xFF00, "BackgroundDownService", "无法启动后台长时任务");
      this.notificationId = -1
      return false;
    }

    this.notificationId = id;

    if (this.noticeTimer !== -1) {
      clearInterval(this.noticeTimer)
      this.noticeTimer = -1
    }
    const notified = await this.updateTraffic()
    if (!notified) {
      hilog.error(0xFF00, "BackgroundDownService", "首条进度通知失败，回滚长时任务")
      await this.stop(context)
      return false
    }

    // 定期更新通知内容，满足 DATA_TRANSFER 的进度更新约束
    this.noticeTimer = setInterval(async () => {
      await this.updateTraffic();
    }, 10000);

    hilog.info(0xFF00, "BackgroundDownService", "后台长时任务已启动");
    return true
  }

  /**
   * 停止后台任务
   */
  async stop(context: Context): Promise<void> {
    if (this.noticeTimer !== -1) {
      clearInterval(this.noticeTimer);
      this.noticeTimer = -1;
    }

    const wasRunning = this.isRunning()
    this.notificationId = -1;
    if (!wasRunning) {
      return
    }
    hilog.info(0xFF00, "BackgroundDownService", "准备停止后台任务");

    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      hilog.info(0xFF00, "BackgroundDownService", "后台任务停止成功");
    } catch (err) {
      hilog.error(
        0xFF00,
        "BackgroundDownService",
        `后台任务停止失败：${JSON.stringify(err)}`
      );
    }
  }

  /**
   * 定时更新下载进度通知
   */
  async updateTraffic(): Promise<boolean> {
    try {
      const appConfig: AppConfig =
        AppStorage.get<AppConfig>("appConfig") ?? new AppConfig();
      const appFlowingState: AppFlowingState =
        AppStorage.get<AppFlowingState>("appFlowingState") ?? new AppFlowingState();

      const lastTraffic = appFlowingState.traffics.getLast?.();
      const downSpeed = lastTraffic?.down?.toString() ?? "0";
      const upSpeed = lastTraffic?.up?.toString() ?? "0";

      const message = `${upSpeed}/s ↑ ${downSpeed}/s ↓`;
      const proxyName = appConfig.currentProxyName ?? "ClashBox";

      hilog.info(
        0xFF00,
        "BackgroundDownService",
        `updateTraffic -> ${message}`
      );

      if (!this.isRunning()) {
        return false
      }
      return await this.updateProcess(this.notificationId, proxyName, message, 50);
    } catch (err) {
      hilog.error(
        0xFF00,
        "BackgroundDownService",
        `updateTraffic 异常: ${JSON.stringify(err)}`
      );
      return false
    }
  }

  /**
   * 更新系统下载通知进度条
   */
  private async updateProcess(id: number, title: string, message: string, progress: number): Promise<boolean> {
    try {
      const supported = await notificationManager.isSupportTemplate("downloadTemplate")
      if (!supported) {
        hilog.error(0xFF00, "BackgroundDownService", "设备不支持下载模板通知");
        return false;
      }

      const template: notificationManager.NotificationTemplate = {
        name: "downloadTemplate",
        data: {
          title: message,
          fileName: "VPN隧道数据传输中,删除通知隧道失效",
          progressValue: progress,
        },
      };

      const request: notificationManager.NotificationRequest = {
        id,
        notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        template,
        content: {
          notificationContentType:
          notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            typeCode: 8,
            title,
            text: message,
          },
        },
      };

      await notificationManager.publish(request)
      hilog.info(0xFF00, "BackgroundDownService", `通知更新成功 id=${id}`);
      return true
    } catch (err) {
      hilog.error(
        0xFF00,
        "BackgroundDownService",
        `通知发布失败: ${JSON.stringify(err)}`
      );
      return false
    }
  }

  /**
   * 启动 HarmonyOS 后台长时任务
   */
  private async startContinuousTask(context: Context): Promise<number> {
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.applicationInfo.name,
          abilityName: "EntryAbility",
        },
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };

    try {
      const wantAgentObj: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      const result = await backgroundTaskManager.startBackgroundRunning(
        context,
        ["dataTransfer"],
        wantAgentObj
      );
      hilog.info(
        0xFF00,
        "BackgroundDownService",
        `长时任务启动成功 notificationId=${result.notificationId}`
      );
      return result.notificationId;
    } catch (err) {
      hilog.error(
        0xFF00,
        "BackgroundDownService",
        `长时任务启动失败: Code=${err.code}, Msg=${err.message}`
      );
      return -1;
    }
  }
}

export default new BackgroundDownService();
