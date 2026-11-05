# 设备分辨率对照（唯一来源：`scripts\ScreenFit.Core.ps1` 的 `$script:DeviceCatalog`）

> 本表由设备目录生成；`TabletScreen.ps1`、`Prepare-Remote.ps1`、`Test-PreCreatedScreen.ps1` 都直接读取同一目录，不再各自维护。
> **规格未核实**的条目仅作候选，用于手动建屏/预建屏时仍可选用，但请先自行核对。

| Key（脚本参数） | 设备 | 原生分辨率（横屏） | 宽高比 | 规格已核实 |
|---|---|---|---|---|
| `FindN6` | OPPO Find N6（内屏） | 2480 × 2248 | 1.1032 | 是 |
| `FindN5` | OPPO Find N5（内屏） | 2480 × 2248 | 1.1032 | 是 |
| `FindN3Flip` | OPPO Find N3/N2 Flip（内屏） | 2520 × 1080 | 2.3333 | 否 |
| `FindN3` | OPPO Find N3（内屏） | 2440 × 2268 | 1.0758 | 否 |
| `FindN2` | OPPO Find N2（内屏） | 1920 × 1792 | 1.0714 | 否 |
| `FindN1` | OPPO Find N（一代，内屏） | 1920 × 1792 | 1.0714 | 否 |
| `OnePlusPad3Pro` | OnePlus Pad 3 Pro | 3392 × 2400 | 1.4133 | 是 |
| `OnePlusPad2Pro` | OnePlus Pad 2 Pro | 3392 × 2400 | 1.4133 | 是 |
| `OnePlusPadPro` | OnePlus Pad Pro | 3000 × 2120 | 1.4151 | 是 |
| `OnePlusPad2` | OnePlus Pad 2 | 3000 × 2120 | 1.4151 | 是 |
| `OnePlusPadGo2` | OnePlus Pad Go 2 | 2800 × 2000 | 1.4 | 否 |
| `OnePlusPadGo` | OnePlus Pad Go | 2408 × 1720 | 1.4 | 否 |
| `Pad5Pro` | OPPO Pad 5 Pro | 3392 × 2400 | 1.4133 | 是 |
| `Pad4Pro` | OPPO Pad 4 Pro | 3392 × 2400 | 1.4133 | 是 |
| `Pad3Pro` | OPPO Pad 3 Pro | 3000 × 2120 | 1.4151 | 是 |
| `Pad5` | OPPO Pad 5 | 3000 × 2120 | 1.4151 | 是 |
| `Pad6` | OPPO Pad 6 | 3000 × 2120 | 1.4151 | 否 |
| `PadAir5` | OPPO Pad Air5 | 2800 × 1980 | 1.4141 | 是 |
| `PadAir2` | OPPO Pad Air2 | 2408 × 1720 | 1.4 | 否 |
| `PadNeo` | OPPO Pad Neo | 2408 × 1720 | 1.4 | 否 |
| `PadAir` | OPPO Pad Air | 2000 × 1200 | 1.6667 | 否 |
| `PadSE` | OPPO Pad SE | 1920 × 1200 | 1.6 | 否 |
| `PadMini` | OPPO Pad Mini | 2520 × 1680 | 1.5 | 是 |
| `Pad2` | OPPO Pad 2 | 2800 × 2000 | 1.4 | 否 |
| `Pad3` | OPPO Pad 3 | 2800 × 2000 | 1.4 | 是 |
| `OPPOPad1` | OPPO Pad（一代） | 2560 × 1600 | 1.6 | 否 |
| `OnePlusPad1` | OnePlus Pad（一代） | 2800 × 2000 | 1.4 | 是 |

## 用法

```powershell
# 查看设备清单
pwsh -NoProfile -File scripts\Prepare-Remote.ps1 -List

# 预建屏（远控前）
pwsh -NoProfile -File scripts\Prepare-Remote.ps1 -Device Pad5Pro

# 手动建屏 / 拆屏
pwsh -NoProfile -File scripts\TabletScreen.ps1 -Device FindN6
pwsh -NoProfile -File scripts\TabletScreen.ps1 -Device Off
```

## 为什么必须匹配原生分辨率

远程画面按「像素 + 宽高比」映射到接收端；主机输出与接收端比例不同会产生拉伸或黑边。
把主机分辨率设成与设备完全相同即可 1:1 满屏。

## 扩展新设备

只改 `scripts\ScreenFit.Core.ps1` 的 `$script:DeviceCatalog`：新增一条 `@{ Key=...; Aliases=@(...); W=...; H=...; Label=...; Verified=$false }`，
然后运行 `tests\Test-Detection.ps1` 确认目录一致性即可；脚本与文档无需再改。
