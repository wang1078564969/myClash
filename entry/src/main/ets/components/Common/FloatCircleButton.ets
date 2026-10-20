import { CircleShape } from '@kit.ArkUI'
import lazy { HdsTabs } from '@kit.UIDesignKit'
import { UIConfig } from '../../entryability/AppState'
import { icon_tertiary } from './Common'
import {
  hdsGlassBarStyle,
  immersiveButtonMaterial,
  isHdsImmersiveMaterialAvailable
} from '../../common/utils/ImmersiveMaterialUtil'

/**
 * 悬浮圆形按钮：材质开启时用单页签栏承载，材质不可用时保持原有模糊圆底。
 */
@Component
export struct FloatCircleButton {
  icon: Resource = $r('sys.symbol.plus')
  buttonSize: number = 50
  onTap: () => void = () => {}
  @StorageProp('EnableUIMaterial') enableUIMaterial: boolean = false
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  private hdsMaterialAvailable: boolean = false

  aboutToAppear(): void {
    this.hdsMaterialAvailable = isHdsImmersiveMaterialAvailable()
  }

  build() {
    if (this.useHdsMaterial()) {
      HdsTabs({ barPosition: BarPosition.End }) {
        TabContent() {
        }
        .backgroundColor(Color.Transparent)
        .tabBar(this.ButtonContent)
      }
      .barMode(BarMode.Fixed)
      .vertical(false)
      .barOverlap(true)
      .scrollable(false)
      .barHeight(this.buttonSize)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .barBackgroundStyle({ maskColor: Color.Transparent })
      .backgroundColor(Color.Transparent)
      .barFloatingStyle(hdsGlassBarStyle(this.buttonSize))
      .width(this.buttonSize)
      .height(this.buttonSize)
      .clipShape(new CircleShape({ width: this.buttonSize, height: this.buttonSize }))
    } else if (this.useUiMaterial()) {
      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {
        }
        .backgroundColor(Color.Transparent)
        .tabBar(this.ButtonContent)
      }
      .barMode(BarMode.Fixed)
      .barOverlap(true)
      .scrollable(false)
      .barHeight(this.buttonSize)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .backgroundColor(Color.Transparent)
      .width(this.buttonSize)
      .height(this.buttonSize)
      .clipShape(new CircleShape({ width: this.buttonSize, height: this.buttonSize }))
    } else {
      this.ButtonContent()
    }
  }

  private useHdsMaterial(): boolean {
    return !this.enableUIMaterial && this.hdsMaterialAvailable
  }

  private useUiMaterial(): boolean {
    return this.enableUIMaterial
  }

  private useMaterial(): boolean {
    return this.useHdsMaterial() || this.useUiMaterial()
  }

  @Builder
  ButtonContent() {
    Row() {
      SymbolGlyph(this.icon)
        .fontSize(27)
        .fontColor([icon_tertiary])
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .justifyContent(FlexAlign.Center)
    .borderRadius(this.buttonSize / 2)
    .backdropBlur(this.useMaterial() ? 0 : this.uiConfig.isBlurr ? 30 : 0)
    .backgroundColor(this.useMaterial() ? Color.Transparent :
      this.uiConfig.isBlurr ? $r('app.color.float_tab_background_blur') : $r('app.color.background'))
    // 材质自带阴影，避免再叠加一层内影
    .shadow(this.useMaterial() ? { radius: 0, color: Color.Transparent } : {
      radius: 15,
      offsetY: 4,
      color: $r('app.color.shadow_button'),
      type: ShadowType.COLOR
    })
    .systemMaterial(this.useUiMaterial() ? immersiveButtonMaterial() : undefined)
    .onClick(() => {
      this.onTap()
    })
  }
}
