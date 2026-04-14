#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"
echo "== Granite Trader v1.3 =="
if [ ! -f ".env" ]; then cp .env.example .env; echo "Created .env"; exit 1; fi
if [ ! -d "venv" ]; then python3 -m venv venv; fi
source venv/bin/activate
python -m pip install -q -r requirements.txt
set -a; source ./.env; set +a
if [ ! -f "${SCHWAB_TOKEN_PATH:-$ROOT_DIR/backend/schwab_token.json}" ]; then
    python backend/get_schwab_client_env.py
fi
pkill -f "uvicorn main:app" 2>/dev/null || true
pkill -f "vite preview"     2>/dev/null || true
echo "Starting backend: http://localhost:8000"
(cd backend && ../venv/bin/uvicorn main:app --reload --host 0.0.0.0 --port 8000) &
if [ -d "react-frontend/dist" ]; then
    echo "Starting React: http://localhost:5500"
    (cd react-frontend && npx vite preview --port 5500 --host) &
else
    echo "React not built yet - run: cd react-frontend && npm install && npm run build"
    (cd frontend && python3 -m http.server 5500) &
fi
echo "Open http://localhost:5500"
trap 'pkill -f "uvicorn main:app"; pkill -f "vite preview"; pkill -f "http.server"' EXIT
wait
