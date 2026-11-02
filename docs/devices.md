# 设备分辨率对照

本项目内置以下设备的原生分辨率（横屏）。触发匹配基于 OPPO 互联 日志里的 `deviceName`，
中英文模型名都做了兼容（例如 `OnePlus Pad` 与 `一加平板`）。

| 设备 | 屏幕 | 原生分辨率 | 宽高比 | 建议缩放 |
|---|---|---|---|---|
| OPPO Pad 5 Pro | 13.2" LCD | 3392 × 2400 | 7:5 | 200% |
| OPPO Pad 4 Pro | 13.2" LCD | 3392 × 2400 | 7:5 | 200% |
| OPPO Pad 5 | 12.1" LCD | 3000 × 2120 | 7:5 | 200% |
| OPPO Pad 3 Pro | 12.1" LCD | 3000 × 2120 | 7:5 | 200% |
| OPPO Pad 3 | 11.61" LCD | 2800 × 2000 | 7:5 | 200% |
| OPPO Pad Mini | 8.8" AMOLED | 2520 × 1680 | 3:2 | 200% |
| OPPO Pad Air5 | 12.1" LCD | 2800 × 1980 | 7:5 | 200% |
| OPPO Find N6（内屏） | 8.12" AMOLED | 2480 × 2248 | ≈1.10 | 200% |
| OnePlus Pad 3 Pro（一加平板 3 Pro） | 13.2" LCD | 3392 × 2400 | 7:5 | 200% |
| OnePlus Pad 2 Pro（一加平板 2 Pro） | 13.2" LCD | 3392 × 2400 | 7:5 | 200% |
| OnePlus Pad Pro（一加平板 Pro） | 12.1" LCD | 3000 × 2120 | 7:5 | 200% |
| OnePlus Pad 2（一加平板 2） | 12.1" LCD | 3000 × 2120 | 7:5 | 200% |
| OnePlus Pad（一加平板 一代） | 11.61" LCD | 2800 × 2000 | 7:5 | 200% |

> 数据来源：OPPO / OnePlus 官方规格与 ZOL 参数页（2026-11 核对）。
> 竖屏（如 Find N6 外屏 2616×1140、竖握时的 2248×2480）不在自动适配范围，见 README「已知限制」。

## 尚未验证 / 未内置

以下型号暂未核对到可靠规格，未加入内置表。可在 `scripts\devices.json` 里自行补充：

- OPPO Pad 6
- OPPO Pad SE
- OPPO Pad Air2 / Air（早期型号）
- OnePlus Pad Go 系列

## 为什么必须匹配原生分辨率

远程画面按「像素 + 宽高比」映射到接收端。若主机输出与接收端比例不同：

- 拉伸 → 变形；
- 等比 → 黑边。

例如电脑内屏 2560×1600（1.6）投到 Pad 5 Pro（1.4133）：

```
纵向变形 = 1.6 / 1.4133 - 1 ≈ 13.2%
```

投到 Find N6 内屏（1.1032）：

```
1.6 / 1.1032 - 1 ≈ 45%
```

把主机分辨率设成与设备完全相同，就能实现 1:1。

## 扩展新设备

### 方式一：devices.json（无需改代码）

在 `scripts\devices.json` 写入数组，匹配项会优先于内置表：

```json
[
  { "match": ["OPPO Pad 6"], "w": 3000, "h": 2120, "label": "OPPO Pad 6" },
  { "match": ["一加平板 4"], "w": 3392, "h": 2400, "label": "OnePlus Pad 4" }
]
```

`match` 支持多个别名（中英文），`w`/`h` 为横屏原生分辨率。

### 方式二：改代码

- `scripts\Watcher.ps1` 里的 `$DeviceMap`
- `scripts\TabletScreen.ps1` 里的 `$Profiles`（手动模式）
