# V2 PoC 阶段结论（输入 / 刷新率 / USB）

日期：2026-11-03
分支：`v2-poc`

## 1. 外接输入（OPPO Pad 5 Pro 专属键盘 + 触控板）

| 项目 | 结果 |
|---|---|
| 字母/数字/修饰键/方向键/F1/Esc/Tab/Backspace | ✅ 全部到达 PC |
| Windows 键 | ✅ 到达；Win+R 实测弹出系统运行对话框 |
| 触控板指针/左键/右键 | ✅ 正常 |
| 双指垂直滚动 | ✅ 正常 |
| 双指水平滚动 | ❌ 无事件（客户端未发送） |
| 三指手势 | ❌ 无事件（客户端未发送） |
| 中键 | ❌ 无 |

Raycast 裸 Win：
- Raycast 会过滤“注入”的热键，所以原生裸 Win 不响应；
- 可选桥接（`poc/RaycastBridge.ps1`）检测远程裸 Win 后调用 `raycast://` 打开 launcher；
- 关闭方式：触控板点击别处（失焦关闭）；
- 打开延迟约 0.9–1.1s（raycast:// 协议启动），快速路径（直接显示缓存窗口）约 100ms 但后台进程常抢不到前台，已加自动回退；
- 桥接默认关闭（`poc/raycast-bridge.json` → `enabled=false`），不影响其他用户的 Win 原生行为。

## 2. 刷新率 / 帧率

日志实测（客户端请求 → 主机执行）：

| 客户端档位 | 请求帧率 | 主机 SetMaxFps |
|---|---|---|
| 流畅 | 40 | 40 |
| 高清 | 30 | 30 |

- 编码统计 `fps=39~40`；
- 历史所有会话均为 40 上限；
- 客户端上报屏幕刷新率 120Hz，但流帧率由客户端请求值决定；
- **结论：40fps 是 OPPO 客户端硬上限，主机侧无法突破。**

## 3. USB 接口映射

- SDK 内存在 `sl-client-usbip.dll` / `sl-control-usbip.dll`、`USBIP_IPC_LISTEN_PORT`、UI 文案 `USBIP mapping` / `USBIP usage remaining times`；
- 实际会话中：**插件从未加载**、16308/16309 未监听、无 USBIP 服务/驱动、日志无 usbip 记录；
- 平板与折叠屏的远程界面均**没有 USB 映射入口**（用户确认）；
- **结论：OPPO 互联 未开放该能力（可能为向日葵会员功能且未接入），主机侧无法单方面启用。V2 不做 USB 映射。**

## 4. 发现的新问题：平板端 App 崩溃导致“僵尸会话”

- 现象：平板端闪退后，主机未收到 `stop remote control`，会话保持 active，重连被占用/等到超时；
- 主机侧证据：心跳正常（45ms）、SLDesktopAgent 未崩溃、WER 无当日记录；
- 建议：加“僵尸会话看门狗”：active 但 desktop_agent 日志超过 90s 无更新 → 恢复布局并重启 SLDesktopAgent。

## 总结

V2 三项需求的可行边界：
1. 输入：基础键鼠可用；横向滚动/三指手势缺失；Raycast 需可选桥接且打开有 ~1s 延迟（更快需硬件 HID 注入）。
2. 刷新率：受客户端 40fps 限制，无法提升。
3. USB：客户端未开放，无法实现。
