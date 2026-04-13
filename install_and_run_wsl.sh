#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

echo "== Granite Trader Turnkey =="

if [ ! -f ".env" ]; then
  cp .env.example .env
  echo "Created .env from .env.example"
  echo "Populate .env once, then rerun this script."
  exit 1
fi

rebuild_venv() {
  rm -rf venv
  python3 -m venv venv
  source venv/bin/activate
  python -m ensurepip --upgrade
  python -m pip install --upgrade pip setuptools wheel
}

if [ ! -d "venv" ]; then
  echo "Creating venv..."
  rebuild_venv
else
  source venv/bin/activate
  if ! python -m pip --version >/dev/null 2>&1; then
    echo "Broken venv detected. Rebuilding..."
    rebuild_venv
  fi
fi

echo "Installing/updating requirements..."
if ! python -m pip install -r requirements.txt; then
  echo "Dependency install failed. Rebuilding venv once..."
  rebuild_venv
  python -m pip install -r requirements.txt
fi

set -a
source ./.env
set +a

if [ ! -f "${SCHWAB_TOKEN_PATH:-$ROOT_DIR/backend/schwab_token.json}" ]; then
  echo ""
  echo "Schwab token file not found."
  echo "Running first-time Schwab auth helper now..."
  python backend/get_schwab_client_env.py
fi

pkill -f "uvicorn main:app" 2>/dev/null || true
pkill -f "http.server 5500" 2>/dev/null || true

echo ""
echo "Starting Granite backend: http://localhost:8000"
(cd backend && ../venv/bin/uvicorn main:app --reload --host 0.0.0.0 --port 8000) &
BACKEND_PID=$!

echo "Starting Granite frontend: http://localhost:5500"
(cd frontend && python3 -m http.server 5500) &
FRONTEND_PID=$!

cleanup() {
  echo ""
  echo "Stopping Granite..."
  kill $BACKEND_PID $FRONTEND_PID 2>/dev/null || true
}
trap cleanup EXIT

echo ""
echo "Open http://localhost:5500"
echo "Press Ctrl+C to stop."
wait
