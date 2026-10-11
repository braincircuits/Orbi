# 应用内字体

共享桌面界面按用户确认采用原型的系统字体优先顺序：`.AppleSystemUIFont`、`PingFang SC`、`Segoe UI`、`NotoSansSC`。macOS 使用系统西文字体与苹方；系统缺字时使用内置 Noto Sans SC。系统字体不随应用重新分发。日志、地址与规则保留 Roboto Mono，中文使用同一回退顺序。

以下 Noto Sans SC 与 Roboto Mono 两个文件均为原始可变 TTF，随应用打包，无需运行时下载。

来源为 Google Fonts 官方仓库，下载版本：`51303ca9e8ac9dcea7b12d307ba568fd0e6fcfca`。文件已按 GitHub 提供的 Git blob SHA-1 核对，并检查字体表范围完整。

- [Noto Sans SC 原文件](https://github.com/google/fonts/blob/51303ca9e8ac9dcea7b12d307ba568fd0e6fcfca/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf)
- [Roboto Mono 原文件](https://github.com/google/fonts/blob/51303ca9e8ac9dcea7b12d307ba568fd0e6fcfca/ofl/robotomono/RobotoMono%5Bwght%5D.ttf)

原始 SIL Open Font License 1.1 分别保存在 `notosanssc-OFL.txt` 和 `robotomono-OFL.txt`，随应用资产打包；保留原文及版权信息，不修改字体文件。

| 文件 | 字节数 | SHA-256 |
| --- | --- | --- |
| `NotoSansSC-Variable.ttf` | 17772300 | `a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da` |
| `RobotoMono-Variable.ttf` | 183700 | `66a80e79d17e4c7cabd162e2916578a4cc08fd19eef6e2a643305eae9c567b2b` |

## 原型导航图标

左侧导航和品牌地球使用 Lucide 原始图标字体，其他操作保留 Material 图标。来源为 [Lucide 官方项目](https://github.com/lucide-icons/lucide) 发布的 `lucide-static@1.54.0`，从 [npm 发布包](https://registry.npmjs.org/lucide-static/-/lucide-static-1.54.0.tgz) 提取 `font/lucide.ttf` 与原始 `LICENSE`，下载包已按 npm 的 SHA-512 integrity 校验。

- 文件：`Lucide.ttf`，913104 字节；SHA-256：`990158c2198df596a944cd47f9f33898a8b308dd9947da9e950def5956c1fcd2`。
- 授权原文：`lucide-LICENSE.txt`，随应用打包；字体未修改。
- 使用图标：`layout-dashboard`、`sliders-horizontal`、`route`、`file-text`、`arrow-down-up`、`activity`、`globe`。字形映射集中在 `lib/ui/desktop_icons.dart`，直接使用官方 `Icon` 组件，无额外组件库或运行时下载。
