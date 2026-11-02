@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo  OPPO 远程分辨率自动适配 - 安装
echo  ---------------------------------
echo  即将请求管理员权限，请在弹出的 UAC 窗口点"是"。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0scripts\Install.ps1')"
echo  已发起安装（约 10-20 秒）。
echo  如果没有任何反应，请右键本文件 - 以管理员身份运行。
echo.
pause
