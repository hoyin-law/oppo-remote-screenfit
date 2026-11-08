# 配置（settings.json）

插件默认值即可直接用；需要改路径/行为时，在下面任一位置放 `settings.json`（只需写要覆盖的键）：

1. 环境变量 `SCREENFIT_CONFIG` 指向的 json（调试用）；
2. 仓库根目录 `settings.json`（开发时）；
3. `%LOCALAPPDATA%\OPPO-ScreenFit\settings.json`（安装版）。

模板见 `settings.example.json`，键说明：

| 键 | 默认 | 说明 |
|---|---|---|
| `OppoLogDir` | `%APPDATA%\O+Connect\devicespace` | OPPO 互联日志目录（一般不用改） |
| `StateDir` | 安装目录\logs | 插件状态/快照目录 |
| `VirtualDisplayTool` | `%LOCALAPPDATA%\DeviceSpace\ext-service\OPVirtualDisplayDriver\OPDisplayDriverTool.exe` | OPPO 虚拟显示器工具路径 |
| `DefaultDevice` | 空 | 会话里识别不到设备名时的兜底设备 Key（如 `Pad5Pro`） |
| `ViewerWindowSeconds` | 30 | 最近多少秒有 `send>0` 才算观看端在消费 |
| `ViewerGraceSeconds` | 60 | 切屏后连续多少秒无观看端则自动恢复 |
| `NoViewerKillSeconds` | 180 | 引擎存活但长时间无观看端时的恢复阈值 |
| `ArmTimeoutSeconds` | 900 | 预建屏等待超时 |
| `SwitchOnSession` | true | true=检测到远控会话立即切虚拟屏；false=等观看端出帧再切 |
| `EnsureNativeInternalMode` | true | 恢复布局时把内屏纠正回原生（最大）分辨率 |

修改后重启计划任务（或在安装目录重新运行 `Install.ps1`）生效。