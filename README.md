# Granite Trader Turnkey

Populate `.env` once, then run:
- WSL: `./install_and_run_wsl.sh`
- Windows: double-click `launch_windows.bat`

Auth model:
- Schwab: `schwab-py` token file flow
- tastytrade: refresh token + client secret via SDK

If Schwab token file does not exist yet, the installer will instruct you to run:
`python backend/get_schwab_client_env.py`
