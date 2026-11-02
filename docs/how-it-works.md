# 设计说明与踩坑记录

本文记录这个工具为什么这样设计、以及调试过程中踩到的坑，方便后来者修改或移植。

## 1. 一个前提：OPPO 互联 的远程控制不做分辨率自适应

远程控制（内嵌向日葵 SDK）抓取的是**当前选中显示器**的画面，客户端再把它铺到手机/平板上。
因此当两边比例不同时，只能拉伸或留黑边。

OPPO 互联 自带一块 **WHQL 签名的虚拟显示器驱动**（安装包内 `opdisplaydriver.inf`，Provider=OPPO），
其自带的 `OPDisplayDriverTool.exe` 支持：

```
--operation create --width <W> --height <H> --freq <Hz>
--operation remove
--operation install
```

这正是我们需要的：创建一块与设备原生分辨率一致的显示器。

> 驱动/工具由 OPPO 互联 安装，本项目不包含、不分发任何 OPPO 文件。
> 工具路径：`%LOCALAPPDATA%\DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe`

## 2. 触发方式：读日志，而不是注入

OPPO 互联 主进程日志（`%APPDATA%\O+Connect\devicespace\*_main.log`）里有明确事件：

```
[WsClient.js] start remote control: {... "deviceName":"OPPO Find N6" ...}
[WsClient.js] stop  remote control: {...}
```

- 只读文件，不注入、不 Hook；
- `deviceName` 直接给出当前设备，用来选择分辨率；
- 会话结束以 `stop remote control` 为准。

> 注意：不要用“设备已连上 OPPO 互联”作为触发条件。设备连接在后台频繁抖动
>（`connectCallbackInfo` / `phone_disconnect` 交替出现），会引发反复建屏/拆屏。

## 3. 为什么必须在远程会话开始后才切屏

早期版本为了“首帧就是正确分辨率”，把触发提前到“设备一连接就切屏”。结果：

- 设备连接会抖动 → 每次重连都拆建一次 → 屏幕反复切换；
- 用户日常只是把手机放旁边，电脑屏幕就被切走了。

现在的策略是“**只认远程控制会话**”，实测切换约 1–8 秒（主要耗在建屏），但不会打扰日常使用。

## 4. 显示拓扑

创建虚拟屏后，Windows 默认是「扩展」。远程时希望客户端只看到一块屏，因此：

- 用 `SetDisplayConfig` 只保留虚拟屏的 path（`仅虚拟屏`），并持续用 `QueryDisplayConfig` 校验活动屏数量；发现额外屏恢复就在 2 秒内重切，连续失败则先 `TOPOLOGY_INTERNAL` 再切虚拟屏；
- 切换成功后枚举窗口，把遗留在已关闭显示器上的窗口移回虚拟屏（保留最大化/最小化状态）；
- 远程开始时保存一份显示配置快照（活动显示器、模式、位置），结束时用 `SetDisplayConfig` 恢复原布局（拓展/复制/单屏）；随后移除虚拟屏。

关键坑：**拓扑标志不能与 `SDC_ALLOW_CHANGES` 一起用**，否则返回 `ERROR_INVALID_PARAMETER (87)`。
正确写法：

```csharp
SetDisplayConfig(1, virtualPath, 0, null, SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY);
// 校验：QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS) 只应有 1 条 path
```

## 5. 显示器枚举：编号会一直涨

驱动每次创建虚拟显示器，Windows 分配的 GDI 设备编号会增长（DISPLAY47 → 57 → 67 …）。
早期脚本只枚举到 `DISPLAY1..40`，导致明明建好了却检测不到 → 误判失败 → 拆掉重建 → 无限循环。

**修复：枚举 `DISPLAY1..200`，并且把工具输出里的 `CreateSuccess` 作为成功判定兜底。**

## 6. 建屏工具会常驻

`OPDisplayDriverTool.exe` 创建完显示器后不会退出（它同时是 HostServer）。
因此不能 `Start-Process -Wait` 等它结束，而应：

1. 启动工具；
2. 轮询显示器是否出现（每 2 秒，最多 ~24 秒）；
3. 不等待进程退出。

## 7. 残留设备会导致 SwDeviceCreate 失败

如果直接重复 `create`，可能报：

```
Failed DeviceCreate SwDeviceCreate, hresult 0x800700b7
Cannot create a file when that file already exists.
```

修复：建屏前先

```powershell
Stop-Process -Name OPDisplayDriverTool -Force
pnputil /remove-device "SWD\OPDISPLAYDRIVER\OPDISPLAYDRIVER"
```

## 8. DPI 的副作用

远程 SDK 在缩放 ≠100% 时会按 DIP 重建抓屏缓冲，例如 2560×1600 @125% 会被编码成 2048×1280。
对虚拟屏来说：

- 缩放 200% → 编码分辨率约为 原生/2（例如 1696×1200），平板端 2× 放大，画面略软但比例正确；
- 缩放 100% → 原生像素 1:1，最清晰，但界面偏小。

按需选择即可，不影响“无拉伸”。

## 9. 防抖参数

| 参数 | 值 | 作用 |
|---|---|---|
| 轮询间隔 | 2 s | 响应速度 |
| 建屏冷却 | 30 s | 失败后避免刷屏式重试 |
| 拆除时机 | 恢复布局后立即 | 避免虚拟屏残留 |
| 切虚拟屏延迟 | 2 s | 滤掉瞬时 start/stop 抖动 |
| 回内屏延迟 | 10 s | 结束远程后尽快恢复本地显示 |

## 10. 兼容性与维护

- 依赖 OPPO 互联 的日志格式与虚拟显示器驱动，升级后可能变化；
- 换设备型号时，在 `Watcher.ps1` 的 `Get-TargetSize` 与 `TabletScreen.ps1` 的 `$Profiles` 中增加映射即可；
- 遇到问题先跑 `scripts\Diagnose.ps1`。
