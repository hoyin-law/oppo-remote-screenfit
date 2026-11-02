# macOS 版：可行性与设计（进行中）

> 结论：**可以做，但不是把 Windows 脚本移植过去**。需要一套独立的 macOS 实现，
> 并且需要一台 Mac 实机来确认 OPPO 互联 Mac 客户端的日志/进程行为。

## 一、前提：OPPO 互联 支持“远控 Mac”

根据公开资料，OPPO Pad 4 Pro 起支持「远控电脑」，且明确包含 Mac：

- IT之家：OPPO Pad 4 Pro 支持远控电脑，配套键盘适配 Mac 手势/快捷键
  <https://m.ithome.com/html/0843544.htm>
- 快科技：同一账号下，OPPO Pad 4 Pro 可远程操控 Mac，支持文件拖拽
  <https://m.mydrivers.com/newsview/1039873.html>
- ColorOS 16 还增加了“手机投屏到 Mac/Windows、最多 5 个窗口”
  <https://www.ithome.com/0/883/618.htm>

所以“平板远程控制 Mac”在 OPPO 生态里是成立的，剩下的是：**Mac 端能不能按设备分辨率自动建虚拟屏并切换**。

## 二、和 Windows 版的差异

| 能力 | Windows | macOS |
|---|---|---|
| 虚拟显示器 | OPPO 自带 WHQL 驱动 + `OPDisplayDriverTool.exe` | 无系统级公开驱动；需 `CGVirtualDisplay`（私有 API）或 BetterDisplay 等 App |
| 建立虚拟屏 | 调 OPPO 工具即可 | 需要常驻 helper（Swift/Obj-C）或依赖 BetterDisplay |
| 切换主屏/分辨率 | `SetDisplayConfig` | `CGDisplaySetDisplayMode` / `displayplacer` / BetterDisplay CLI |
| 会话检测 | 读 OPPO 主进程日志的 `start/stop remote control` | **未知**：需实机定位 Mac 客户端日志与事件 |
| 权限 | 管理员 + 计划任务 | 辅助功能/屏幕录制权限；私有 API 无沙盒；分发需签名/公证 |

## 三、技术路线（建议）

1. **先确认 OPPO Mac 客户端**
   - 进程名、App 路径、日志目录、日志里是否有“远程会话开始/结束”事件；
   - 是否已有“自适应分辨率”选项（如果有，可能不需要本项目）。
2. **虚拟屏**
   - 方案 A：用 [`makeable/virtual-display-macos`](https://github.com/makeable/virtual-display-macos) / [`Stengo/DeskPad`](https://github.com/Stengo/DeskPad) 的 `CGVirtualDisplay` 思路，写一个小的常驻 helper，创建任意分辨率虚拟屏；
   - 方案 B：用 [BetterDisplay](https://betterdisplay.pro/) 的虚拟屏 + CLI（免费版功能有限，需确认命令行能力见 <https://betterdisplay.pro/guide/integration/cli-examples/>）。
3. **切换**
   - 用 [`displayplacer`](https://github.com/jakehilborn/displayplacer) 或 `CGDisplaySetDisplayMode`，把虚拟屏设为主屏/唯一屏，结束后恢复。
4. **触发**
   - 优先读 OPPO Mac 客户端日志（需实机确认）；
   - 备选：检测客户端进程 + 已建立的远程会话连接（要加防抖，参考 Windows 版 90 秒宽限）。
5. **打包**
   - 建议做成菜单栏 App（SwiftUI）或 launchd 守护 + 脚本；需要 Developer ID 签名/公证才能平滑分发。

## 四、现在的状态

- 已提供 `collect-info.sh`：在 Mac 上跑一次，收集系统/显示器/OPPO 客户端/日志目录信息（只读）；
- 拿到输出后即可确定：Mac 客户端日志位置、会话事件、显示器枚举方式，再实现虚拟屏与切换；
- 在此之前不做“盲写”的 macOS 版本，避免像 Windows 早期那样出现反复切屏。

## 五、如果你有 Mac

1. 把本仓库克隆到 Mac；
2. 运行：

```bash
bash macos/collect-info.sh
```

3. 把生成的 `~/Desktop/oppo-mac-info.txt` 发回来（里面不含账号密码；如担心隐私可先自行检查）。

有了这些信息，就可以继续做 macOS 的 PoC。
