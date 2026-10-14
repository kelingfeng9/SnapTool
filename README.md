# SnapTool — 小巧截图工具

一个用 **C# / WinForms** 写的 Windows 截图工具:**单文件 exe、零安装**(约 261 KiB)。
专为无法流畅下载 ShareX 等工具的环境,用 Windows 系统自带组件本地编译而成。

当前版本:**v1.4.0**(2026-10-14)

**Mac 版 v1.0.0 开发预览**：支持 Apple 芯片、macOS 14 及更新版本，使用原生 Swift / AppKit 菜单栏应用。已移植形状截图、标注编辑、贴图、快捷键设置、取色、延迟截图和本地 OCR。

[下载 Mac 安装 ZIP（约 621 KiB）](https://github.com/kelingfeng9/SnapTool/releases/download/mac-v1.0.0-preview.1/SnapTool-macOS-1.0.0-arm64.zip) · [Mac 安装与使用说明](macos/README.md) · [Mac 预览版 Release](https://github.com/kelingfeng9/SnapTool/releases/tag/mac-v1.0.0-preview.1)

[Apple 芯片 CI](https://github.com/kelingfeng9/SnapTool/actions/runs/38513370395) 已通过 36 项测试、Release 编译、应用完整性检查和启动检查。预览包使用 ad-hoc 签名，尚未进行 Apple 公证；屏幕授权、多显示器与完整截图交互仍需实机验证。

## ✨ 功能
- **形状截图**：矩形默认、圆形第二；另有三角形、五边形、六边形和自由多边形。顶部独立选择形状，PNG 保留选区外透明背景。
- 区域截图、**自动识别窗口**(鼠标悬停高亮 + 显示标题,单击即选中;自动跳过挂起的 UWP 隐身窗口)
- **选区可调整**:框选确定后工具栏自动出现,可拖动选区移动、拖边/角缩放,点标注工具直接开始画(无需 Enter)
- **截图内标注**：矩形 / 圆形（椭圆）/ 箭头 / 直线 / 画笔 / 文字 / 马赛克 / 序号 / 高亮，7 种颜色；矩形、圆形可实心填充，箭头可双向
- **编辑已有标注**：选择后拖动移动、删除、改颜色及粗细，支持撤销 / 重做；Shift 画正方形、正圆或按 45° 对齐的线段
- **标注参数可调**:选中工具后按 `[` `]` 或滚轮,调节线宽 / 字号 / 马赛克粒度
- 输出:复制到剪贴板 / 保存为文件(记住上次目录和格式)/ **快存**(一键保存到 图片\SnapTool 并复制路径)/ 贴图(置顶、光标锚定缩放、Shift+滚轮调透明度)
- **取色器**:截图时实时显示像素 HEX/RGB;`C` 复制 HEX,无选区时 `Ctrl+C` 复制 RGB
- **文字识别 (OCR)**:框选屏幕文字一键识别(系统自带引擎,本地、断网可用),托盘菜单可切换识别语言
- 延迟截图(3 / 5 / 10 秒,适合截菜单、悬停提示;倒计时不会截进画面)
- 双击快速复制、系统托盘常驻、**开机自启**(托盘一键开关)

## ⌨️ 快捷键
| 操作 | 按键 |
|---|---|
| 开始截图 | `Ctrl + Alt + A`(可自定义) |
| 复制像素颜色 HEX(取色器) | `C` |
| 复制像素颜色 RGB(无选区时) | `Ctrl + C` |
| 复制截图(调整态 / 标注态均可) | `Enter` / `Ctrl + C` / 双击 |
| 保存(对话框,记忆目录) | `Ctrl + S` |
| 快存(免对话框) | `Ctrl + Shift + S` |
| 贴图 | `Ctrl + T` |
| 识别文字(OCR) | `Ctrl + Shift + O` |
| 切换标注工具 | `1` – `9`(与工具栏顺序一致，文字输入时除外) |
| 选择已有标注 | `0`，点击标注后拖动移动 |
| 约束形状 / 角度 | 绘制矩形、圆形、直线、箭头时按住 `Shift` |
| 调线宽 / 字号 / 马赛克粒度 | `[` `]` 或滚轮 |
| 撤销 | `Ctrl + Z`；未选中标注时也可用 `Delete` / `Backspace` |
| 重做 | `Ctrl + Y` / `Ctrl + Shift + Z` |
| 删除选中的标注 | `Delete` / `Backspace` |
| 重选 | `Ctrl + R` / 右键 |
| 取消 | `Esc` |

**贴图窗口**:拖动移动 · 滚轮缩放(光标锚定)· `Shift+滚轮` 透明度 · `Ctrl+C` 复制 · `T` 置顶开关 · 双击 / `Esc` 关闭

## 📂 文件结构
| 文件 | 说明 |
|---|---|
| `SnapTool.exe` | 程序(双击运行) |
| `Program.cs` | 入口、托盘、全局热键、延迟倒计时、配置 |
| `CaptureForm.cs` | 截图遮罩、框选、窗口识别、标注工具栏、取色器 |
| `AnnotationGeometry.cs` | 标注命中检测、移动和绘制边界缓存 |
| `SelectionShape.cs` | 形状几何、透明蒙版和抗锯齿裁剪 |
| `ImageClipboard.cs` | PNG / DIBV5 透明复制及兼容 Bitmap |
| `PinForm.cs` | 贴图窗口 |
| `OcrHelper.cs` | 本地 OCR(系统 Windows.Media.Ocr 引擎) |
| `AssemblyInfo.cs` | 版本信息 |
| `SnapTool.rsp` | csc 编译引用清单(系统 WinRT winmd + GAC facade) |
| `build.cmd` / `build.ps1` | 构建与测试，输出到 artifacts |
| `ConfigurationStore.cs` | 配置迁移、原子写入和 APPDATA 回退 |
| `tests/RegressionTests.cs` / `ShapeTests.cs` / `SettingsTests.cs` / `AnnotationTests.cs` | 345 项回归断言 |
| `对标与性能报告.md` | 开源工具对比、功能取舍及绘制性能证据 |
| `gen-icon.ps1` / `app.ico` | 图标 |
| `SnapTool.config.txt` | 配置(key=value) |

## ⚙️ 配置文件
`SnapTool.config.txt` 每行一项 `key=value`(兼容旧版单行热键写法);exe 目录不可写时自动改存 `%APPDATA%\SnapTool\`，重启读取较新的配置:

| 键 | 说明 | 默认 |
|---|---|---|
| `hotkey` | 截图热键,如 `Ctrl+Alt+A`;数字直接写 `Ctrl+1` | `Ctrl+Alt+A` |
| `ocr` | OCR 语言标记,如 `zh-Hans-CN`;留空 = 自动 | 自动 |
| `pinwin` | 截图时是否把贴图当窗口识别,`1` / `0` | `1` |

开机自启状态保存在注册表 `HKCU\…\Run`,托盘菜单直接开关,无需手动放快捷方式。

## 🔧 构建与验证

双击 `build.cmd` 编译到 `artifacts\SnapTool.exe`。默认不覆盖正在使用的程序。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Test -OutputPath artifacts\RegressionTests.exe
```

测试通过后，退出托盘程序，把 `artifacts\SnapTool.exe` 复制到项目根目录，重新启动。
系统需提供 .NET Framework 4.8、csc 和 Windows WinRT 元数据；不需要额外 SDK 或 Visual Studio。

## v1.2.0 更新

修复文字输入丢失、热键冲突后旧键失效、配置回退不生效、同秒快存覆盖、选区越界、OCR 结果随截图关闭而丢失等问题。增加资源清理、工具栏自动换行、严格构建和 65 项回归断言。完整范围、验证证据和限制见 `修复报告.md`。

文字输入时 Enter 提交，Esc 取消当前文字；点击其他工具或保存会提交文字。文字编辑期间 Ctrl+C/Z、数字与退格仍用于文本编辑。

再次双击运行中的 SnapTool 会唤起截图；命令行 `SnapTool.exe --capture` 可启动后立即截图。
开机自启兼容注册表和旧版 Startup 快捷方式；关闭时会保留旧快捷方式的禁用备份。
OCR 依赖已安装的系统识别语言包，结果窗口可从任务栏找回。

## v1.2.1 图标更新

重新设计蓝青色截图取景框与橙色光标图标。`app.ico` 内含 16、20、24、32、40、48、64、96、128、256 像素版本，256 像素使用 PNG，其余使用 32 位 DIB，保留透明边缘。

`gen-icon.ps1` 可重新生成图标与预览；`assets/SnapTool-logo.svg` 为可编辑图形，`assets/SnapTool-logo-512.png` 为透明 PNG，`assets/SnapTool-icon-preview.png` 展示浅色和深色背景的小尺寸效果。

## v1.3.0 形状截图与快捷键设置

截图界面顶部依次显示“矩形、圆形、三角形、多边形”。每次截图默认矩形；圆形保持正圆，移动和边角缩放后仍保持正圆。三角形、五边形、六边形可拖动选择区域；多边形菜单还提供“自由多边形”，逐点单击添加顶点，双击、点击首点或 Enter 完成，右键/退格撤回一点。完成后可标注，再按 Enter 复制。

形状外部透明，快存和 PNG 文件保留透明度。JPEG/BMP 使用白色背景。剪贴板提供 PNG 与 DIBV5 透明格式，目标软件若仅支持传统 Bitmap，会使用白底兼容图像。贴图窗口按图片轮廓显示，空白部分不遮挡桌面。

**修改截图快捷键有两个入口**：截图界面顶部的“快捷键设置”；右下角托盘图标右键 →“设置快捷键”。在设置窗口可直接输入组合键，或点“录制快捷键”后按下组合键，再点保存。热键冲突会留在设置窗口显示错误，原快捷键继续有效。

## v1.4.0 截图内标注与绘制优化

框选截图后，点击下方 **“标注”** 工具栏的矩形、圆形或箭头，在截图里拖动绘制。顶部“截图形状”用于裁剪图片轮廓；下方“标注”用于在图片上画记号。

数字键顺序：**1 矩形、2 圆形、3 箭头、4 直线、5 画笔、6 文字、7 马赛克、8 序号、9 高亮、0 选择**。圆形工具平时画椭圆，按住 Shift 画正圆；矩形按住 Shift 画正方形。直线、箭头按住 Shift 按水平、垂直或 45° 对齐。

矩形 / 圆形可勾选“实心”，箭头可勾选“双向”。点击“选择”后点击标注（空心图形点击边线），可拖动移动、按 Delete 删除，也可通过颜色按钮、滚轮或方括号修改颜色和大小参数。Ctrl+Z 撤销，Ctrl+Y 或 Ctrl+Shift+Z 重做；撤销栈为空时保留截图选区。

参考 Flameshot、ksnip、ShareX 的常用标注流程，继续使用系统 WinForms / GDI+，无新增第三方依赖。历史画笔点列、马赛克预览及标注边界采用缓存，局部重绘跳过区域外标注；撤销只记录标注操作，不复制整张截图。345 项回归通过。比较范围、性能实测及尚未实现的高级编辑见 [对标与性能报告.md](对标与性能报告.md)。
