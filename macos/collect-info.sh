#!/bin/bash
# collect-info.sh —— 在 macOS 上收集 OPPO 互联 与本机显示环境信息（只读）。
# 用法：bash macos/collect-info.sh
# 输出：~/Desktop/oppo-mac-info.txt

set -u
OUT="$HOME/Desktop/oppo-mac-info.txt"
: > "$OUT"

log() { printf '%s\n' "$*" >> "$OUT"; }
sec() { printf '\n===== %s =====\n' "$*" >> "$OUT"; }

sec "系统"
sw_vers >> "$OUT" 2>&1
uname -m >> "$OUT" 2>&1

sec "显示器（system_profiler）"
system_profiler SPDisplaysDataType >> "$OUT" 2>&1

sec "显示器（displayplacer，若已安装）"
if command -v displayplacer >/dev/null 2>&1; then
  displayplacer list >> "$OUT" 2>&1
else
  log "未安装 displayplacer（可选：brew install jakehilborn/jakehilborn/displayplacer）"
fi

sec "屏幕布局（AppleScript）"
osascript -e 'tell application "Finder" to get bounds of window of desktop' >> "$OUT" 2>&1

sec "疑似 OPPO / 一加 相关进程"
ps aux | grep -iE 'oppo|oneplus|heytap|o\+connect|oconnect|connect' | grep -v grep >> "$OUT" 2>&1

sec "/Applications 中的疑似 App"
ls -1 /Applications 2>/dev/null | grep -iE 'oppo|oneplus|heytap|connect' >> "$OUT" 2>&1
ls -1 "$HOME/Applications" 2>/dev/null | grep -iE 'oppo|oneplus|heytap|connect' >> "$OUT" 2>&1

sec "疑似 App 的 Bundle 标识"
for app in /Applications/*.app "$HOME"/Applications/*.app; do
  [ -d "$app" ] || continue
  case "$(basename "$app")" in
    *OPPO*|*Oppo*|*oppo*|*OnePlus*|*oneplus*|*HeyTap*|*Connect*|*connect*)
      log "--- $app"
      defaults read "$app/Contents/Info" CFBundleIdentifier >> "$OUT" 2>&1
      defaults read "$app/Contents/Info" CFBundleShortVersionString >> "$OUT" 2>&1
      ;;
  esac
done

sec "日志目录候选（~/Library/Logs）"
find "$HOME/Library/Logs" -maxdepth 2 -iname '*oppo*' -o -maxdepth 2 -iname '*oneplus*' -o -maxdepth 2 -iname '*connect*' >> "$OUT" 2>&1

sec "应用数据目录候选（~/Library/Application Support）"
find "$HOME/Library/Application Support" -maxdepth 2 \( -iname '*oppo*' -o -iname '*oneplus*' -o -iname '*heytap*' -o -iname '*connect*' \) >> "$OUT" 2>&1

sec "Group Containers / Preferences 候选"
ls -1 "$HOME/Library/Group Containers" 2>/dev/null | grep -iE 'oppo|oneplus|heytap|connect' >> "$OUT" 2>&1
ls -1 "$HOME/Library/Preferences" 2>/dev/null | grep -iE 'oppo|oneplus|heytap|connect' >> "$OUT" 2>&1

sec "相关网络连接（lsof）"
lsof -nP -iTCP -iUDP 2>/dev/null | grep -iE 'oppo|oneplus|heytap|connect' >> "$OUT" 2>&1

sec "完成"
log "请把 $OUT 的内容发回（如需脱敏，可先自行删除账号/设备 ID）。"
printf '已生成：%s\n' "$OUT"
