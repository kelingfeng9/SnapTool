# SnapTool for Mac

SnapTool 的原生 macOS 菜单栏版本，面向 **Apple 芯片、macOS 14 及更新版本**。使用 AppKit、ScreenCaptureKit、CoreGraphics 和 Vision；不安装额外运行时，不引入第三方依赖。启动后常驻菜单栏，通过快捷键调取截图。

**当前为 1.0.0 开发预览版。** 每次发布包的验证记录见 [macOS 工作流](https://github.com/kelingfeng9/SnapTool/actions/workflows/macos.yml) 及对应 Release；CI 验证编译、核心单元测试、应用打包和无截图权限的启动。屏幕授权、多显示器与贴图交互仍需要真实 Mac 验证，不能由编译和单元测试代替。

## 安装与首次启动

1. 在 [Mac 预览版 Release](https://github.com/kelingfeng9/SnapTool/releases/tag/mac-v1.0.0-preview.1) 下载 `SnapTool-macOS-1.0.0-arm64.zip` 并解压。也可以在成功的 macOS 工作流页面下载 `SnapTool-macOS-arm64-…` 构建产物，再解压里面的安装 ZIP。
2. 将 `SnapTool.app` 拖入 Mac 的“应用程序”文件夹，打开应用。菜单栏会出现取景框图标；应用默认不显示 Dock 图标。
3. 按 **Control + Option + A（⌃⌥A）**，或点击菜单栏图标中的“开始截图”。首次截图时，按系统提示允许 SnapTool 读取屏幕。
4. 如系统要求手动授权，进入“系统设置 → 隐私与安全性 → 屏幕录制”（较新 macOS 中名为“屏幕与系统音频录制”），开启 SnapTool，并按提示重新打开应用。

构建包仅使用 **ad-hoc 签名**检查应用完整性，**没有 Developer ID 签名，也没有 Apple 公证**。从互联网下载后，Gatekeeper 可能阻止首次打开。确认下载来自本仓库后，可按 Apple 的[打开未知开发者应用说明](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)，在“系统设置 → 隐私与安全性”中选择“仍要打开”。不要关闭系统的全局安全保护。

截图权限遵循 Apple 的[屏幕与系统音频录制访问设置](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)。软件不采集音频；OCR 使用系统 Vision 在本机识别，不上传截图或文字。全局快捷键使用系统注册接口，不需要辅助功能或输入监控权限。

## 截图与标注

调取后默认使用矩形截图，圆形排在第二位。还可以选择三角形、五边形、六边形与自由多边形。拖动框选区域，也可以单击自动识别的窗口；完成选择后拖动选区移动，拖动边缘或角点调整大小。

自由多边形逐点单击添加顶点，双击或按 Enter 闭合；右键或退格撤回顶点。圆形及多边形导出 PNG、复制或贴图时保留透明背景；JPEG 使用白底。

截图形状在上方选择，截图内的图形和文字在下方 **“标注”** 工具栏绘制：

| 按键 | 标注工具 | 使用方法 |
| --- | --- | --- |
| 1 | 矩形 | 拖动绘制边框，可启用“实心” |
| 2 | 圆形 / 椭圆 | 拖动绘制，可启用“实心” |
| 3 | 箭头 | 拖动确定方向，可启用“双向” |
| 4 | 直线 | 拖动确定线段 |
| 5 | 画笔 | 按住鼠标自由绘制 |
| 6 | 文字 | 单击后输入，Enter 完成，Esc 取消输入 |
| 7 | 马赛克 | 拖动遮盖区域 |
| 8 | 序号 | 单击添加编号 |
| 9 | 高亮 | 拖动绘制半透明笔迹 |
| 0 | 选择 | 单击标注后拖动移动，Delete 删除，修改颜色与样式 |

按住 **Shift** 绘制正方形或正圆；绘制箭头与直线时按 45° 约束方向。滚轮或 `[` / `]` 调整线宽、文字字号或马赛克粒度。已选择的标注也能改颜色、线宽、实心或双向样式。文字输入期间，常规复制、粘贴与撤销优先作用于正在编辑的文字。

## 快捷键

Mac 的 ⌘ 是 Command，⌃ 是 Control，⌥ 是 Option，⇧ 是 Shift。常用复制、保存等动作使用 Command；调取截图默认使用 Control + Option。

| 快捷键 | 动作 |
| --- | --- |
| ⌃⌥A | 全局调取截图，可在设置中修改 |
| Enter / ⌘C | 复制选区；多边形绘制中 Enter 用于闭合 |
| ⌘S | 另存为 PNG / JPEG / BMP |
| ⇧⌘S | 快速保存到“图片 / SnapTool” |
| ⌘T | 将选区贴在桌面上 |
| ⇧⌘O | 本地文字识别 |
| ⌘Z | 撤销标注 |
| ⇧⌘Z / ⌘Y | 重做标注 |
| ⌘R / 右键 | 重选区域；自由多边形中右键撤点 |
| Esc | 取消当前截图；文字编辑中先取消文字输入 |
| C | 复制鼠标处像素的 HEX 颜色 |
| ⌘C（未选区） | 复制鼠标处像素的 RGB 颜色 |

菜单栏提供延迟 3 / 5 / 10 秒截图。延迟过程中再次调取会替换原有倒计时。

## 贴图、OCR 与设置

贴图默认置顶，可拖动移动，滚轮缩放，Shift + 滚轮调整透明度。右键菜单提供复制、保存、切换置顶与恢复大小；双击或 Esc 关闭。透明区域允许鼠标穿透。

OCR 识别截图的原始内容，避免将标注笔迹当作文字。结果窗口支持选择和编辑识别文字，点击“复制全部”写入剪贴板。菜单栏和设置窗口可以选择系统当前支持的识别语言；自动模式优先处理中英文。

点击菜单栏 **“快捷键与设置…”**，或截图界面上的“快捷键设置”，可录制新组合键，也可直接输入 `Ctrl+Option+A`、`Cmd+Shift+S` 等形式。至少包含 Control、Option、Command 中的一个；Shift 可以搭配使用。点击保存后立即生效，冲突时保留旧快捷键。录制期间按 Esc 可以取消。

设置还包括默认标注颜色、线宽、截图时识别贴图窗口，以及“登录 Mac 时启动”。登录启动使用 macOS 的系统登录项服务；如果需要额外确认，可点击“系统登录项…”查看。请将应用放在“应用程序”中再开启，失败时窗口会显示原因。

## 从源码构建

在 Mac 上安装 Xcode 或 Xcode Command Line Tools，克隆完整仓库后执行：

```bash
cd SnapTool/macos
swift test --arch arm64
bash scripts/build-app.sh
```

脚本把构建结果写入 `macos/build`，生成原生 arm64 可执行文件、沿用项目 Logo 的 `.icns` 图标、应用与 ZIP。最终压缩包为 `build/SnapTool-macOS-1.0.0-arm64.zip`，应用位于本次 `build/package.*/package/SnapTool.app` 中。每次构建使用独立暂存目录，保留旧构建文件。

开发者可使用 `bash scripts/build-app.sh --universal` 构建双架构包；本项目当前主要验证 Apple 芯片版本，Intel 兼容性以实际测试为准。源码构建同样采用 ad-hoc 签名。发布给普通用户所需的 Developer ID 签名、公证和正式自动更新尚未配置。

CI 使用 GitHub 的 [macOS 15 M1 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)，只具备仓库读取权限，不自动创建 Release。成功后上传安装 ZIP、SHA-256 校验文件与日志；失败时也保留已生成的测试、编译日志。启动检查使用 `--smoke-test`，运行几秒后正常退出，不触发截图或屏幕授权请求。
