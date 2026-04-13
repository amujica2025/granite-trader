@echo off
setlocal
cd /d %~dp0
wsl bash -lc "cd \"$(wslpath '%CD%')\" && chmod +x install_and_run_wsl.sh && ./install_and_run_wsl.sh"
endlocal
