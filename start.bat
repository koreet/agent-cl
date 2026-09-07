@echo off
rem Agent-CL one-click launcher (double-clickable). Passes args through to start.ps1.
rem   start.bat -Mode test
rem   start.bat -Mode smoke -Key sk-xxxx
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
