# 轻截 · LightCapture for Windows

**工程预览，尚未在 Windows 实机验收。** 独立 Win32 移植，参考 macOS LightCapture 的公开源码提交 `90e690fe357a971e741ce5d3fdd9f5d6d3e10ff2`。不覆盖 macOS 项目。暂定目标 Windows 11 x64，也应在拟兼容的 Windows 10 22H2 环境单独测试；Windows N 版需要系统 Media Feature Pack 才可能支持录屏编码。

- **F2** 默认；可切换 F1 或 Ctrl+A，可暂停或恢复。全局 F2 启用时，资源管理器的 F2 重命名不再接收该键；如果键盘把功能键映射为媒体键，可能需要与 Fn 同时按下。
- 快捷键打开冻结选区：单击吸附窗口或拖动选区。**F** 选中鼠标所在屏幕，Enter 复制并按设置保存，Esc 取消。选区工具栏可画笔、箭头、矩形、文字、复制和保存。
- 长截图选择内容后点击 **长截图**（或按 **L**），选区遮罩消失。可直接点击原页面，用触控板双指或鼠标滚轮滚动，轻截自动拼接新出现的下方内容；向上回滚不会重复接图。**Enter** 保存，**Esc** 取消，这两个按键只在长截图期间注册。若按键被别的软件占用，可使用浮动按钮，也可再次按截图快捷键保存。选择录屏后点 **录屏**（或 **R**）；全屏需先按 F。录屏用同一个全局快捷键停止并保存。录屏音频默认系统声音开、麦克风关。
- 从桌面再次启动同一个 EXE 打开主窗口；关闭主窗口后不占任务栏、不显示系统托盘图标。设置内可退出或显式启用登录后隐藏启动。
- 默认保存在图片目录下的 `LightCapture` 子目录；可在设置中改成其他同步目录。保存按 Screenshots、Long Screenshots、Recordings 分开。

当前文件是未签名的工程验证构建，不是正式版，不应关闭 SmartScreen 或其他系统安全保护来绕过警告。尚无 Windows 签名更新渠道、一键更新、Windows 运行内存、录屏音画同步或多屏 DPI 的实测数据。长截图、GDI 窗口抓取和录屏可能无法读取部分特殊窗口或受系统保护的内容。

## 构建与测试

在 Linux 或 macOS shell 使用 Zig 0.15.2：

```sh
./test.sh
./build.sh
```

Windows x64 GUI EXE 位于 `build/LightCapture.exe`。构建可设置 `ZIG=/path/to/zig` 和 `ZIG_GLOBAL_CACHE_DIR=/writable/path`。应用使用 Windows 自带 GDI、WIC、Media Foundation 和 WASAPI，不要求安装 Electron 或 .NET。合成测试验证长截图拼接和视频 NV12 像素转换，不代表 Windows 界面或设备运行测试。

## Windows x64 工程预览下载

- [便携 ZIP](downloads/LightCapture-Windows-x64-preview.zip) · [SHA-256](downloads/SHA256SUMS.txt)
- 这是独立 Windows 分支的未签名工程包，不是 macOS 正式发布，也不会进入 macOS 自动更新渠道。
- Windows 模拟数据构建检查已通过；需要按 [验收清单](qa/parity.md) 做系统桌面、录屏与内存实测。无需由用户承担测试。
