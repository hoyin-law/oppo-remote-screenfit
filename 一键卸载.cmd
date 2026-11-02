@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo  OPPO 远程分辨率自动适配 - 卸载
echo  ---------------------------------
echo  即将请求管理员权限，请在弹出的 UAC 窗口点"是"。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0scripts\Uninstall.ps1')"
echo  已发起卸载（约 5-10 秒）。
echo.
pause
