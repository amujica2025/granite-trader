"""
account_streamer.py  ?  Granite Trader tastytrade Account Streamer client

Connects to wss://streamer.tastyworks.com and receives real-time notifications:
  - Order status changes (Routed ? Live ? Filled)
  - Balance updates (net liq, buying power)
  - Position changes (new legs, closed legs)
  - Quote alert triggers (alerts set on tastytrade platform)

Events are pushed to:
  1. data_store.live_account  ? for REST endpoint fallback reads
  2. dx_streamer._broadcast   ? same broadcast channel as market data events
                                so React receives everything on one WS connection

Heartbeat must be sent every 2?60 s.  We use 20 s.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import threading
from typing import Any, Dict, Optional

log = logging.getLogger("account_streamer")

PROD_URL    = "wss://streamer.tastyworks.com"
SANDBOX_URL = "wss://streamer.cert.tastyworks.com"
HEARTBEAT_S = 20
MAX_BACKOFF = 60

_thread:  Optional[threading.Thread] = None
_loop:    Optional[asyncio.AbstractEventLoop] = None
_running: bool = False


def _get_access_token() -> tuple[str, str]:
    """
    Returns (access_token, account_number) using the existing tasty_adapter
    which correctly handles async session refresh.
    """
    from tasty_adapter import fetch_account_snapshot
    account_number = os.getenv("TASTY_ACCOUNT_NUMBER", "").strip()
    snapshot   = fetch_account_snapshot()
    auth_token = snapshot.get("session_token", "")
    if not auth_token:
        raise RuntimeError("tastytrade session_token not found. Check .env credentials.")
    return auth_token, account_number


class AccountStreamer:

    def __init__(self) -> None:
        self._ws          = None
        self._token:  str = ""
        self._account:str = ""
        self._req_id: int = 1
        self._backoff:int = 1

    async def run(self) -> None:
        global _running
        _running = True
        while _running:
            try:
                self._token, self._account = await asyncio.get_event_loop() \
                    .run_in_executor(None, _get_access_token)
                await self._connect()
                self._backoff = 1
            except Exception as exc:
                log.warning(f"Account streamer error: {exc}. Retry in {self._backoff}s")
                await asyncio.sleep(self._backoff)
                self._backoff = min(self._backoff * 2, MAX_BACKOFF)

    async def _connect(self) -> None:
        import websockets

        use_sandbox = os.getenv("TASTY_ENV", "prod").lower() == "sandbox"
        url = SANDBOX_URL if use_sandbox else PROD_URL

        log.info(f"Account streamer connecting: {url}")
        async with websockets.connect(url, ping_interval=None) as ws:
            self._ws = ws
            log.info("Account streamer connected")

            # Subscribe to account notifications
            await self._send({
                "action":     "connect",
                "value":      [self._account] if self._account else [],
                "auth-token": f"Bearer {self._token}",
                "request-id": self._next_id(),
            })

            # Subscribe to quote alerts
            await self._send({
                "action":     "quote-alerts-subscribe",
                "value":      "",
                "auth-token": f"Bearer {self._token}",
                "request-id": self._next_id(),
            })

            # Start heartbeat
            hb_task = asyncio.create_task(self._heartbeat_loop())
            try:
                async for raw in ws:
                    msg = json.loads(raw)
                    await self._handle(msg)
            finally:
                hb_task.cancel()
                self._ws = None

    async def _handle(self, msg: Dict[str, Any]) -> None:
        from dx_streamer import _broadcast

        mtype = msg.get("type", msg.get("action", ""))
        data  = msg.get("data", {})
        status = msg.get("status", "")

        if status == "ok":
            action = msg.get("action", "")
            if action == "connect":
                log.info(f"Account streamer: subscribed to account {self._account}")
            return

        if mtype == "Order":
            log.info(f"Order event: {data.get('id')} status={data.get('status')}")
            _broadcast({"type": "order", "data": data})

        elif mtype == "AccountBalance":
            from data_store import store
            net_liq = _flt(data.get("net-liquidating-value"))
            if net_liq:
                store.upsert_live_balance({"net_liq": net_liq, "raw": data})
            _broadcast({"type": "balance", "data": data})

        elif mtype == "CurrentPosition":
            _broadcast({"type": "position", "data": data})

        elif mtype == "QuoteAlert":
            log.info(f"Quote alert triggered: {data}")
            _broadcast({"type": "quote_alert", "data": data})

        elif mtype in ("heartbeat", "error"):
            if mtype == "error":
                log.error(f"Account streamer error: {msg}")

    async def _heartbeat_loop(self) -> None:
        while True:
            await asyncio.sleep(HEARTBEAT_S)
            try:
                await self._send({
                    "action":     "heartbeat",
                    "auth-token": f"Bearer {self._token}",
                    "request-id": self._next_id(),
                })
            except Exception:
                break

    async def _send(self, msg: Dict[str, Any]) -> None:
        if self._ws:
            try:
                await self._ws.send(json.dumps(msg))
            except Exception as exc:
                log.warning(f"Account streamer send error: {exc}")

    def _next_id(self) -> int:
        self._req_id += 1
        return self._req_id


def _flt(v: Any, default: float = 0.0) -> float:
    try:
        f = float(v or 0)
        return f if f == f else default
    except Exception:
        return default


def start_account_streamer() -> None:
    global _thread, _loop

    if _thread and _thread.is_alive():
        return

    def _run() -> None:
        global _loop
        _loop = asyncio.new_event_loop()
        asyncio.set_event_loop(_loop)
        streamer = AccountStreamer()
        try:
            _loop.run_until_complete(streamer.run())
        except Exception as exc:
            log.error(f"Account streamer crashed: {exc}")

    _thread = threading.Thread(target=_run, name="account-streamer", daemon=True)
    _thread.start()
    log.info("Account streamer background thread started")
