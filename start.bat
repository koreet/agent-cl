@echo off
rem Agent-CL 一键启动（可双击）。参数透传给 start.ps1，例如：
rem   start.bat -Mode test
rem   start.bat -Mode smoke -Key sk-xxxx
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
