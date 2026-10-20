import TopBuilder from "./TopBuilder"
import { immersiveSurfaceColor } from "../../common/utils/ImmersiveMaterialUtil"

@Component
struct WipeData {

  @Consume('NavSettingsPathStack') SettingsPageInfos: NavPathStack
  //@Consume('morePageMargin') morePageMargin: BreakpointState<number>
  @State icon_primary: ResourceColor = $r('sys.color.icon_primary') //一级图标色，黑色

  build() {
    NavDestination() {
      TopBuilder({
        title: $r('app.string.WipeData'),
        pathStack: this.SettingsPageInfos
      })
    }
    .hideTitleBar(true)
    .backgroundColor(immersiveSurfaceColor($r('app.color.background')))
  //  .backgroundBlurStyle(BlurStyle.BACKGROUND_REGULAR)
    .onBackPressed(() => {
      this.SettingsPageInfos.clear();
      return true;
    })
  }
}
export default WipeData