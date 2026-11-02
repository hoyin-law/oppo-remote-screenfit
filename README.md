# oppo-remote-screenfit

> 让 **OPPO 互联** 远程控制电脑时，自动把电脑显示切换成 **OPPO Pad / Find N6 的原生分辨率**，画面不再被拉伸或上下留黑边。

适用于 Windows 11 + OPPO 互联（O+ Connect）远程控制场景。已在 **OPPO Pad 5 Pro**、**OPPO Find N6** 上验证。

---

## 它解决什么问题

OPPO 互联 的远程控制内核不会按接收端自适应分辨率：它抓取电脑当前显示器的画面，再铺到平板/手机上。

- 电脑屏幕是 16:10 / 16:9，平板是 1.41 / 1.10 → 画面被拉伸或留黑边；
- 手动改分辨率受物理屏模式限制（笔记本屏幕通常没有平板那种比例的模式）。

本项目利用 **OPPO 互联 自带的虚拟显示器驱动**（安装 OPPO 互联 时已装好、微软 WHQL 签名），在远程会话开始时创建一块与设备原生分辨率完全一致的虚拟屏，并切换到该屏显示，从而实现像素级 1:1、无拉伸、无黑边。

| 设备 | 原生分辨率 | 宽高比 |
|---|---|---|
| OPPO Pad 5 Pro / Pad 4 Pro | 3392 × 2400 | 7:5 |
| OPPO Pad 5 / Pad 3 Pro | 3000 × 2120 | 7:5 |
| OPPO Pad 3 | 2800 × 2000 | 7:5 |
| OPPO Pad Mini | 2520 × 1680 | 3:2 |
| OPPO Pad Air5 | 2800 × 1980 | 7:5 |
| OPPO Find N6（内屏） | 2480 × 2248 | ≈1.10 |
| OnePlus Pad 3 Pro / 2 Pro | 3392 × 2400 | 7:5 |
| OnePlus Pad Pro / Pad 2 | 3000 × 2120 | 7:5 |
| OnePlus Pad（一代） | 2800 × 2000 | 7:5 |

完整对照表与「尚未验证的型号」见 [docs/devices.md](docs/devices.md)；
新设备可通过 `scripts/devices.json` 扩展，无需改代码。

---

## 工作原理（简述）

1. `Watcher.ps1`（管理员计划任务，登录自启）读取 OPPO 互联 自己的日志，识别 **远程控制会话开始/结束**：
   - `start remote control: ... "deviceName":"OPPO Find N6" ...`
   - `stop remote control: ...`
2. 会话开始时，按设备型号调用 OPPO 自带的 `OPDisplayDriverTool.exe` 创建对应分辨率的虚拟屏；
3. `TopologyGuard.ps1`（用户级，登录自启）把显示拓扑切到「仅在虚拟屏上显示」；
4. 远程结束后 10 秒切回「仅内屏」，90 秒后拆除虚拟屏（防止客户端短暂重连导致反复拆建）。

全程只读日志，不注入、不修改 OPPO 互联 的程序文件。

详细设计、防抖策略与踩坑记录见 [docs/how-it-works.md](docs/how-it-works.md)。

---

## 环境要求

- Windows 11（22H2 及以上，建议 24H2/25H2）
- OPPO 互联 PC 端（测试版本 16.2.20.0）
- 已安装 OPPO 互联 并至少成功连接过一次手机/平板（这样虚拟显示器驱动与工具才会就位）
- PowerShell 5.1（系统自带即可）
- 安装需要管理员权限（创建计划任务）；日常运行不需要

虚拟显示器工具路径（由 OPPO 互联 安装）：

```
%LOCALAPPDATA%\DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe
```

如果不存在：打开一次 OPPO 互联 的「屏幕扩展」功能，让它把组件解压出来。

---

## 安装（推荐：Release 一键包）

1. 打开 [Releases](https://github.com/hoyin-law/oppo-remote-screenfit/releases) 下载最新的
   `oppo-remote-screenfit-v*.zip`；
2. 解压到任意目录；
3. 双击 **`一键安装.cmd`**，在 UAC 弹窗点「是」。

安装脚本会把程序复制到 `%LOCALAPPDATA%\OPPO-ScreenFit`（所以解压目录之后可以删掉/移动），
并注册「登录自启 + 最高权限」的计划任务和用户级守护。

### 高级：命令行一键安装

```powershell
irm https://raw.githubusercontent.com/hoyin-law/oppo-remote-screenfit/main/install.ps1 | iex
```

（网络不畅时请改用上面的 zip 方式；脚本会自动请求 UAC。）

### 手动安装（开发/调试）

```powershell
git clone https://github.com/hoyin-law/oppo-remote-screenfit.git
cd oppo-remote-screenfit
.\scripts\Install.ps1
```

## 使用

- **平时**：两个守护只读日志，不改变显示；
- **发起远程控制**：约 10–20 秒内自动创建虚拟屏并切换，画面为设备原生分辨率；
- **结束远程**：10 秒后恢复「仅 ROG 内屏」，90 秒后拆除虚拟屏。

### 手动模式（不想用自动逻辑时）

```powershell
# 建屏
.\scripts\TabletScreen.ps1 -Device Pad5Pro    # 3392x2400
.\scripts\TabletScreen.ps1 -Device FindN6     # 2480x2248

# 查看当前显示（只读）
.\scripts\TabletScreen.ps1 -Status

# 拆除
.\scripts\TabletScreen.ps1 -Device Off
```

> 首次使用建议到 Windows「设置 → 系统 → 显示」选中虚拟屏，把缩放设为 **200%**（只需一次，Windows 会按显示器记住）。

### 诊断

```powershell
.\scripts\Diagnose.ps1
```

输出当前显示器、OPPO 互联 会话与设备、最近编码分辨率、本项目日志。

---

## 关闭 / 卸载

- **临时关闭**：在 `scripts` 目录新建空文件 `STOP.txt`，两个守护会在下一次启动时立即退出；
- **彻底卸载**：右键 `scripts\Uninstall.ps1` → 使用 PowerShell 运行（删除计划任务、移除自启、拆虚拟屏、恢复内屏）。

---

## 已知限制

- **竖屏不适配**：竖屏时视频是横的、视口是竖的，必然上下留黑边（比例正确、不拉伸）。本项目只保证横屏满屏。
- **连接后需要 10–20 秒**：虚拟屏是远程会话开始后创建的，这期间客户端可能还显示旧画面，随后自动切换。
- **客户端兼容性**：不同版本的 OPPO 互联 的日志格式可能变化；如果升级后失效，请运行 `Diagnose.ps1` 并把日志发到 Issues。
- **显示器编号**：Windows 给虚拟屏分配的 GDI 编号会不断增长（DISPLAY47、57…），本项目已枚举到 200；极端情况下可能需要重启电脑重置编号。
- 切换显示拓扑的瞬间，物理屏会闪一下，属正常现象。

---

## 安全与免责声明

- 本项目只调用 **OPPO 互联 已安装** 的虚拟显示器驱动与工具，**不包含、不修改、不重新分发** 任何 OPPO/贝锐的二进制文件；
- 仅通过读取 OPPO 互联 本地日志判断会话状态，不注入进程、不修改其程序；
- 本项目与 OPPO、贝锐（向日葵）无任何关联；
- 显示切换涉及系统级 API，**使用风险由使用者自行承担**，建议在了解 Win+P / 显示设置的前提下使用；
- 如果你在使用中遇到问题，欢迎提 Issue（请附 `Diagnose.ps1` 输出）。

---

## macOS

OPPO 互联 也支持「远控 Mac」（OPPO Pad 4 Pro 起）。macOS 版不能直接复用 Windows 驱动，
需要用 CGVirtualDisplay / BetterDisplay 等方案重建虚拟屏，并用 displayplacer 切换分辨率。

可行性分析、技术路线与「在 Mac 上一键收集信息」的脚本见 [macos/README.md](macos/README.md)。

## License

[MIT](LICENSE)
