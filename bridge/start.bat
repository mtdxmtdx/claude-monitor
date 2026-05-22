@echo off
chcp 65001 >nul
title Claude Code Bridge

echo 正在检查 Node.js...
node --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [错误] 未找到 Node.js，请先安装 https://nodejs.org
    pause
    exit /b 1
)

echo 正在检查依赖...
if not exist "node_modules" (
    echo 首次运行，安装依赖中...
    npm install
)

echo 正在设置防火墙规则...
netsh advfirewall firewall show rule name="ClaudeMonitor" >nul 2>&1
if %errorlevel% neq 0 (
    netsh advfirewall firewall add rule name="ClaudeMonitor" dir=in action=allow protocol=TCP localport=8765 >nul
    echo 防火墙规则已添加
)

echo.
node bridge.js
pause
