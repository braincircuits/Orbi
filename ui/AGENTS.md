# UI 项目要求

本目录遵循仓库根目录 `../AGENTS.md` 的通用要求。以下文件路径相对于 `ui/`。

提交时回到仓库根目录，使用 `sh scripts/commit.sh`；UI 与内核统一提交。

## 跨平台桌面 UI 设计要求

- 核心目标是 macOS、Windows、Linux 保持统一的界面外观和操作体验，不模仿特定操作系统，不按操作系统自动切换视觉风格。
- 以 Flutter 官方 Material 3 和基础 Widgets 为主要组件体系，不使用 macos_ui、Fluent UI 等平台专用 UI 组件库，不混用 Cupertino 视觉组件。
- 统一使用 `lib/ui/desktop_theme.dart` 中的 ThemeData 和设计参数；字体、Material 图标、语义颜色、间距、圆角和控件尺寸由共享规范管理。
- 三个平台复用同一套页面和通用组件。允许跟随系统明暗模式，但明暗模式不改变组件结构、尺寸和交互规则。
- 优先使用 NavigationDrawer、NavigationRail、Card、SegmentedButton、菜单、输入框等成熟 Material 组件；复用已有通用组件，避免不必要的自定义控件、适配层和过度封装。
- 按桌面窗口可用空间设计布局，优化信息密度、鼠标悬停、Tab 焦点、键盘快捷键和窗口缩放；不照搬 Android 手机布局，不用平台判断替代窗口尺寸判断。
- 界面改造限定在展示和交互层，不修改业务逻辑、网络协议或代理内核接口。原生文件选择、窗口和系统菜单可保留宿主能力，但不能决定共享页面的视觉风格。
- 设计细则见 `docs/desktop-ui-design.md`；变更需检查浅色、深色和不同桌面窗口尺寸，并验证共享界面在三个 TargetPlatform 下保持一致。
