import lazy { HdsTabs } from '@kit.UIDesignKit'
import type { HdsTabsFloatingStyle } from '@kit.UIDesignKit'
import { CircleShape } from '@kit.ArkUI'
import { UIConfig } from '../../entryability/AppState'
import { EventHub, EventKey } from '../../common/EventHub'
import { icon_tertiary } from './Common'
import { customAnimationUtil } from '../../common/utils/Animation'
import {
  hdsGlassBarStyle,
  immersiveButtonMaterial,
  isHdsImmersiveMaterialAvailable
} from '../../common/utils/ImmersiveMaterialUtil'

/**
 * @fileName:      FloatControlButton
 * @author:     SummerKaze
 * @description:  悬浮控制按钮组件
 * @date:    2026/2/8 17:03
 * @version:    1.0
 */

@Component
export struct FloatControlButton {
  /** @description 是否为左侧按钮 */
  isLeft: boolean = false
  /** @description 代理启动状态 */
  @Consume proxyEnabled: boolean
  /** @description 主题强调色 */
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  /** @description UI 配置 */
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  /** @description 宽度断点 */
  @StorageProp('currentWidthBreakpoint') widthBp: number = 1
  /** @description 沉浸光感支持 */
  @StorageProp('EnableUIMaterial') enableUIMaterial: boolean = false
  /** @description HDS 沉浸材质可用（HarmonyOS 7 上优先走 HDS 链路） */
  private hdsMaterialAvailable: boolean = false

  aboutToAppear(): void {
    this.hdsMaterialAvailable = isHdsImmersiveMaterialAvailable()
  }

  build() {
    if (this.useHdsGlassButton()) {
      // HDS 悬浮栏只有一个页签时就是一块圆形玻璃底
      HdsTabs({ barPosition: BarPosition.End }) {
        TabContent() {
        }
        .backgroundColor(Color.Transparent)
        .tabBar(this.VpnButton)
      }
      .barMode(BarMode.Fixed)
      .vertical(false)
      .barOverlap(true)
      .scrollable(false)
      .barHeight(60)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .barBackgroundStyle({ maskColor: Color.Transparent })
      .backgroundColor(Color.Transparent)
      .barFloatingStyle(this.getHdsGlassStyle())
      .height(60)
      .width(60)
      .clipShape(new CircleShape({ width: 60, height: 60 }))
      // 滑入/滑出 动画
      .transition(customAnimationUtil.getFloatButtonTransition(this.uiConfig, this.uiConfig.buttonPositionIndex))
    } else if (this.useGlassButton()) {
      // 需要材质时才放进 TabBar；否则 Tabs 的默认栏背景会在圆形按钮外留下方形底色
      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {
        }
        .tabBar(this.VpnButton)
      }
      .barMode(BarMode.Fixed)
      .barOverlap(true)
      .scrollable(false)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .barHeight(60)
      .height(60)
      .width(60)
      // 滑入/滑出 动画
      .transition(customAnimationUtil.getFloatButtonTransition(this.uiConfig, this.uiConfig.buttonPositionIndex))
    } else {
      Stack() {
        this.VpnButton()
      }
      .width(60)
      .height(60)
      .transition(customAnimationUtil.getFloatButtonTransition(this.uiConfig, this.uiConfig.buttonPositionIndex))
    }
  }

  useHdsGlassButton(): boolean {
    return !this.enableUIMaterial && this.hdsMaterialAvailable && !this.proxyEnabled
  }

  getHdsGlassStyle(): HdsTabsFloatingStyle | undefined {
    return this.useHdsGlassButton() ? hdsGlassBarStyle(60) : undefined
  }

  useGlassButton(): boolean {
    return this.enableUIMaterial && !this.proxyEnabled
  }

  isMaterialButton(): boolean {
    return this.useHdsGlassButton() || this.useGlassButton()
  }

  @Builder
  VpnButton() {
    Row() {
      SymbolGlyph(this.proxyEnabled ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
        .fontSize(27)
        .fontColor([this.proxyEnabled ? Color.White : icon_tertiary])
    }
    .functionButtonStyle(this.proxyEnabled && this.widthBp <= 2)
    .animation({ duration: this.uiConfig.animationSpeed, curve: Curve.Linear })
    // 背景模糊
    .backdropBlur(this.isMaterialButton() ? 0 :
      this.uiConfig.isBlurr && !this.proxyEnabled ? 30 : 0)
    .backgroundColor(
      this.isMaterialButton() ? Color.Transparent :
        this.proxyEnabled
        ? this.icon_emphasize
        : this.uiConfig.isBlurr
          ? $r('app.color.float_tab_background_blur')
          : $r('app.color.background')
    )
    // 材质自带阴影，避免再叠加一圈内影
    .shadow(this.isMaterialButton() ? { radius: 0, color: Color.Transparent } : {
      radius: 15,
      offsetY: 4,
      color: this.proxyEnabled ? this.icon_emphasize : $r('app.color.shadow_button'),
      type: ShadowType.COLOR
    })
    .systemMaterial(this.useGlassButton() ? immersiveButtonMaterial() : undefined)
    .onClick(() => {
      // 触发代理启动事件
      EventHub.sendEvent(EventKey.ChangeProxy)
    })
  }
}

/**
 * 功能按钮样式
 * @param during - 是否处于激活状态（代理已启动）
 */
@Extend(Row)
function functionButtonStyle(during: boolean) {
  .borderRadius(30)
  .padding(during ? { left: 8, right: 8 } : 0)
  .size({ width: 60, height: 60 })
  .justifyContent(FlexAlign.Center)
  .aspectRatio(1)
  .alignItems(VerticalAlign.Center)
}
