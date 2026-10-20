import { uiMaterial } from '@kit.ArkUI'
import lazy { hdsMaterial } from '@kit.UIDesignKit'
import type { HdsTabsFloatingStyle, SystemMaterialParams } from '@kit.UIDesignKit'

/**
 * 沉浸光感材质统一入口。
 * 应用级开关由 module.json5 的 ohos.arkui.UIMaterial.state 控制，
 * EntryAbility 在运行时把设备能力写入 EnableUIMaterial，这里统一做能力兜底。
 */
export function isImmersiveMaterialEnabled(): boolean {
  return AppStorage.get<boolean>('EnableUIMaterial') === true
}

let hdsImmersiveAvailable: boolean | undefined = undefined

/**
 * HDS 沉浸材质能力。HarmonyOS 7 上自定义节点的 uiMaterial 可能不渲染，
 * 而 HDS（HdsTabs 等）走独立材质链路仍然正常，因此页签栏等载体优先使用 HDS。
 */
export function isHdsImmersiveMaterialAvailable(): boolean {
  if (hdsImmersiveAvailable !== undefined) {
    return hdsImmersiveAvailable
  }
  let available = false
  if (canIUse('SystemCapability.UIDesign.HDSComponent.Core')) {
    try {
      available = hdsMaterial.getSystemMaterialTypes().indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0
    } catch (error) {
      available = false
    }
  }
  hdsImmersiveAvailable = available
  return available
}

export function hdsTabBarMaterialEffect(): SystemMaterialParams | undefined {
  if (!isHdsImmersiveMaterialAvailable()) {
    return undefined
  }
  return {
    materialType: hdsMaterial.MaterialType.IMMERSIVE,
    materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
  }
}

/** 固定宽度的 HDS 悬浮材质栏，用于把单个圆形按钮包成玻璃胶囊 */
export function hdsGlassBarStyle(barWidth: number): HdsTabsFloatingStyle | undefined {
  const effect = hdsTabBarMaterialEffect()
  if (effect === undefined) {
    return undefined
  }
  return {
    barWidth: { smallWidth: barWidth, mediumWidth: barWidth, largeWidth: barWidth },
    barSideMargin: 0,
    barBottomMargin: 0,
    gradientMask: { maskColor: Color.Transparent },
    systemMaterialEffect: effect
  }
}

function createImmersiveMaterial(style: uiMaterial.ImmersiveStyle, interactive: boolean = false,
  colorInvert: boolean = false, lightEffect: boolean = false): uiMaterial.ImmersiveMaterial | undefined {
  if (!isImmersiveMaterialEnabled()) {
    return undefined
  }
  return new uiMaterial.ImmersiveMaterial({
    style: style,
    interactive: interactive,
    colorInvert: colorInvert,
    lightEffect: lightEffect ? { color: Color.White } : undefined
  })
}

/** 按钮：按压形变，不开触点光效，避免圆钮内部出现光晕圆环 */
export function immersiveButtonMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return createImmersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, true, false)
}

/** 底部页签栏：光感反馈，但整条栏不做形变 */
export function immersiveTabBarMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return createImmersiveMaterial(uiMaterial.ImmersiveStyle.THIN, false, false, true)
}

/** 搜索框：超薄材质，保持输入区域通透 */
export function immersiveSearchMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return createImmersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN)
}

/** 下拉按钮：超薄材质 + 交互形变 + 光感反馈 */
export function immersiveSelectMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return createImmersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true, false, true)
}

/** 半模态：常规厚度，兼顾大面积内容的可读性 */
export function immersiveSheetMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return createImmersiveMaterial(uiMaterial.ImmersiveStyle.REGULAR)
}

/** Popup：较厚材质，与底层内容拉开层次 */
export function immersivePopupMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return createImmersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
}

/** 菜单：较厚材质，保证菜单项可读 */
export function immersiveMenuMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return createImmersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
}

/** Navigation/NavDestination 标题栏：薄材质，保留标题区域通透感 */
export function immersiveTitleBarMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return createImmersiveMaterial(uiMaterial.ImmersiveStyle.THIN)
}

/** 沉浸光感开启时让内容根节点透出材质，关闭时保留原背景色 */
export function immersiveSurfaceColor(fallback: ResourceColor): ResourceColor {
  return isImmersiveMaterialEnabled() ? Color.Transparent : fallback
}
