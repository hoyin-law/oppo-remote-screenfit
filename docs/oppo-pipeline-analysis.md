# OPPO 互联远控：虚拟屏停帧的根因分析（2026-11-04）

> 结论先行：**在当前 OPPO 互联 16.2.20.0 上，"自建虚拟屏 + 让远控内核采集它"这条路走不通**。
> 远控内核只支持它自己的 `OrayIddDriver Device`（IDD 直采通道），不认我们创建的 `OPDisplayDriver` 软件设备；
> OPPO 官方的"平板当扩展屏"能力由 **`app_process\screenshare.exe`** 这套原生模块实现，与远控内核（SunLogin SDK）是两条独立链路。

---

## 1. 实测证据（可复现）

### 1.1 远控内核的显示器枚举与采集模式

`desktop_agent.*.log`（SunLogin SDK）每次会话开始都会打印：

```
[WinSysMgr] nCount=2, queryPhysicCount=2, queryVirtualCount=0, nVirtualCount=0, nOrayIddCount=0
[ClientDesktopMgr] monitor [ count 2 virtual 0 orayidd 0 ], useidd 0, devCount 2 devVirCount 0
[WinVideoCaptureFactory] using 2 mode  with watermark(no)
[SaddcStream] Create new capture mode=2 (0-full, 1-gditracer, 2-mirrortracer, 3-dwm, 4-idd)
```

对 81 份历史桌面代理日志统计（`scripts\Probe-OPPO-Pipeline.ps1`）：

- 初始化时看到虚拟屏：**0 / 81**
- 看到 `orayidd`：**0 / 81**
- `useidd=1`：**0 / 81**
- 采集模式：**全部为 mode=2（mirrortracer，DXGI 抓屏）**

### 1.2 切到虚拟屏后为什么停帧

虚拟屏由 `%LOCALAPPDATA%\DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe` 创建。
该组件是 OPPO 自带的一部分（无数字签名、带 PDB 的内部构建；`DeviceSpace ext-service` 会在需要时自愈重写，文件哈希稳定为
`A767EE94…09B1`），内部用 `SwDeviceCreate` 创建 `SWD\OPDISPLAYDRIVER` 软件设备，
日志显示它打开的设备接口是 `\\?\swd#opdisplaydriver#opdisplaydriver#{89c99670-3fbc-4ea5-962a-f2c46ba45e5a}`。

切屏后远控内核的表现：

```
[IddListener] monitor arrival, \\?\DISPLAY#DELD0E6#...
[IddCxDevice] open device fail, no device founded
[DXGI] Failed to get duplicate output in DUPLICATIONMANAGER hr 80004005
[SaddcStream] Display changed ... 
```

实际帧统计：切到虚拟屏后 `EncoderQualityCalc send=12 → 16` 约 20 秒，然后停止出帧（`send 0` 持续），
这是 DXGI 无法持续复制这块 IddCx 输出导致的，不是插件恢复逻辑的问题。

### 1.3 内核期望的设备名

`plugins\sl-client-desktop.dll` / `sl-client-saddc.dll` 的字符串：

```
OrayIddDriver Device
enable_idd
[WinSysMgr] nOrayIddCount=%d ... useidd %d
[WinSysMgr] idd-toal %d idd-cur %d -> %d cur-feature %s -> %s
[WinSysMgr] EnsureAttachIddDisplay %d
[WinSysMgr] no physical monitor detected, useidd
auto_idd:%d        （会话初始化参数；历史上全部为 0）
```

即：内核认识的是 **Oray 的 IDD 驱动**（向日葵/AweSun 系），并且 `auto_idd` 由会话发起方（OPPO 应用）传入；
历史上所有会话 `auto_idd=0`，所以即使有 `DoDisplayAction isAdd=1` 也会被 `auto virtualdisplay disabled` 拒绝。

### 1.4 OPPO 自己的"屏幕扩展"链路

`C:\Program Files\Oppo Connect\app_process\screenshare.exe`（Qt，3.6MB）字符串包含：

```
StartExtProcessor / [StartExtProcessor::process] Now in mirror progress. Switch to screen extension.
/change_extend_screen_settings
Processing ChangeExtendSettingProcessor ... audio_output / rotation_type / screen_setting
start screen mirror. mode:
castMirrorScreenStatus / SyncCastStateProcessor
```

PC 端 app.asar 里也有完整文案：`EX_EXTEND_SCREEN_CONFIRM_TITLE`（要把屏幕扩展到"X"吗？）、
`EX_EXTEND_SCREEN_STARTED_TOAST`（已将屏幕扩展至"X"）、`extendScreenMainScreen`、`extendScreenRotation`。

→ OPPO 官方的平板扩展屏由 `screenshare.exe` 负责（创建虚拟屏 + 自有推流），**不经过** SunLogin 远控内核。

---

## 2. 三条可选路线的评估

| 路线 | 做法 | 现状 |
|---|---|---|
| A. 走 OPPO 原生「屏幕扩展」 | 由 OPPO 自己创建平板分辨率虚拟屏并推流；插件只负责检测/守护/恢复布局 | **最可行**。需要确认平板端入口；可通过 `screenshare.exe` 进程 + `castScreenStatusChanged` 状态检测会话 |
| B. 装 Oray IDD 驱动 | 让 `nOrayIddCount>0`，内核改用 `mode=4 idd` 直采虚拟屏帧 | 需要第三方驱动（AweSun/向日葵系）；有驱动冲突风险，需实验验证 |
| C. 继续自建虚拟屏 + DXGI | 已实测 `0x80004005`，DXGI 无法持续复制该 IddCx 输出 | **已证伪** |

### 路线 A 的自动化切入点

1. `screenshare.exe` 由 OPPO 应用通过本地 IPC 拉起：`/start_child_process {"name":"screenshare","args":["0"],"require_elevation":true}`；
2. 会话状态由 `[screenshare_ipc] castScreenStatusChanged to screenShare: {"castMirrorScreenStatus":..,"gameCastStatus":..,"appMirrorScreenStatus":..}` 广播；
3. 成功扩展后 `screenshare.exe` 内 `StartExtProcessor` 负责把 PC 画面扩展到平板，`/change_extend_screen_settings` 支持 `screen_setting/rotation_type/audio_output`。

因此插件可演进为：**检测 OPPO 原生扩展会话 → 记录/恢复物理布局 → 会话结束确保扩展屏拆除**，
而不是自己去创建虚拟屏。

### 路线 B 的前置验证

- 用 `scripts\Probe-OPPO-Pipeline.ps1` 对比安装 Oray IDD 前后的 `nOrayIddCount` / `useidd` / `captureMode`；
- 判定标准：出现 `orayidd>0, useidd=1, captureMode=4`，且 `EncoderQualityCalc send>0` 连续 10 分钟。

---

## 3. 当前机器状态与后续实验

- 自动切屏已停用（`%LOCALAPPDATA%\OPPO-ScreenFit\STOP.txt` 存在），物理屏保持"内屏 + ExternalMonitor 扩展"；
- 插件版本 1.2.7；
- 建议的下一步实验（按优先级）：
  1. 在平板端确认「屏幕扩展」入口是否可用：若可用，记录完整日志（`screenshare.exe` + `castScreenStatusChanged`），据此把插件改为原生扩展守护；
  2. 若原生扩展不可用，再评估安装 Oray IDD 驱动做路线 B；
  3. 无论哪条路线，都用 `Probe-OPPO-Pipeline.ps1` 做前后对照，以「连续 10 分钟 send>0」为验收线。
