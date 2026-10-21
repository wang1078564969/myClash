import { UIConfig } from '../../entryability/AppState'
import { hilog } from '@kit.PerformanceAnalysisKit'

export interface DropRecord {
  time: number
  reason: string
  core: string
  keepAlive: string
}

/**
 * 掉线/保活诊断记录
 *
 * 记录写入 UIConfig（PersistentStorage），进程被杀/重启后仍可查看；
 * 最多保留 20 条，避免 Preferences 无限增长。
 */
class KeepAliveDiagnostics {
  private static instance: KeepAliveDiagnostics = new KeepAliveDiagnostics()
  private static readonly MAX_RECORDS: number = 20

  static getInstance(): KeepAliveDiagnostics {
    return KeepAliveDiagnostics.instance
  }

  recordDrop(reason: string, core: string, keepAlive: string): void {
    try {
      const uiConfig = AppStorage.get<UIConfig>('uiConfig')
      if (uiConfig === undefined) {
        return
      }
      const now = Date.now()
      let records = this.getRecords()
      records.unshift({ time: now, reason: reason, core: core, keepAlive: keepAlive })
      if (records.length > KeepAliveDiagnostics.MAX_RECORDS) {
        records = records.slice(0, KeepAliveDiagnostics.MAX_RECORDS)
      }
      uiConfig.dropRecords = JSON.stringify(records)
      uiConfig.lastDropReason = reason
      uiConfig.lastDropTime = now
      AppStorage.setOrCreate<UIConfig>('uiConfig', uiConfig)
      hilog.warn(0xFF00, 'KeepAliveDiagnostics', `记录掉线: ${reason}`)
    } catch (e) {
      hilog.error(0xFF00, 'KeepAliveDiagnostics', `记录掉线失败: ${JSON.stringify(e) ?? ''}`)
    }
  }

  getRecords(): DropRecord[] {
    try {
      const uiConfig = AppStorage.get<UIConfig>('uiConfig')
      if (uiConfig === undefined) {
        return []
      }
      const raw = uiConfig.dropRecords ?? '[]'
      if (raw === '') {
        return []
      }
      return JSON.parse(raw) as DropRecord[]
    } catch (e) {
      hilog.warn(0xFF00, 'KeepAliveDiagnostics', `解析掉线记录失败: ${JSON.stringify(e) ?? ''}`)
      return []
    }
  }

  getCount(): number {
    return this.getRecords().length
  }

  clear(): void {
    try {
      const uiConfig = AppStorage.get<UIConfig>('uiConfig')
      if (uiConfig !== undefined) {
        uiConfig.dropRecords = '[]'
        uiConfig.lastDropReason = ''
        uiConfig.lastDropTime = 0
        AppStorage.setOrCreate<UIConfig>('uiConfig', uiConfig)
      }
    } catch (e) {
      hilog.error(0xFF00, 'KeepAliveDiagnostics', `清空掉线记录失败: ${JSON.stringify(e) ?? ''}`)
    }
  }
}

export default KeepAliveDiagnostics.getInstance()
