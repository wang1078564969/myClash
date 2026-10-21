import {  VpnExtensionAbility } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { SocketStubService } from 'proxy_core';
import { ClashCore } from './AppState';
import fs from  "@ohos.file.fs"
import { writeFile } from 'proxy_core/src/main/ets/fileUtils';
import util from '@ohos.util';


export default class ClashVpnAbility extends VpnExtensionAbility {

  clashStubService: SocketStubService | undefined
  constructor() {
    super();
  }
  async onCreate(want: Want) {
    try {
      let core = want.parameters?.["ClashCore"] as ClashCore ?? ClashCore.mihomo
      let requestId = (want.parameters?.["requestId"] as number) ?? 0
      if(core == ClashCore.mihomo){
        console.log("ClashBox", `启用核心 mihomo`);
        this.clashStubService = new SocketStubService(this.context)
        const started = await this.clashStubService.startService(requestId)
        if (!started) {
          console.error("ClashBox", `启用核心 mihomo 失败`);
          return
        }
        console.log("ClashBox", `启用核心 mihomo 成功`);
      }else{
        console.log("ClashBox", `前台模式`);
        // 前台模式的 VPN 内核由 UI 进程托管，这里只写锁文件用于 ChangeCore 握手
        await this.lockVpn(requestId)
      }
    } catch (e) {
      console.log("ClashBox", `启用VPN失败 ${e.message} ${e.stack}`);
    }
  }
  async lockVpn(local: number){
    let lockPath = this.context.filesDir + '/vpn_ipc.lock';
    let encoder = new util.TextEncoder()
    writeFile(lockPath, encoder.encodeInto(local + ""))
  }
  onDestroy(){
    console.log("ClashBox", `后台vpn服务(ClashVpnAbility) 退出`);
    this.clashStubService?.stopVpn();
    try {
      let lockPath = this.context.filesDir + '/vpn_ipc.lock';
      fs.unlinkSync(lockPath)
    } catch (e) {
      console.log("ClashBox", `清理 vpn_ipc.lock 失败 ${e.message}`);
    }
  }
};




