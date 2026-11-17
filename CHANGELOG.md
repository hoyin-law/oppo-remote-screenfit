# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/spec/v2.0.0.html)，
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。此前版本见 GitHub Releases。

## [1.5.6] - 2026-11-17

### Added

- 断开远程控制后自动清理 OPPO 遗留的「幽灵」虚拟显示器实例（`DISPLAY\DELD0E6\*`，`Present=False`）。
  O+ Connect 每次远控都会新建一个虚拟屏实例且从不回收，长期累积会拖慢显示子系统；
  现在每次恢复布局时顺带清掉，只删幽灵、不动活动实例。
  （筛选逻辑 `Select-GhostDisplayInstances` 在 `ScreenFit.Core.ps1`，删除动作 `Remove-GhostDisplays` 在 `Watcher.ps1`。）

### Changed

- `Restore-Layout` 在拆除虚拟屏后调用 `Remove-GhostDisplays`。

## [1.5.5] - 2026-11-16

- 无观看端恢复后 10 分钟内抑制自动切屏，终止反复建屏/拆屏的抖动。详见 GitHub Release。
