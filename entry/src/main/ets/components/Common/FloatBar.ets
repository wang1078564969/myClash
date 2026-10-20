import { CircleShape, curves, LengthMetrics } from '@kit.ArkUI'
import lazy { HdsAnimationMode, HdsTabs, HdsTabsController } from '@kit.UIDesignKit'
import type { HdsTabsFloatingStyle } from '@kit.UIDesignKit'
import { UIConfig } from '../../entryability/AppState'
import {
  hdsGlassBarStyle,
  hdsTabBarMaterialEffect,
  immersiveButtonMaterial,
  immersiveTabBarMaterial
} from '../../common/utils/ImmersiveMaterialUtil'
import { TabBuild } from '../../common/entity/PageArgumentEntity'
import { customAnimationUtil } from '../../common/utils/Animation'
import {
  Xb_FloatTabBarDirection,
  Xb_FloatTabBarPadding,
  Xb_TabBarVertical,
  Xb_TabIconFontSize,
  Xb_TabTitleFontSize
} from 'xb_components'
import { Xb_AnimationStyle } from 'xb_components'
import { FloatControlButton } from './FloatControlButton'
import { FloatTabBarHeight } from '../../common/breakpoint/BreakPoint'

/**
 * @fileName:      FloatBar
 * @author:     SummerKaze
 * @description:  悬浮 Tab 栏组件
 * @date:    2026/2/8 17:03
 * @version:    1.0
 */

@Component
export struct FloatBar {
  // 必传属性
  /** @description Tab 列表数据 */
  @Require tabList: TabBuild[] = []
  /** @description Swiper 控制器（与 FloatTab 中的 Swiper 共享） */
  @Require swiperController: SwiperController = new SwiperController()
  // @Consume 父子共享属性
  /** @description 当前选中的 Tab 页索引 */
  @Consume @Watch('onTabPageChanged') tabCurrentPage: number
  /** @description 列表是否正在滚动（控制 Tab 栏折叠） */
  @Consume @Watch('onRollingChanged') isRolling: boolean
  /** @description 主题强调色 */
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  // @StorageLink / @StorageProp 全局共享属性
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @StorageProp('currentWidthBreakpoint') widthBp: number = 1
  @StorageProp('currentHeightBreakpoint') heightBp: number = 0
  @StorageProp('topRectHeight') topRectHeight: number = 0
  @StorageProp('bottomRectHeight') bottomRectHeight: number = 0
  @StorageProp('LeftAvoidWidth') leftAvoidWidth: number = 0
  @StorageProp('WindowMode') windowMode: boolean = false
  @StorageProp('EnableUIMaterial') enableUIMaterial: boolean = false
  /** 系统悬浮页签栏控制器（沉浸光感材质） */
  private glassBarController: TabsController = new TabsController()
  /** HDS 悬浮页签栏控制器（系统材质与原生显隐动效的载体） */
  private hdsBarController: HdsTabsController | undefined = undefined
  private hdsBarAvailable: boolean = false
  /** 页签栏槽位实测宽度，用于 HDS 栏宽与无 HDS 时的弹性收缩 */
  @State barAreaWidth: number = 0
  /** 折叠进度（0 展开，1 圆钮），驱动圆钮淡入淡出与无 HDS 时的栏宽收缩 */
  @State collapseProgress: number = 0
  /** HDS 页签栏当前是否处于系统隐藏态，隐藏时需放行穿透点击 */
  @State hdsBarHidden: boolean = false

  aboutToAppear(): void {
    this.hdsBarAvailable = hdsTabBarMaterialEffect() !== undefined
    if (this.hdsBarAvailable) {
      this.hdsBarController = new HdsTabsController()
    }
    this.collapseProgress = this.isRollingCircle() ? 1 : 0
  }

  /** 滚动状态变化：HDS 载体走系统原生显隐动效，圆钮同步弹性淡入淡出 */
  onRollingChanged(): void {
    const target = this.isRollingCircle() ? 1 : 0
    if (this.useHdsTabBar()) {
      this.applyHdsBarVisibility(target === 0)
    }
    if (this.collapseProgress === target) {
      return
    }
    this.getUIContext().animateTo({
      duration: this.uiConfig.animationSpeed,
      curve: curves.springMotion(0.5, 0.7)
    }, () => {
      this.collapseProgress = target
    })
  }

  /** 调用 HDS 控制器播放页签栏的系统隐藏/显示动效 */
  private applyHdsBarVisibility(visible: boolean): void {
    if (this.hdsBarController === undefined || this.hdsBarHidden === !visible) {
      return
    }
    this.hdsBarHidden = !visible
    try {
      if (visible) {
        this.hdsBarController.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION)
      } else {
        this.hdsBarController.applyHideAnimation(HdsAnimationMode.SCROLL_ANIMATION)
      }
    } catch (error) {
      this.hdsBarHidden = visible
    }
  }

  build() {
    Flex({
      direction: Xb_FloatTabBarDirection(this.widthBp, this.heightBp),
      justifyContent: this.widthBp < 2 ? FlexAlign.SpaceBetween : FlexAlign.Center,
      alignItems: this.widthBp < 2 ? ItemAlign.Center : ItemAlign.Start,
      space: { main: LengthMetrics.vp(10) }
    }) {
      // 左侧控制按钮
      if (this.uiConfig.buttonPositionIndex === 2) {
        FloatControlButton({ isLeft: true })
      }

      if (this.useSystemTabBar()) {
        // 页签栏槽位：uiMaterial 走 Tabs 悬浮栏，HDS 走系统悬浮栏，两者都不可用时用同形玻璃背板兜底
        Stack({ alignContent: Alignment.Start }) {
          if (!this.useHdsTabBar() && !this.enableUIMaterial) {
            Row()
              .width('100%')
              .height('100%')
              .borderRadius(30)
              .backdropBlur(this.uiConfig.isBlurr ? 30 : 0)
              .backgroundColor(this.uiConfig.isBlurr ? $r('app.color.float_tab_background_blur') :
                $r('app.color.background'))
              .shadow({
                radius: 15,
                offsetY: 4,
                color: $r('app.color.shadow_button'),
                type: ShadowType.COLOR,
              })
          }
          if (this.useHdsTabBar()) {
            // 统一由 HDS 承载系统材质与滚动显隐动效
            HdsTabs({
              barPosition: BarPosition.End,
              index: this.tabCurrentPage,
              controller: this.hdsBarController
            }) {
              ForEach(this.tabList, (item: TabBuild, index: number) => {
                TabContent() {
                }
                  .backgroundColor(Color.Transparent)
                  .tabBar(this.ImmersiveTabItem(item, index))
              })
            }
            .barMode(BarMode.Fixed)
            .vertical(false)
            .barOverlap(true)
            .scrollable(false)
            .barHeight(FloatTabBarHeight(this.widthBp, this.heightBp))
            .barBackgroundColor(Color.Transparent)
            .barBackgroundBlurStyle(BlurStyle.NONE)
            .backgroundColor(Color.Transparent)
            .barFloatingStyle(this.getHdsTabBarStyle())
            .width('100%')
            .height('100%')
            // 系统隐藏后节点仍在树上，需连同内部子节点一起退出触摸测试
            .hitTestBehavior(this.hdsBarHidden ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.Default)
            .onChange((index: number) => {
              Xb_AnimationStyle.animToAPI18(() => {
                this.tabCurrentPage = index
              }, this.uiConfig.animationSpeed, 'app')
              this.swiperController.changeIndex(index, true)
            })
            .onAppear(() => {
              this.swiperController.changeIndex(this.tabCurrentPage, true)
              // 挂载时与控制器的显隐意图对齐（例如启动即处于滚动收起态）
              this.hdsBarHidden = false
              this.applyHdsBarVisibility(!this.isRollingCircle())
            })
          } else {
            Tabs({
              barPosition: BarPosition.End,
              index: this.tabCurrentPage,
              controller: this.glassBarController
            }) {
              ForEach(this.tabList, (item: TabBuild, index: number) => {
                TabContent() {
                }
                  .backgroundColor(Color.Transparent)
                  .tabBar(this.ImmersiveTabItem(item, index))
              })
            }
            .barMode(BarMode.Fixed)
            .barOverlap(this.enableUIMaterial)
            .scrollable(false)
            .barHeight(FloatTabBarHeight(this.widthBp, this.heightBp))
            .barBackgroundColor(Color.Transparent)
            .barBackgroundBlurStyle(BlurStyle.NONE)
            .backgroundColor(Color.Transparent)
            .barFloatingStyle(this.getImmersiveTabBarStyle())
            .width(this.getCollapseBarWidth())
            .height('100%')
            .onChange((index: number) => {
              Xb_AnimationStyle.animToAPI18(() => {
                this.tabCurrentPage = index
              }, this.uiConfig.animationSpeed, 'app')
              this.swiperController.changeIndex(index, true)
            })
            .onAppear(() => {
              this.swiperController.changeIndex(this.tabCurrentPage, true)
            })
          }
          // 收缩终点：HDS 原生隐藏后保留当前页签圆钮，随折叠进度在栏左端放大淡入
          if (this.useHdsTabBar()) {
            HdsTabs({ barPosition: BarPosition.End }) {
              TabContent() {
              }
              .backgroundColor(Color.Transparent)
              .tabBar(this.RollingCircleContent)
            }
            .barMode(BarMode.Fixed)
            .vertical(false)
            .barOverlap(true)
            .scrollable(false)
            .barHeight(60)
            .barBackgroundColor(Color.Transparent)
            .barBackgroundBlurStyle(BlurStyle.NONE)
            .barBackgroundStyle({ maskColor: '#00000000' })
            .backgroundColor(Color.Transparent)
            .barFloatingStyle(hdsGlassBarStyle(60))
            .width(60)
            .height(60)
            .clipShape(new CircleShape({ width: 60, height: 60 }))
            .opacity(this.getCollapseCircleOpacity())
            .scale({
              x: 0.7 + 0.3 * this.getCollapseCircleOpacity(),
              y: 0.7 + 0.3 * this.getCollapseCircleOpacity()
            })
            .hitTestBehavior(this.getCollapseCircleOpacity() > 0.5 ? HitTestMode.Default : HitTestMode.None)
          } else if (this.useSpringCollapse()) {
            // 沉浸光感圆钮直接用普通节点承载材质，避免 Tabs 页签内容不随当前页刷新
            Stack() {
              this.RollingCircleContent()
            }
            .width(60)
            .height(60)
            .clipShape(new CircleShape({ width: 60, height: 60 }))
            .opacity(this.getCollapseCircleOpacity())
            .scale({
              x: 0.7 + 0.3 * this.getCollapseCircleOpacity(),
              y: 0.7 + 0.3 * this.getCollapseCircleOpacity()
            })
            .hitTestBehavior(this.getCollapseCircleOpacity() > 0.5 ? HitTestMode.Default : HitTestMode.None)
          }
        }
        .height(FloatTabBarHeight(this.widthBp, this.heightBp))
        .layoutWeight(1)
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.barAreaWidth = Number(newValue.width)
        })
        .transition(customAnimationUtil.isOpacity(this.uiConfig))
      } else {
        // 原自定义胶囊（滚动折叠、平板竖排等场景）
        Flex({
          direction: Xb_FloatTabBarDirection(this.widthBp, this.heightBp),
          justifyContent: FlexAlign.SpaceAround,
          alignItems: ItemAlign.Center,
          space: { main: LengthMetrics.vp(10) }
        }) {
          if (this.isRollingCircle()) {
            // 滚动状态：仅显示当前 Tab 图标，圆钮同样走沉浸材质
            if (this.useHdsRollingMaterial()) {
              HdsTabs({ barPosition: BarPosition.End }) {
                TabContent() {
                }
                .backgroundColor(Color.Transparent)
                .tabBar(this.RollingCircleContent)
              }
              .barMode(BarMode.Fixed)
              .vertical(false)
              .barOverlap(true)
              .scrollable(false)
              .barHeight(60)
              .barBackgroundColor(Color.Transparent)
              .barBackgroundBlurStyle(BlurStyle.NONE)
              .barBackgroundStyle({ maskColor: '#00000000' })
              .backgroundColor(Color.Transparent)
              .barFloatingStyle(hdsGlassBarStyle(60))
              .width(60)
              .height(60)
              .clipShape(new CircleShape({ width: 60, height: 60 }))
              .transition(this.getRollingCircleTransition())
            } else if (this.useUiRollingMaterial()) {
              Tabs({ barPosition: BarPosition.End }) {
                TabContent() {
                }
                .backgroundColor(Color.Transparent)
                .tabBar(this.RollingCircleContent)
              }
              .barMode(BarMode.Fixed)
              .barOverlap(true)
              .scrollable(false)
              .barHeight(60)
              .barBackgroundColor(Color.Transparent)
              .barBackgroundBlurStyle(BlurStyle.NONE)
              .backgroundColor(Color.Transparent)
              .width(60)
              .height(60)
              .clipShape(new CircleShape({ width: 60, height: 60 }))
              .transition(this.getRollingCircleTransition())
            } else {
              Column() {
                SymbolGlyph(this.tabList[this.tabCurrentPage].icon)
                  .fontSize(27)
                  .fontColor([this.icon_emphasize])
                  .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
              }
              .size({ width: 60, height: 60 })
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .onClick(() => {
                this.isRolling = false
              })
              .transition(this.getRollingCircleTransition())
            }
          } else {
            // 正常状态：显示所有 Tab 图标
            ForEach(this.tabList, (item: TabBuild, index: number) => {
              Column() {
                SymbolGlyph(item.icon)
                  .fontSize(Xb_TabIconFontSize(this.widthBp, this.heightBp))
                  .fontColor([this.tabCurrentPage === index ? this.icon_emphasize : $r('sys.color.icon_tertiary')])
                  .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
                  .translate({ y: this.tabCurrentPage == index ? -2 : 0 })
                  .animation(Xb_AnimationStyle.animNormalUtils(0))
                Text(item.name)
                  .fontColor(this.tabCurrentPage === index ? this.icon_emphasize : $r('sys.color.icon_tertiary'))
                  .fontSize(Xb_TabTitleFontSize(this.widthBp, this.heightBp))
              }
              .width(60)
              .height(60)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .onClick(() => {
                Xb_AnimationStyle.animToAPI18(() => {
                  this.tabCurrentPage = index
                }, this.uiConfig.animationSpeed, 'app')
                this.swiperController.changeIndex(index, true)
              })
              .transition(customAnimationUtil.isSlideScaleBigMove(this.uiConfig))
            })
          }
        }
        .transition(customAnimationUtil.isOpacity(this.uiConfig))
        .padding(this.isRollingCircle() ? 0 :
          Xb_FloatTabBarPadding(this.widthBp, this.heightBp))
        .width((!this.isRolling && this.widthBp < 2) ? '100%' : 'auto')
        .height(FloatTabBarHeight(this.widthBp, this.heightBp))
        .layoutWeight((!this.isRolling && this.widthBp < 2) ? 1 : undefined)
        .borderRadius(30)
        // 材质圆钮自带背板，外层不再叠模糊和阴影
        .backdropBlur(this.useRollingMaterial() ? 0 : this.uiConfig.isBlurr ? 30 : 0)
        .backgroundColor(this.useRollingMaterial() ? Color.Transparent :
          this.uiConfig.isBlurr ? $r('app.color.float_tab_background_blur') : $r('app.color.background'))
        .animation({ duration: this.uiConfig.animationSpeed, curve: Curve.Linear })
        .shadow(this.useRollingMaterial() ? { radius: 0, color: Color.Transparent } : {
          radius: 15,
          offsetY: 4,
          color: $r('app.color.shadow_button'),
          type: ShadowType.COLOR,
        })
        .onAppear(() => {
          this.swiperController.changeIndex(this.tabCurrentPage, true)
        })
      }

      // 右侧控制按钮
      if (this.uiConfig.buttonPositionIndex === 0) {
        FloatControlButton({ isLeft: false })
      }
    }
    .height(FloatTabBarHeight(this.widthBp, this.heightBp))
    .width(this.widthBp < 2 ? '100%' : 'auto')
    // 页签栏系统隐藏后整层放行，让底部被覆盖的内容仍可点击
    .hitTestBehavior(this.hdsBarHidden ? HitTestMode.Transparent : HitTestMode.Default)
    .padding({
      left: 10,
      right: 10,
      top: this.topRectHeight === 0 ? 10 : 0,
      bottom: this.topRectHeight === 0 ? 10 : 0
    })
    .margin({
      bottom: this.getFloatBottom(),
      top: this.windowMode ? 0 : this.topRectHeight,
      left: (this.leftAvoidWidth != 0 && !this.windowMode) ? this.leftAvoidWidth + 19 : 0,
    })
  }

  /** 手机滚动时页签栏收缩为单个圆钮 */
  private isRollingCircle(): boolean {
    return this.isRolling && this.uiConfig.isAnimation && this.widthBp < 2
  }

  private useHdsRollingMaterial(): boolean {
    return !this.enableUIMaterial && this.hdsBarAvailable && this.isRollingCircle()
  }

  private useUiRollingMaterial(): boolean {
    return this.enableUIMaterial && this.isRollingCircle()
  }

  private useRollingMaterial(): boolean {
    return this.useHdsRollingMaterial() || this.useUiRollingMaterial()
  }

  /** 有材质时保留系统页签栏；无材质时仍走原模糊圆钮兜底 */
  private useMaterialCollapse(): boolean {
    return this.enableUIMaterial || this.hdsBarAvailable
  }

  /** 无 HDS 的材质载体仍用宽度弹性收缩 + 圆钮完成折叠 */
  private useSpringCollapse(): boolean {
    return this.useMaterialCollapse() && !this.useHdsTabBar()
  }

  private getCollapseBarWidth(): Length {
    if (this.barAreaWidth <= 0) {
      return '100%'
    }
    if (!this.useMaterialCollapse()) {
      return this.barAreaWidth
    }
    const width = this.barAreaWidth - (this.barAreaWidth - 60) * this.collapseProgress
    return Math.max(0, width)
  }

  /** 收缩时页签内容先快速淡出，避免被压窄后文字竖排、图标重叠 */
  private getCollapseContentOpacity(): number {
    return Math.max(0, 1 - this.collapseProgress * 3)
  }

  /** 圆钮在栏收窄到后段时淡入，与收缩过程无缝衔接 */
  private getCollapseCircleOpacity(): number {
    return Math.max(0, (this.collapseProgress - 0.4) / 0.6)
  }

  /** 收缩圆钮与整条栏互换时的缩放/淡入动画 */
  private getRollingCircleTransition(): TransitionEffect {
    if (!this.uiConfig.isAnimation) {
      return TransitionEffect.IDENTITY
    }
    return TransitionEffect.OPACITY
      .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
      .animation({ duration: this.uiConfig.animationSpeed, curve: curves.springMotion() })
  }

  @Builder
  RollingCircleContent() {
    Row() {
      SymbolGlyph(this.tabList[this.tabCurrentPage].icon)
        .fontSize(27)
        .fontColor([this.icon_emphasize])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
    }
    .width(60)
    .height(60)
    .justifyContent(FlexAlign.Center)
    .borderRadius(30)
    .backgroundColor(Color.Transparent)
    // HDS 圆钮由外层 HdsTabs 提供材质，避免叠两层
    .systemMaterial(this.enableUIMaterial && !this.useHdsTabBar() ? immersiveButtonMaterial() : undefined)
    .onClick(() => {
      this.isRolling = false
    })
  }

  /** 手机横向布局使用系统页签栏，保证材质与兜底背板共用同一套栏结构 */
  useSystemTabBar(): boolean {
    return this.widthBp < 2 && !Xb_TabBarVertical(this.widthBp, this.heightBp) &&
      !(this.isRolling && this.uiConfig.isAnimation && !this.useMaterialCollapse())
  }

  /** 沉浸光感可用时用可收缩宽度的 Tabs；仅材质能力缺失时才退回 HDS 载体 */
  useHdsTabBar(): boolean {
    return !this.enableUIMaterial && this.hdsBarAvailable && this.hdsBarController !== undefined &&
      this.useSystemTabBar()
  }

  getHdsTabBarStyle(): HdsTabsFloatingStyle | undefined {
    if (!this.useHdsTabBar()) {
      return undefined
    }
    const effect = hdsTabBarMaterialEffect()
    if (effect === undefined) {
      return undefined
    }
    // HDS 默认栏宽按页签数计算，会超出两侧悬浮按钮之间的空位，按实测槽宽收窄
    const slotWidth = this.barAreaWidth
    return {
      barWidth: slotWidth > 0 ? {
        smallWidth: slotWidth,
        mediumWidth: slotWidth,
        largeWidth: slotWidth
      } : undefined,
      barSideMargin: 0,
      barBottomMargin: 0,
      gradientMask: { maskColor: '#00000000' },
      systemMaterialEffect: effect
    }
  }

  /** 沉浸光感 Tabs 页签栏仅在 HDS 不可用时作为材质载体 */
  useImmersiveTabBar(): boolean {
    return this.enableUIMaterial && !this.useHdsTabBar() && this.useSystemTabBar()
  }

  getImmersiveTabBarStyle(): FloatingTabBarStyle | undefined {
    if (!this.useImmersiveTabBar()) {
      return undefined
    }
    const material = immersiveTabBarMaterial()
    if (material === undefined) {
      return undefined
    }
    return {
      barSideMargin: 0,
      barBottomMargin: 0,
      // 关闭悬浮栏默认的矩形渐变蒙层，只保留胶囊材质
      maskColor: '#00000000',
      systemMaterial: material
    }
  }

  /** Swiper 切页后同步系统页签栏选中态 */
  onTabPageChanged(): void {
    if (!this.useSystemTabBar()) {
      return
    }
    try {
      if (this.useHdsTabBar()) {
        this.hdsBarController?.changeIndex(this.tabCurrentPage)
      } else {
        this.glassBarController.changeIndex(this.tabCurrentPage)
      }
    } catch (error) {
      // 页签栏未挂载时忽略
    }
  }

  @Builder
  ImmersiveTabItem(item: TabBuild, index: number) {
    Column() {
      SymbolGlyph(item.icon)
        .fontSize(Xb_TabIconFontSize(this.widthBp, this.heightBp))
        .fontColor([this.tabCurrentPage === index ? this.icon_emphasize : $r('sys.color.icon_tertiary')])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
        .translate({ y: this.tabCurrentPage == index ? -2 : 0 })
        .animation(Xb_AnimationStyle.animNormalUtils(0))
      Text(item.name)
        .fontColor(this.tabCurrentPage === index ? this.icon_emphasize : $r('sys.color.icon_tertiary'))
        .fontSize(Xb_TabTitleFontSize(this.widthBp, this.heightBp))
        // 收缩过程中页签宽度持续变小，锁定单行避免文字被挤成竖排
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Clip })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .opacity(this.useSpringCollapse() ? this.getCollapseContentOpacity() : 1)
  }

  /** 获取悬浮 Tab 底部避让值 */
  getFloatBottom(): number | string {
    const isTabBarVertical = Xb_TabBarVertical(this.widthBp, this.heightBp);
    const isFloatTabBarFullHeight = FloatTabBarHeight(this.widthBp, this.heightBp) == '100%';
    // 优先级 1: 侧边撑满布局
    if (isTabBarVertical && isFloatTabBarFullHeight) {
      return 5;
    }
    // 优先级 2: 窗口模式下的水平布局
    if (!isTabBarVertical && this.windowMode) {
      return this.widthBp < 2 ? 8 : 1;
    }
    // 优先级 3: 常规避让布局：有高度就减 10
    if (this.bottomRectHeight !== 0) {
      return this.bottomRectHeight - 10;
    }
    // 优先级 4 (兜底逻辑): 其他所有情况
    return isTabBarVertical ? 3 : 8;
  }
}
