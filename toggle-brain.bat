@echo off
REM ============================================================
REM  toggle-brain.bat
REM  Double-click to toggle Claude Code's brain between real
REM  Anthropic and a third-party LLM via LiteLLM proxy.
REM
REM  USAGE:
REM    Double-click              → shows usage / menu
REM    toggle-brain.bat status   → show current brain status
REM    toggle-brain.bat claude   → switch to real Anthropic
REM    toggle-brain.bat proxy    → switch to proxy LLM
REM    toggle-brain.bat stop     → stop proxy
REM ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0toggle-brain.ps1" -Mode %1 -StartProxy
pause
