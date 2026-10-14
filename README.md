# SnapTool · 小巧截图工具

<img src="assets/SnapTool-logo-128.png" alt="SnapTool logo" width="80" />

面向 Windows 的轻量截图工具：单文件运行，约 **261 KiB**，使用系统自带 .NET Framework / WinForms / GDI+，无需额外安装运行库。当前版本 **v1.4.0**。

## 下载与使用

[下载 v1.4.0 便携包](downloads/SnapTool-v1.4.0.zip)，点击文件页面的下载按钮，解压后双击 `SnapTool.exe`。程序常驻右下角托盘，默认按 **Ctrl+Alt+A** 截图。

框选区域后，点击下方 **“标注”** 工具栏，在截图内拖动绘制。矩形默认、圆形第二；顶部 **“截图形状”** 用于选择图片外轮廓。

修改截图快捷键：截图顶部 **“快捷键设置”**，或托盘右键 → **“设置快捷键”**。支持输入和录制组合键，冲突时保留原快捷键。

## 功能

- 截图：矩形、圆形、三角形、五边形、六边形、自由多边形，窗口自动识别，选区移动和缩放。
- 标注：矩形、圆形 / 椭圆、箭头、直线、画笔、文字、马赛克、序号、高亮；实心图形、双向箭头。
- 编辑：选择已有标注后移动、删除、改颜色和大小参数，撤销 / 重做，Shift 约束比例或角度。
- 输出：复制、保存、快存、置顶贴图；PNG 保留形状外透明区域。
- 工具：取色器、本地 OCR、延迟截图、托盘常驻、开机自启。

![截图内标注工具示例](docs/images/annotation-tools-preview.png)

上图由隔离测试位图生成，展示标注效果；不包含真实用户屏幕。

## 快捷键

| 操作 | 按键 |
|---|---|
| 开始截图 | Ctrl+Alt+A，可修改 |
| 标注工具 | 1 矩形、2 圆形、3 箭头、4 直线、5 画笔、6 文字、7 马赛克、8 序号、9 高亮 |
| 选择已有标注 | 0，点击标注后拖动移动；空心图形点击边线 |
| 正方形 / 正圆 / 45° 线段 | 绘制时按住 Shift |
| 修改线宽 / 字号 / 马赛克粒度 | 滚轮或 [ / ] |
| 撤销 / 重做 | Ctrl+Z / Ctrl+Y 或 Ctrl+Shift+Z |
| 删除选中标注 | Delete / Backspace |
| 复制截图 | Enter / Ctrl+C / 双击 |
| 保存 / 快存 | Ctrl+S / Ctrl+Shift+S |
| 贴图 / OCR | Ctrl+T / Ctrl+Shift+O |
| 重选 / 取消 | Ctrl+R / Esc |

文字输入期间数字与编辑快捷键用于文本编辑，Enter 提交文字。完整说明见 [使用说明.txt](使用说明.txt)。

## 构建

需要 Windows 10 / 11、.NET Framework 4.8 编译器和系统 WinRT 元数据。无需 Visual Studio、NuGet 或第三方库。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

输出为 `artifacts\SnapTool.exe`，不会覆盖正在使用的程序。双击 `build.cmd` 也可编译。

回归验证：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Test -OutputPath artifacts\RegressionTests.exe
```

v1.4.0 在开发机通过 **345 项断言**。测试包含真实 Windows 热键和本地 OCR，需要可交互桌面及已安装 OCR 语言包；未验证无人值守 CI 环境。脱敏记录见 [docs/verification](docs/verification)。

## 源码与配置

| 文件 | 职责 |
|---|---|
| Program.cs | 托盘、快捷键、设置、自启、延迟截图 |
| CaptureForm.cs | 选区、标注工具与输出流程 |
| AnnotationGeometry.cs | 标注边界、命中检测、移动 |
| SelectionShape.cs | 截图形状及透明蒙版 |
| ImageClipboard.cs | PNG / DIBV5 与兼容 Bitmap 复制 |
| PinForm.cs | 贴图窗口 |
| OcrHelper.cs | 系统本地 OCR |
| ConfigurationStore.cs | 配置读取、迁移及原子写入 |
| tests/ | 回归用例 |

个人配置 `SnapTool.config.txt` 不提交到仓库；可参考 [SnapTool.config.example.txt](SnapTool.config.example.txt)。程序目录不可写时使用 `%APPDATA%\SnapTool\`。

## 审计与对标

[修复报告](修复报告.md) · [对标与性能报告](对标与性能报告.md)

参考 Flameshot、ksnip、ShareX 的常用标注流程，保持轻量。性能改进集中于局部重绘、画笔点缓存、马赛克预览缓存和批量布局；合成绘制数据不代表完整启动或快捷键到显示的延迟。未复制上游源码或引入其运行库。

公开仓库包含源码、测试、图标、合成预览、脱敏验证记录和便携包；历史备份、用户配置与本机部署清单保留在开发机。
