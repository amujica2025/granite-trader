# Granite Trader — Developer Handoff

## Overview

Granite Trader is a **local trading dashboard + decision engine** built for Windows (WSL) that combines:

- **tastytrade** → account + positions (source of truth)
- **Schwab API** → market data + option chains
- **Local UI (browser)** → visualization, scanning, alerts

This is NOT a toy dashboard.  
It is intended to become a **professional-grade options workflow tool** focused on:

- credit spread scanning
- roll opportunity detection
- margin/limit-aware trade sizing
- real-time monitoring + alerts

---

## Project Location

```text
C:\Users\alexm\granite_trader

WSL path:

/mnt/c/Users/alexm/granite_trader
Current Tech Stack
Backend
FastAPI
Uvicorn
Python 3.12 (venv)
Libraries:
tastytrade
schwab-py
python-dotenv
requests
Frontend
Plain HTML / CSS / JS
Single-page dashboard
Project Structure
granite_trader/
│
├── backend/
│   ├── main.py
│   ├── tasty_adapter.py
│   ├── schwab_adapter.py
│   ├── scanner.py
│   ├── positions.py
│   ├── limit_engine.py
│   ├── notify.py
│   ├── get_schwab_client_env.py
│   └── schwab_token.json
│
├── frontend/
│   └── index.html
│
├── venv/
├── .env
├── .env.example
├── install_and_run_wsl.sh
├── launch_windows.bat
└── HANDOFF.md
Auth Architecture
Schwab (WORKING)
Uses schwab-py
One-time auth flow:
python backend/get_schwab_client_env.py
Token stored at:
backend/schwab_token.json
Live endpoint:
GET /quote/schwab?symbol=SPY
Important rules
NEVER manually curl Schwab OAuth again
NEVER hardcode credentials
Always use .env
tastytrade (WORKING)

Auth model:

Session(client_secret, refresh_token)
await session.refresh()

.env contains:

TASTY_CLIENT_SECRET=...
TASTY_REFRESH_TOKEN=...
TASTY_ACCOUNT_NUMBER=...
Important rules
Refresh token MUST match client secret
Do NOT use browser session tokens
Do NOT attempt manual curl auth unless absolutely necessary
SDK handles session token refresh internally
Environment File
.env

Loaded via:

set -a
source ./.env
set +a
Critical fields
SCHWAB_CLIENT_ID
SCHWAB_CLIENT_SECRET
SCHWAB_REDIRECT_URI
SCHWAB_TOKEN_PATH

TASTY_CLIENT_SECRET
TASTY_REFRESH_TOKEN
TASTY_ACCOUNT_NUMBER
Running the App
Start
cd /mnt/c/Users/alexm/granite_trader
set -a
source ./.env
set +a
./install_and_run_wsl.sh
Stop
Ctrl+C

Or force kill:

pkill -f "uvicorn main:app" || true
pkill -f "http.server 5500" || true
Current Features (Working)
✅ Schwab live quote
✅ tasty live account data
✅ Open positions table
✅ Metrics bar (net liq, limit usage)
✅ Desktop notifications
✅ Basic UI controls
⚠️ Scanner = mock data (NOT LIVE)
Core Trading Logic (CRITICAL)
1. Same-Risk Spread Equivalence

All spreads must normalize by defined risk, not quantity.

Examples:

1 x $10 wide = 2 x $5 = 4 x $2.50 = 10 x $1 = SAME RISK

Scanner must:

generate equivalent spreads
compare across call and put sides
normalize results by risk
2. tastytrade Trading Limit
Max capacity = Net Liq × 25

App must show:

used short option value
remaining capacity
per-trade impact:
max(short value, long cost)
3. Open Positions UI

Must:

resemble Thinkorswim web
include selectable rows
include live totals bar
explode multi-shorts:
-2 → two separate -1 rows
Known Pitfalls (DO NOT REPEAT)
Environment
Windows .env → CRLF → breaks WSL
Fix with:
dos2unix .env
Auth
tasty mismatch error = wrong token/secret pair
Schwab fails if token file missing or expired
Python
broken venv → rebuild instead of debugging
Structure
DO NOT nest folders
Always run from project root
Code
DO NOT hardcode secrets
DO NOT initialize auth clients at import time
Immediate Next Task
Replace mock scanner with REAL scanner

Requirements:

Pull option chain from Schwab
Build:
call credit spreads
put credit spreads
Normalize by:
total defined risk
Rank by:
net credit
credit / risk
limit impact
Future Roadmap
Real scanner (live chain)
Roll engine
Alert engine (price + trade conditions)
Trade builder
Persistent settings
Cleaner UI polish
Full automation hooks
Developer Instructions

Before making changes:

Read:
backend/main.py
backend/scanner.py
backend/limit_engine.py
frontend/index.html
Preserve:
auth flows
trading logic
UI structure
Improve:
scanner
performance
UX
Next Developer Prompt

Use this to continue development:

You are continuing development of Granite Trader.

The system is already running with:

working Schwab auth
working tastytrade auth
live account + quote data
structured UI

Your task is to:

Replace the mock scanner with a real Schwab-based option chain scanner
Generate call and put credit spreads
Normalize spreads by same defined risk
Rank results by:
net credit
credit/risk
limit impact
Integrate results into existing UI without breaking layout
Preserve all existing logic and auth systems

Return:

updated backend files
updated frontend if needed
clear test instructions
Final Note

This app has already gone through multiple failed builds.

The current version is stable because:

auth is correct
structure is clean
environment is controlled

Do not regress to:

manual auth hacks
broken installers
throwaway UI

Build forward from here.