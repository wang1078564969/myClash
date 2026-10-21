import { WantAgent, wantAgent } from "@kit.AbilityKit";
import { backgroundTaskManager } from "@kit.BackgroundTasksKit";
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * TASK_KEEPING 长时任务（仅平板 / PC）
 * 与 xb_components 中的旧实现相比，这里返回真实启动结果，供 KeepAliveManager fallback。
 */
class TaskKeepingService {
  private active: boolean = false

  isRunning(): boolean {
    return this.active
  }

  async start(context: Context): Promise<boolean> {
    if (this.active) {
      return true
    }
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.applicationInfo.name,
          abilityName: "EntryAbility"
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    try {
      const wantAgentObj: WantAgent = await wantAgent.getWantAgent(wantAgentInfo)
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.TASK_KEEPING, wantAgentObj)
      this.active = true
      console.info("Operation startBackgroundRunning(TASK_KEEPING) succeeded");
      return true
    } catch (error) {
      this.active = false
      console.error(`Operation startBackgroundRunning(TASK_KEEPING) failed. code is ${(error as BusinessError).code} message is ${(error as BusinessError).message}`);
      return false
    }
  }

  async stop(context: Context): Promise<void> {
    if (!this.active) {
      return
    }
    this.active = false
    try {
      await backgroundTaskManager.stopBackgroundRunning(context)
      console.info("Operation stopBackgroundRunning(TASK_KEEPING) succeeded");
    } catch (err) {
      console.error(`Operation stopBackgroundRunning(TASK_KEEPING) failed. code is ${(err as BusinessError).code} message is ${(err as BusinessError).message}`);
    }
  }
}

export default new TaskKeepingService()
