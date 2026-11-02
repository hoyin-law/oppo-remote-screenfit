# V2 PoC —— 外接键鼠 / 刷新率 / USB 映射

这个目录是 V2 的实验代码，**不影响 v1.2.1 的屏幕适配功能**。

## 1. 输入诊断（当前步骤）

`InputDiagnose.ps1` 用低级键鼠钩子（WH_KEYBOARD_LL / WH_MOUSE_LL）记录
**远程客户端实际注入到 Windows 的原始事件**，用来回答：

- 平板专属键盘的按键有没有到电脑？以什么键码/扫描码到达？
- Windows 键（Win / Win+R / Win+D…）有没有被客户端吞掉？
- 触控板的移动、单击、双指滚动、双指右键、三指手势，分别变成了什么事件？
- 多媒体键/亮度键等有没有到达？

### 运行

管理员 PowerShell（覆盖以管理员运行的程序）：

```powershell
cd C:\Users\User\oppo-remote-screenfit-v2\poc
powershell -NoProfile -ExecutionPolicy Bypass -File .\InputDiagnose.ps1
```

脚本会先打印操作清单，然后开始记录；按 `Ctrl+C` 停止并生成汇总。

自检（不连远程）：`-SelfTest -DurationSec 4`。

### 操作清单（对着做）

1. 字母数字：`a b c 1 2 3`
2. 修饰键：`Shift` `Ctrl` `Alt` `Tab` `Esc` `Enter` `Backspace` `方向键` `F1`
3. Windows 键：单独 `Win`、`Win+R`、`Win+D`、`Win+Tab`、`Alt+Tab`
4. 触控板：单指移动、单击、双击、双指滚动、双指右键、三指上滑/左右
5. 键盘多媒体键（音量/播放等，如果有）

### 输出

- `logs\input-<时间>.jsonl`：原始事件（只有键码/坐标，不记录文字内容、不读剪贴板）
- `logs\summary-<时间>.txt`：按键/鼠标/滚轮统计

把这两个文件发我即可分析差异，然后决定哪些能在 PC 端补齐、哪些是客户端没发。

## 隐私

只记录硬件事件码（vk/scan/鼠标坐标），不记录输入的文字内容，不联网上传。
