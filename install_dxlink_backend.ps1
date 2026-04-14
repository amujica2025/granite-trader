param(
    [switch]$SkipGit,
    [string]$Root = "C:\Users\alexm\granite_trader"
)
$ErrorActionPreference = "Stop"
function Write-Info([string]$m) { Write-Host "[Granite] $m" -ForegroundColor Cyan }
function Write-OK([string]$m)   { Write-Host "[Granite] $m" -ForegroundColor Green }
function WF([string]$rel,[string]$txt) {
    $p = Join-Path $Root ($rel -replace '/','\')
    $d = Split-Path $p -Parent
    if (-not(Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [System.IO.File]::WriteAllText($p,$txt,(New-Object System.Text.UTF8Encoding($false)))
    Write-Info "  $rel"
}
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$bd = Join-Path $Root "_installer_backups\dxlink_$ts"
New-Item -ItemType Directory -Force -Path $bd | Out-Null
@("backend\data_store.py","backend\main.py") | ForEach-Object {
    Copy-Item (Join-Path $Root $_) $bd -Force -ErrorAction SilentlyContinue
}
Write-Info "Backup: $bd"

Write-Info "Installing DXLink streaming backend..."

$c = @'
"""
dx_streamer.py  ?  Granite Trader DXLink streaming client

Connects to tastytrade's DXLink WebSocket feed and streams:
  - Quote events  (live bid/ask/last for every subscribed symbol)
  - Trade events  (live last price + volume)
  - Candle events (OHLCV bars ? historical bulk + live updating last bar)
  - Greeks events (live delta/theta/vega/gamma for option legs)
  - Summary events (day open/high/low/prevClose)

Architecture
------------
  DXStreamer runs in a dedicated asyncio event loop on a background thread.
  Incoming events are dispatched to:
    1. data_store  ? persistent symbol state (all other backend code reads here)
    2. _broadcast_queue ? asyncio.Queue used by the FastAPI /ws/stream endpoint
                         to forward events to connected React clients in real-time

Token lifecycle
---------------
  Token is obtained from tastytrade REST API (/api-quote-tokens).
  Valid for 24 h. Refreshed automatically every 23 h.

Reconnect logic
---------------
  Any WebSocket error or close triggers exponential back-off reconnect
  (1 s ? 2 s ? 4 s ? ? capped at 60 s).

Compact data format
-------------------
  DXLink COMPACT format sends field values as ordered arrays matching the
  field list declared in FEED_SETUP. We map them back to dicts here.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
import threading
from typing import Any, Callable, Dict, List, Optional, Set

log = logging.getLogger("dx_streamer")

# ?? Constants ?????????????????????????????????????????????????????????????????
DXLINK_URL      = "wss://tasty-openapi-ws.dxfeed.com/realtime"
KEEPALIVE_SECS  = 30
TOKEN_REFRESH_H = 23          # hours ? token valid 24 h, refresh before expiry
MAX_BACKOFF     = 60          # seconds

# Fields we request per event type
FEED_FIELDS = {
    "Quote":      ["eventType", "eventSymbol", "bidPrice", "askPrice", "bidSize", "askSize"],
    "Trade":      ["eventType", "eventSymbol", "price", "dayVolume", "size"],
    "TradeETH":   ["eventType", "eventSymbol", "price", "dayVolume", "size"],
    "Candle":     ["eventType", "eventSymbol", "open", "high", "low", "close", "volume", "time"],
    "Greeks":     ["eventType", "eventSymbol", "volatility", "delta", "gamma", "theta", "vega", "rho"],
    "Summary":    ["eventType", "eventSymbol", "openInterest", "dayOpenPrice",
                   "dayHighPrice", "dayLowPrice", "prevDayClosePrice"],
    "Profile":    ["eventType", "eventSymbol", "description", "tradingStatus"],
}

# Candle symbol suffix per timeframe label
CANDLE_PERIOD: Dict[str, str] = {
    "1d":  "5m",
    "5d":  "15m",
    "1m":  "30m",
    "3m":  "1h",
    "6m":  "2h",
    "1y":  "1d",
    "2y":  "1d",
    "5y":  "1d",
    "10y": "1d",
    "20y": "1d",
    "ytd": "1d",
}

# Days back per timeframe label
CANDLE_DAYS: Dict[str, int] = {
    "1d":  1,   "5d":  5,   "1m":  31,  "3m":  92,
    "6m":  183, "1y":  365, "2y":  730, "5y":  1826,
    "10y": 3652,"20y": 7305,"ytd": 0,
}


# ?? Global state ??????????????????????????????????????????????????????????????
_streamer: Optional["DXStreamer"] = None
_loop:     Optional[asyncio.AbstractEventLoop] = None
_thread:   Optional[threading.Thread] = None

# Clients listening via FastAPI /ws/stream
_ws_clients: Set[asyncio.Queue] = set()
_ws_lock = threading.Lock()


def get_streamer() -> Optional["DXStreamer"]:
    return _streamer


def add_ws_client(q: asyncio.Queue) -> None:
    with _ws_lock:
        _ws_clients.add(q)


def remove_ws_client(q: asyncio.Queue) -> None:
    with _ws_lock:
        _ws_clients.discard(q)


def _broadcast(event: Dict[str, Any]) -> None:
    """Thread-safe: push event to every connected React client queue."""
    with _ws_lock:
        dead = set()
        for q in _ws_clients:
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                dead.add(q)
        _ws_clients.difference_update(dead)


# ?? Token fetcher ?????????????????????????????????????????????????????????????

def _get_tasty_session():
    """Return a live tastytrade Session using env credentials."""
    from tastytrade import Session
    client_secret   = os.getenv("TASTY_CLIENT_SECRET", "").strip()
    refresh_token   = os.getenv("TASTY_REFRESH_TOKEN", "").strip()
    if not client_secret or not refresh_token:
        raise RuntimeError("TASTY_CLIENT_SECRET and TASTY_REFRESH_TOKEN must be set in .env")
    return Session(client_secret, refresh_token)


def fetch_dxlink_token() -> tuple[str, str]:
    """
    Fetch a DXLink api-quote-token from tastytrade.
    Returns (token, dxlink_url).
    """
    import requests
    session   = _get_tasty_session()
    # The tastytrade SDK exposes the session token via .session_token attribute
    # or .headers ? try both patterns
    auth_token = getattr(session, "session_token", None) or getattr(session, "_session_token", None)
    if not auth_token:
        # Try headers dict
        headers = getattr(session, "headers", {})
        auth_token = headers.get("Authorization", "").replace("Bearer ", "")

    if not auth_token:
        raise RuntimeError("Could not extract tastytrade session token")

    base_url = os.getenv("TASTY_BASE_URL", "https://api.tastytrade.com")
    resp = requests.get(
        f"{base_url}/api-quote-tokens",
        headers={"Authorization": f"Bearer {auth_token}"},
        timeout=10,
    )
    if not resp.ok:
        raise RuntimeError(f"api-quote-tokens failed: {resp.status_code} {resp.text}")

    data = resp.json().get("data", {})
    token = data.get("token", "")
    url   = data.get("dxlink-url", DXLINK_URL)
    if not token:
        raise RuntimeError(f"Empty token in api-quote-tokens response: {data}")
    log.info("DXLink token obtained (valid 24h)")
    return token, url


# ?? DXStreamer class ??????????????????????????????????????????????????????????

class DXStreamer:
    """
    Async DXLink streaming client.
    Runs entirely inside a background asyncio event loop.
    """

    def __init__(self) -> None:
        self._token:        str  = ""
        self._url:          str  = DXLINK_URL
        self._ws                  = None
        self._channel:      int  = 3
        self._connected:    bool = False
        self._authorized:   bool = False
        self._channel_open: bool = False

        # field order returned by FEED_CONFIG ? used to parse COMPACT arrays
        self._field_map: Dict[str, List[str]] = dict(FEED_FIELDS)

        # subscribed symbols (non-candle)
        self._quote_syms:   Set[str] = set()
        self._greeks_syms:  Set[str] = set()

        # candle subscriptions: {candle_sym: from_time_ms}
        self._candle_subs:  Dict[str, int] = {}

        # candle cache: {candle_sym: [{"time":ms,"open":f,...}, ...]}
        self._candle_cache: Dict[str, List[Dict[str, Any]]] = {}

        # token refresh timer
        self._token_obtained_at: float = 0.0

        self._running = False
        self._backoff = 1

    # ?? Public API (called from sync threads via run_coroutine_threadsafe) ????

    async def subscribe_quotes(self, symbols: List[str]) -> None:
        new = [s.upper() for s in symbols if s.upper() not in self._quote_syms]
        if not new or not self._channel_open:
            return
        self._quote_syms.update(new)
        subs = []
        for sym in new:
            for etype in ("Quote", "Trade", "TradeETH", "Summary", "Profile"):
                subs.append({"type": etype, "symbol": sym})
        await self._send({"type": "FEED_SUBSCRIPTION", "channel": self._channel,
                          "reset": False, "add": subs})
        log.info(f"Subscribed quotes: {new}")

    async def subscribe_greeks(self, option_symbols: List[str]) -> None:
        """option_symbols: DXLink-format option symbols e.g. '.SPY240419C550'"""
        new = [s for s in option_symbols if s not in self._greeks_syms]
        if not new or not self._channel_open:
            return
        self._greeks_syms.update(new)
        subs = [{"type": "Greeks", "symbol": s} for s in new]
        await self._send({"type": "FEED_SUBSCRIPTION", "channel": self._channel,
                          "reset": False, "add": subs})
        log.info(f"Subscribed Greeks: {new}")

    async def subscribe_candles(self, symbol: str, period: str) -> None:
        """
        Subscribe to candle events for symbol at the given period label.
        period: one of CANDLE_PERIOD keys  (e.g. '5y', '1d')
        """
        interval   = CANDLE_PERIOD.get(period, "1d")
        days_back  = CANDLE_DAYS.get(period, 1826)
        from_time  = int((time.time() - days_back * 86400) * 1000) if days_back > 0 \
                     else int((time.time() - 365 * 86400) * 1000)  # YTD ~ 1 year

        candle_sym = f"{symbol.upper()}{{={interval}}}"

        # Clear old cache for this candle symbol
        self._candle_cache[candle_sym] = []
        self._candle_subs[candle_sym] = from_time

        if not self._channel_open:
            return

        await self._send({
            "type": "FEED_SUBSCRIPTION",
            "channel": self._channel,
            "reset": False,
            "add": [{"type": "Candle", "symbol": candle_sym, "fromTime": from_time}],
        })
        log.info(f"Subscribed candles: {candle_sym} from {period}")

    async def unsubscribe_candles(self, symbol: str, period: str) -> None:
        interval   = CANDLE_PERIOD.get(period, "1d")
        candle_sym = f"{symbol.upper()}{{={interval}}}"
        self._candle_subs.pop(candle_sym, None)
        self._candle_cache.pop(candle_sym, None)
        if self._channel_open:
            await self._send({
                "type": "FEED_SUBSCRIPTION",
                "channel": self._channel,
                "reset": False,
                "remove": [{"type": "Candle", "symbol": candle_sym}],
            })

    def get_candle_cache(self, symbol: str, period: str) -> List[Dict[str, Any]]:
        interval   = CANDLE_PERIOD.get(period, "1d")
        candle_sym = f"{symbol.upper()}{{={interval}}}"
        return list(self._candle_cache.get(candle_sym, []))

    # ?? Internal WebSocket lifecycle ??????????????????????????????????????????

    async def run(self) -> None:
        self._running = True
        while self._running:
            try:
                await self._connect_and_run()
                self._backoff = 1   # reset on clean exit
            except Exception as exc:
                log.warning(f"DXLink disconnected: {exc}. Reconnecting in {self._backoff}s?")
                await asyncio.sleep(self._backoff)
                self._backoff = min(self._backoff * 2, MAX_BACKOFF)

    async def stop(self) -> None:
        self._running = False
        if self._ws:
            await self._ws.close()

    async def _connect_and_run(self) -> None:
        import websockets

        # Refresh token if needed
        await self._maybe_refresh_token()

        log.info(f"Connecting to DXLink: {self._url}")
        async with websockets.connect(
            self._url,
            ping_interval=None,    # we manage keepalives manually
            max_size=10 * 1024 * 1024,
        ) as ws:
            self._ws           = ws
            self._connected    = True
            self._authorized   = False
            self._channel_open = False
            log.info("DXLink connected")

            # Send SETUP
            await self._send({"type": "SETUP", "channel": 0,
                               "version": "0.1-DXF-JS/0.3.0",
                               "keepaliveTimeout": 60,
                               "acceptKeepaliveTimeout": 60})

            # Start keepalive loop
            ka_task = asyncio.create_task(self._keepalive_loop())

            try:
                async for raw in ws:
                    msg = json.loads(raw)
                    await self._handle_message(msg)
            finally:
                ka_task.cancel()
                self._connected    = False
                self._authorized   = False
                self._channel_open = False
                self._ws           = None

    async def _handle_message(self, msg: Dict[str, Any]) -> None:
        mtype = msg.get("type", "")

        if mtype == "SETUP":
            log.debug("SETUP received ? sending AUTH")
            await self._send({"type": "AUTH", "channel": 0, "token": self._token})

        elif mtype == "AUTH_STATE":
            state = msg.get("state", "")
            if state == "AUTHORIZED":
                log.info("DXLink authorized")
                self._authorized = True
                await self._open_channel()
            elif state == "UNAUTHORIZED":
                log.warning("DXLink UNAUTHORIZED ? bad token?")

        elif mtype == "CHANNEL_OPENED":
            log.info(f"Channel {msg.get('channel')} opened")
            self._channel_open = True
            await self._setup_feed()

        elif mtype == "FEED_CONFIG":
            log.info("FEED_CONFIG received ? sending initial subscriptions")
            # Update field map if server confirms different ordering
            event_fields = msg.get("eventFields", {})
            if event_fields:
                for etype, fields in event_fields.items():
                    self._field_map[etype] = fields
            await self._send_initial_subscriptions()

        elif mtype == "FEED_DATA":
            await self._handle_feed_data(msg)

        elif mtype == "KEEPALIVE":
            pass  # DXLink echoes our keepalives ? no action needed

        elif mtype == "ERROR":
            log.error(f"DXLink error: {msg}")

    async def _open_channel(self) -> None:
        await self._send({
            "type": "CHANNEL_REQUEST",
            "channel": self._channel,
            "service": "FEED",
            "parameters": {"contract": "AUTO"},
        })

    async def _setup_feed(self) -> None:
        await self._send({
            "type": "FEED_SETUP",
            "channel": self._channel,
            "acceptAggregationPeriod": 0.1,
            "acceptDataFormat": "COMPACT",
            "acceptEventFields": FEED_FIELDS,
        })

    async def _send_initial_subscriptions(self) -> None:
        """Re-subscribe to everything after a (re)connect."""
        subs = []

        # Quote/Trade/Summary for known symbols
        for sym in self._quote_syms:
            for etype in ("Quote", "Trade", "TradeETH", "Summary", "Profile"):
                subs.append({"type": etype, "symbol": sym})

        # Greeks for option legs
        for sym in self._greeks_syms:
            subs.append({"type": "Greeks", "symbol": sym})

        if subs:
            await self._send({"type": "FEED_SUBSCRIPTION", "channel": self._channel,
                               "reset": True, "add": subs})

        # Candles
        for candle_sym, from_time in self._candle_subs.items():
            await self._send({
                "type": "FEED_SUBSCRIPTION",
                "channel": self._channel,
                "reset": False,
                "add": [{"type": "Candle", "symbol": candle_sym, "fromTime": from_time}],
            })

        log.info(f"Re-subscribed: {len(self._quote_syms)} quotes, {len(self._candle_subs)} candle streams")

    async def _handle_feed_data(self, msg: Dict[str, Any]) -> None:
        """
        Parse COMPACT format FEED_DATA messages.
        data field is: [eventType, [val1, val2, ...], eventType, [...], ...]
        """
        from data_store import store

        data = msg.get("data", [])
        i = 0
        while i < len(data):
            etype = data[i]
            i += 1
            if i >= len(data):
                break
            vals = data[i]
            i += 1

            if not isinstance(vals, list):
                continue

            fields = self._field_map.get(etype, [])
            if not fields:
                continue

            event = dict(zip(fields, vals))
            sym   = event.get("eventSymbol", "")

            if etype in ("Quote", "Trade", "TradeETH", "Summary", "Profile"):
                await self._handle_quote_event(etype, sym, event, store)

            elif etype == "Candle":
                await self._handle_candle_event(sym, event)

            elif etype == "Greeks":
                await self._handle_greeks_event(sym, event, store)

    async def _handle_quote_event(self, etype: str, sym: str,
                                  event: Dict[str, Any], store: Any) -> None:
        # Build a normalized live_quote dict
        underlying = sym.split(":")[0]  # strip exchange suffix

        payload: Dict[str, Any] = {"live_quote_source": "dxlink"}

        if etype == "Quote":
            payload.update({
                "live_bid":  _flt(event.get("bidPrice")),
                "live_ask":  _flt(event.get("askPrice")),
                "live_bid_sz": _flt(event.get("bidSize")),
                "live_ask_sz": _flt(event.get("askSize")),
            })
        elif etype in ("Trade", "TradeETH"):
            payload.update({
                "live_last":   _flt(event.get("price")),
                "live_volume": _flt(event.get("dayVolume")),
            })
        elif etype == "Summary":
            payload.update({
                "live_open":       _flt(event.get("dayOpenPrice")),
                "live_high":       _flt(event.get("dayHighPrice")),
                "live_low":        _flt(event.get("dayLowPrice")),
                "live_prev_close": _flt(event.get("prevDayClosePrice")),
            })

        store.upsert_live_quote(underlying, payload)

        # Broadcast to React
        _broadcast({"type": "quote", "symbol": underlying, "data": payload})

    async def _handle_candle_event(self, candle_sym: str,
                                   event: Dict[str, Any]) -> None:
        t   = event.get("time")
        if t is None:
            return
        t_sec = int(t) // 1000

        candle = {
            "time":   t_sec,
            "open":   _flt(event.get("open")),
            "high":   _flt(event.get("high")),
            "low":    _flt(event.get("low")),
            "close":  _flt(event.get("close")),
            "volume": int(_flt(event.get("volume"), 0)),
        }

        cache = self._candle_cache.setdefault(candle_sym, [])

        # Replace if same timestamp (live bar update), else append
        if cache and cache[-1]["time"] == t_sec:
            cache[-1] = candle
        else:
            cache.append(candle)
            cache.sort(key=lambda x: x["time"])  # ensure order

        _broadcast({
            "type":       "candle",
            "symbol":     candle_sym,
            "candle":     candle,
            "is_update":  True,
        })

    async def _handle_greeks_event(self, option_sym: str,
                                   event: Dict[str, Any], store: Any) -> None:
        greeks = {
            "live_iv":    _flt(event.get("volatility")),
            "live_delta": _flt(event.get("delta")),
            "live_gamma": _flt(event.get("gamma")),
            "live_theta": _flt(event.get("theta")),
            "live_vega":  _flt(event.get("vega")),
            "live_rho":   _flt(event.get("rho")),
        }
        store.upsert_option_greeks(option_sym, greeks)
        _broadcast({"type": "greeks", "symbol": option_sym, "data": greeks})

    async def _keepalive_loop(self) -> None:
        while True:
            await asyncio.sleep(KEEPALIVE_SECS)
            try:
                await self._send({"type": "KEEPALIVE", "channel": 0})
            except Exception:
                break

    async def _send(self, msg: Dict[str, Any]) -> None:
        if self._ws:
            try:
                await self._ws.send(json.dumps(msg))
            except Exception as exc:
                log.warning(f"DXLink send error: {exc}")

    async def _maybe_refresh_token(self) -> None:
        age_h = (time.time() - self._token_obtained_at) / 3600
        if not self._token or age_h >= TOKEN_REFRESH_H:
            self._token, self._url = await asyncio.get_event_loop().run_in_executor(
                None, fetch_dxlink_token
            )
            self._token_obtained_at = time.time()


# ?? Helpers ???????????????????????????????????????????????????????????????????

def _flt(v: Any, default: float = 0.0) -> float:
    try:
        f = float(v)
        return f if f == f else default   # NaN check
    except Exception:
        return default


# ?? Public startup function (called from main.py / refresh_scheduler.py) ?????

def start_dx_streamer() -> None:
    """
    Launch the DXStreamer in a background thread with its own event loop.
    Safe to call multiple times ? only starts once.
    """
    global _streamer, _loop, _thread

    if _thread and _thread.is_alive():
        log.debug("DXStreamer already running")
        return

    def _run() -> None:
        global _loop, _streamer
        _loop     = asyncio.new_event_loop()
        asyncio.set_event_loop(_loop)
        _streamer = DXStreamer()
        try:
            _loop.run_until_complete(_streamer.run())
        except Exception as exc:
            log.error(f"DXStreamer loop crashed: {exc}")

    _thread = threading.Thread(target=_run, name="dx-streamer", daemon=True)
    _thread.start()
    log.info("DXStreamer background thread started")


def streamer_subscribe_quotes(symbols: List[str]) -> None:
    """Thread-safe: submit quote subscriptions from sync code."""
    if _streamer and _loop and _loop.is_running():
        asyncio.run_coroutine_threadsafe(
            _streamer.subscribe_quotes(symbols), _loop
        )


def streamer_subscribe_candles(symbol: str, period: str) -> None:
    """Thread-safe: subscribe to candle stream from sync code."""
    if _streamer and _loop and _loop.is_running():
        asyncio.run_coroutine_threadsafe(
            _streamer.subscribe_candles(symbol, period), _loop
        )


def streamer_subscribe_greeks(option_symbols: List[str]) -> None:
    """Thread-safe: subscribe to option Greeks from sync code."""
    if _streamer and _loop and _loop.is_running():
        asyncio.run_coroutine_threadsafe(
            _streamer.subscribe_greeks(option_symbols), _loop
        )


def streamer_get_candles(symbol: str, period: str) -> List[Dict[str, Any]]:
    """Return cached candles for symbol+period (may be empty if not yet loaded)."""
    if _streamer:
        return _streamer.get_candle_cache(symbol, period)
    return []


def streamer_is_connected() -> bool:
    return bool(_streamer and _streamer._connected and _streamer._authorized)

'@
WF "backend\dx_streamer.py" $c

$c = @'
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
    Returns (access_token, account_number) from the tastytrade session.
    """
    from tastytrade import Session
    client_secret   = os.getenv("TASTY_CLIENT_SECRET", "").strip()
    refresh_token   = os.getenv("TASTY_REFRESH_TOKEN", "").strip()
    account_number  = os.getenv("TASTY_ACCOUNT_NUMBER", "").strip()

    if not client_secret or not refresh_token:
        raise RuntimeError("TASTY_CLIENT_SECRET / TASTY_REFRESH_TOKEN not set")

    session    = Session(client_secret, refresh_token)
    auth_token = getattr(session, "session_token", None) \
              or getattr(session, "_session_token", None) \
              or ""

    if not auth_token:
        headers    = getattr(session, "headers", {})
        auth_token = headers.get("Authorization", "").replace("Bearer ", "")

    if not auth_token:
        raise RuntimeError("Could not extract tastytrade access token")

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

'@
WF "backend\account_streamer.py" $c

$c = @'
from __future__ import annotations

import threading
import time
from typing import Any, Dict, List, Optional


class DataStore:
    """
    Thread-safe in-memory store.

    Sections:
      1. symbol_state   - chain/vol/scanner data (from schwab_adapter)
      2. live_quotes    - real-time Quote/Trade/Summary from DXLink
      3. option_greeks  - real-time Greeks from DXLink per option symbol
      4. live_balance   - real-time account balance from Account Streamer
    """

    def __init__(self) -> None:
        self._lock           = threading.RLock()
        self._symbols:       Dict[str, Dict[str, Any]] = {}
        self._live_quotes:   Dict[str, Dict[str, Any]] = {}
        self._option_greeks: Dict[str, Dict[str, Any]] = {}
        self._live_balance:  Dict[str, Any] = {}

    # ?? Symbol state ???????????????????????????????????????????????????????

    def upsert_symbol_state(self, symbol: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        key = symbol.upper()
        with self._lock:
            existing = self._symbols.get(key, {})
            merged   = dict(existing)
            merged.update(payload)
            merged["symbol"] = key
            if "updated_at_epoch" not in merged:
                merged["updated_at_epoch"] = time.time()
            self._symbols[key] = merged
            return dict(merged)

    def get_symbol_state(self, symbol: str) -> Dict[str, Any]:
        with self._lock:
            return dict(self._symbols.get(symbol.upper(), {}))

    def list_symbols(self) -> List[str]:
        with self._lock:
            return sorted(self._symbols.keys())

    def snapshot_all(self) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            return {k: dict(v) for k, v in self._symbols.items()}

    def clear(self) -> None:
        with self._lock:
            self._symbols.clear()

    # ?? Live quotes (DXLink) ???????????????????????????????????????????????

    def upsert_live_quote(self, symbol: str, data: Dict[str, Any]) -> None:
        key = symbol.upper()
        with self._lock:
            existing = self._live_quotes.get(key, {})
            merged   = dict(existing)
            merged.update(data)
            merged["updated_at"] = time.time()
            self._live_quotes[key] = merged

    def get_live_quote(self, symbol: str) -> Dict[str, Any]:
        with self._lock:
            return dict(self._live_quotes.get(symbol.upper(), {}))

    def get_all_live_quotes(self) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            return {k: dict(v) for k, v in self._live_quotes.items()}

    def get_live_price(self, symbol: str) -> Optional[float]:
        """Best live last price ? DXLink first, Schwab chain fallback."""
        q    = self.get_live_quote(symbol)
        last = q.get("live_last")
        if last and float(last) > 0:
            return float(last)
        state = self.get_symbol_state(symbol)
        return state.get("underlying_price")

    # ?? Option Greeks (DXLink) ?????????????????????????????????????????????

    def upsert_option_greeks(self, option_symbol: str, data: Dict[str, Any]) -> None:
        with self._lock:
            existing = self._option_greeks.get(option_symbol, {})
            merged   = dict(existing)
            merged.update(data)
            merged["updated_at"] = time.time()
            self._option_greeks[option_symbol] = merged

    def get_option_greeks(self, option_symbol: str) -> Dict[str, Any]:
        with self._lock:
            return dict(self._option_greeks.get(option_symbol, {}))

    def get_all_option_greeks(self) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            return {k: dict(v) for k, v in self._option_greeks.items()}

    # ?? Live balance (Account Streamer) ????????????????????????????????????

    def upsert_live_balance(self, data: Dict[str, Any]) -> None:
        with self._lock:
            self._live_balance.update(data)
            self._live_balance["updated_at"] = time.time()

    def get_live_balance(self) -> Dict[str, Any]:
        with self._lock:
            return dict(self._live_balance)


# singleton
store = DataStore()

'@
WF "backend\data_store.py" $c

$c = @'
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Dict, List, Optional

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

load_dotenv()

from cache_manager import ensure_symbol_loaded, get_symbol_state, list_cached_symbols, manual_refresh_symbol
from data_store import store
from field_registry import ENTRY_STRATEGIES, SCANNER_FIELDS, VALID_SORT_KEYS
from limit_engine import compute_limit_summary, compute_selected_totals
from notify import send_pushover
from positions import normalize_mock_positions
from refresh_scheduler import start_scheduler
from scanner import generate_risk_equivalent_candidates
from source_router import get_active_chain_source
from tasty_adapter import extract_net_liq, fetch_account_snapshot, normalize_live_positions
from vol_surface import build_vol_surface_payload

log = logging.getLogger("main")

app = FastAPI(title="Granite Trader", version="1.3.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ?? Pydantic models ??????????????????????????????????????????????????????????

class SelectedRowsPayload(BaseModel):
    rows: List[Dict[str, Any]]

class AlertPayload(BaseModel):
    title: str
    message: str
    notify_whatsapp: bool = False

class StreamSubscribePayload(BaseModel):
    symbols:  List[str] = []
    period:   Optional[str] = "5y"   # candle timeframe

class GreeksSubscribePayload(BaseModel):
    option_symbols: List[str] = []


# ?? Helpers ??????????????????????????????????????????????????????????????????

def _parse_expirations(expiration: str) -> Optional[List[str]]:
    exp = (expiration or "all").strip().lower()
    return None if exp == "all" else [expiration.strip()]


# ?? Startup ??????????????????????????????????????????????????????????????????

@app.on_event("startup")
def on_startup() -> None:
    # Existing REST-based scheduler (chain refresh, archiving)
    start_scheduler()

    # DXLink streaming ? start in background, non-fatal if token unavailable
    try:
        from dx_streamer import start_dx_streamer
        start_dx_streamer()
        log.info("DXLink streamer started")
    except Exception as exc:
        log.warning(f"DXLink streamer could not start: {exc}")

    # Account streamer
    try:
        from account_streamer import start_account_streamer
        start_account_streamer()
        log.info("Account streamer started")
    except Exception as exc:
        log.warning(f"Account streamer could not start: {exc}")


# ?? Health ???????????????????????????????????????????????????????????????????

@app.get("/health")
def health() -> Dict[str, Any]:
    try:
        from dx_streamer import streamer_is_connected
        dx_connected = streamer_is_connected()
    except Exception:
        dx_connected = False

    return {
        "status": "ok",
        "active_chain_source": get_active_chain_source(),
        "cached_symbols": list_cached_symbols(),
        "dxlink_connected": dx_connected,
    }


# ?? WebSocket stream endpoint ?????????????????????????????????????????????????
# React connects here and receives all DXLink + Account Streamer events
# as JSON messages on a single persistent WebSocket connection.

@app.websocket("/ws/stream")
async def ws_stream(websocket: WebSocket) -> None:
    await websocket.accept()
    q: asyncio.Queue = asyncio.Queue(maxsize=500)

    try:
        from dx_streamer import add_ws_client, remove_ws_client
        add_ws_client(q)
    except Exception:
        pass

    # Send connection ack
    await websocket.send_text(json.dumps({
        "type": "connected",
        "message": "Granite Trader stream active",
    }))

    try:
        while True:
            # Forward queued events to React (non-blocking get with timeout)
            try:
                event = await asyncio.wait_for(q.get(), timeout=15.0)
                await websocket.send_text(json.dumps(event))
            except asyncio.TimeoutError:
                # Send ping to keep connection alive
                await websocket.send_text(json.dumps({"type": "ping"}))
    except (WebSocketDisconnect, Exception):
        pass
    finally:
        try:
            from dx_streamer import remove_ws_client
            remove_ws_client(q)
        except Exception:
            pass


# ?? Streaming subscription endpoints ?????????????????????????????????????????

@app.post("/stream/subscribe/quotes")
def subscribe_quotes(payload: StreamSubscribePayload) -> Dict[str, Any]:
    """Subscribe to live Quote/Trade/Summary for the given symbols."""
    try:
        from dx_streamer import streamer_subscribe_quotes
        streamer_subscribe_quotes(payload.symbols)
        return {"ok": True, "symbols": payload.symbols}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/stream/subscribe/candles")
def subscribe_candles(payload: StreamSubscribePayload) -> Dict[str, Any]:
    """Subscribe to Candle events for symbol at given period."""
    try:
        from dx_streamer import streamer_subscribe_candles
        for sym in payload.symbols:
            streamer_subscribe_candles(sym, payload.period or "5y")
        return {"ok": True, "symbols": payload.symbols, "period": payload.period}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/stream/subscribe/greeks")
def subscribe_greeks(payload: GreeksSubscribePayload) -> Dict[str, Any]:
    """Subscribe to Greeks events for option streamer-symbols."""
    try:
        from dx_streamer import streamer_subscribe_greeks
        streamer_subscribe_greeks(payload.option_symbols)
        return {"ok": True, "option_symbols": payload.option_symbols}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/stream/candles")
def get_candles(
    symbol: str = Query(..., min_length=1),
    period: str = Query("5y"),
) -> Dict[str, Any]:
    """
    Return cached candles from the DXLink stream.
    Falls back to Schwab REST if stream has no data yet.
    """
    try:
        from dx_streamer import streamer_get_candles, streamer_is_connected
        candles = streamer_get_candles(symbol, period)
        if candles:
            return {
                "symbol":    symbol.upper(),
                "period":    period,
                "source":    "dxlink",
                "count":     len(candles),
                "candles":   candles,
            }
    except Exception:
        pass

    # Schwab REST fallback
    try:
        from chart_adapter import get_price_history
        return get_price_history(symbol=symbol, period=period)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/stream/status")
def stream_status() -> Dict[str, Any]:
    """Return status of both streaming connections."""
    try:
        from dx_streamer import streamer_is_connected, _streamer
        dx_ok = streamer_is_connected()
        quote_syms  = list(getattr(_streamer, "_quote_syms",  set()))
        candle_syms = list(getattr(_streamer, "_candle_subs", {}).keys())
        greek_syms  = list(getattr(_streamer, "_greeks_syms", set()))
    except Exception:
        dx_ok = False
        quote_syms = candle_syms = greek_syms = []

    return {
        "dxlink":         {"connected": dx_ok, "quote_symbols": quote_syms,
                           "candle_symbols": candle_syms, "greek_symbols": greek_syms},
        "live_quotes":    list(store.get_all_live_quotes().keys()),
        "live_greeks":    list(store.get_all_option_greeks().keys()),
        "account_balance": store.get_live_balance(),
    }


# ?? Account / Positions ???????????????????????????????????????????????????????

@app.get("/account/mock")
def account_mock() -> Dict[str, Any]:
    positions = normalize_mock_positions()
    return {"source": "mock", "positions": positions,
            "limit_summary": compute_limit_summary(72.0, positions)}

@app.get("/account/tasty")
def account_tasty() -> Dict[str, Any]:
    try:
        snapshot  = fetch_account_snapshot()
        positions = normalize_live_positions(snapshot)
        net_liq   = extract_net_liq(snapshot)
        # Use live balance from account streamer if available and fresher
        live_bal = store.get_live_balance()
        if live_bal.get("net_liq"):
            net_liq = live_bal["net_liq"]
        return {"source": "tasty", "positions": positions,
                "limit_summary": compute_limit_summary(net_liq, positions)}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.post("/totals")
def totals(payload: SelectedRowsPayload) -> Dict[str, Any]:
    return compute_selected_totals(payload.rows)


# ?? Cache ?????????????????????????????????????????????????????????????????????

@app.get("/cache/status")
def cache_status() -> Dict[str, Any]:
    syms = list_cached_symbols()
    return {"symbols": syms, "count": len(syms),
            "active_chain_source": get_active_chain_source()}

@app.get("/refresh/symbol")
def refresh_symbol(symbol: str = Query(..., min_length=1),
                   strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = manual_refresh_symbol(symbol=symbol, strike_count=strike_count)
        return {"symbol": symbol.upper(),
                "active_chain_source": state.get("active_chain_source"),
                "contract_count": len(state.get("contracts", [])),
                "expirations": state.get("expirations", []),
                "updated_at_epoch": state.get("updated_at_epoch")}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ?? Quote ?????????????????????????????????????????????????????????????????????

@app.get("/quote/schwab")
def quote_schwab(symbol: str = Query(..., min_length=1),
                 strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = ensure_symbol_loaded(symbol=symbol, strike_count=strike_count,
                                     requested_by="quote")
        quote_raw = state.get("quote_raw", {})

        # Overlay live DXLink data if available
        live = store.get_live_quote(symbol)
        if live and quote_raw:
            sym_key = symbol.upper()
            inner   = quote_raw.get(sym_key, {})
            q       = inner.get("quote", inner)
            if live.get("live_last"):
                q["lastPrice"] = live["live_last"]
            if live.get("live_bid"):
                q["bidPrice"] = live["live_bid"]
            if live.get("live_ask"):
                q["askPrice"] = live["live_ask"]

        if not quote_raw:
            raise RuntimeError(f"No quote for {symbol.upper()}")
        return quote_raw
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/quote/live")
def quote_live(symbol: str = Query(..., min_length=1)) -> Dict[str, Any]:
    """Return the latest live DXLink quote for a symbol."""
    q = store.get_live_quote(symbol)
    if q:
        return {"symbol": symbol.upper(), "source": "dxlink", **q}
    # Fall back to Schwab price
    price = store.get_live_price(symbol)
    return {"symbol": symbol.upper(), "source": "schwab_cache", "live_last": price}


# ?? Chain ?????????????????????????????????????????????????????????????????????

@app.get("/chain")
def chain(symbol: str = Query(..., min_length=1),
          strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = ensure_symbol_loaded(symbol=symbol, strike_count=strike_count,
                                     requested_by="chain")
        return {"symbol": state.get("symbol", symbol.upper()),
                "underlying_price": state.get("underlying_price"),
                "count": len(state.get("contracts", [])),
                "expirations": state.get("expirations", []),
                "strikes": state.get("strikes", []),
                "items": state.get("contracts", []),
                "active_chain_source": state.get("active_chain_source"),
                "symbol_snapshot": state.get("symbol_snapshot", {})}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ?? Vol surface ???????????????????????????????????????????????????????????????

@app.get("/vol/surface")
def vol_surface(symbol: str = Query(..., min_length=1),
                max_expirations: int = Query(7, ge=1, le=20),
                strike_count: int = Query(25, ge=5, le=101)) -> Dict[str, Any]:
    try:
        return build_vol_surface_payload(symbol=symbol,
                                         max_expirations=max_expirations,
                                         strike_count=strike_count)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ?? Scanner ???????????????????????????????????????????????????????????????????

@app.get("/scan")
def scan_legacy(symbol: str = Query("SPY"), total_risk: float = Query(600.0, gt=0),
                side: str = Query("all"), expiration: str = Query("all"),
                sort_by: str = Query("credit_pct_risk"),
                strike_count: int = Query(200, ge=25, le=500),
                max_results: int = Query(500, ge=1, le=2000)) -> Dict[str, Any]:
    return scan_live(symbol=symbol, total_risk=total_risk, side=side,
                     expiration=expiration, sort_by=sort_by,
                     strike_count=strike_count, max_results=max_results)

@app.get("/scan/live")
def scan_live(symbol: str = Query(..., min_length=1),
              total_risk: float = Query(600.0, gt=0),
              side: str = Query("all"), expiration: str = Query("all"),
              sort_by: str = Query("credit_pct_risk"),
              strike_count: int = Query(200, ge=25, le=500),
              max_results: int = Query(500, ge=1, le=2000)) -> Dict[str, Any]:
    side = side.lower().strip()
    if side not in {"all", "call", "put"}:
        raise HTTPException(status_code=400, detail="side must be all, call, or put")
    sort_by = sort_by.strip().lower()
    if sort_by not in VALID_SORT_KEYS:
        raise HTTPException(status_code=400,
                            detail=f"sort_by must be one of: {', '.join(sorted(VALID_SORT_KEYS))}")
    try:
        items = generate_risk_equivalent_candidates(
            symbol=symbol, total_risk=total_risk,
            expirations=_parse_expirations(expiration),
            side_filter=side, pricing_mode="conservative_mid",
            strike_count=strike_count, ranking=sort_by, max_results=max_results)
        s = get_symbol_state(symbol)
        return {"symbol": symbol.upper(), "total_risk": round(total_risk, 2),
                "side": side, "count": len(items), "items": items,
                "active_chain_source": s.get("active_chain_source"),
                "symbol_snapshot": s.get("symbol_snapshot", {})}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ?? Chart history (REST fallback when DXLink not connected) ???????????????????

@app.get("/chart/history")
def chart_history(symbol: str = Query(..., min_length=1),
                  period: str = Query("5y"),
                  frequency: str = Query("daily")) -> Dict[str, Any]:
    """
    REST chart history via Schwab.
    React tries /stream/candles first (DXLink) then falls back here.
    """
    try:
        from chart_adapter import get_price_history
        return get_price_history(symbol=symbol, period=period, frequency=frequency)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ?? Field registry ????????????????????????????????????????????????????????????

@app.get("/field-registry")
def field_registry() -> Dict[str, Any]:
    return {"entry_strategies": ENTRY_STRATEGIES, "scanner_fields": SCANNER_FIELDS,
            "valid_sort_keys": sorted(VALID_SORT_KEYS)}


# ?? Alerts / Notifications ????????????????????????????????????????????????????

@app.post("/alerts/send")
def alerts_send(payload: AlertPayload) -> Dict[str, Any]:
    return {"desktop": True, "pushover": send_pushover(payload.message, payload.title)}

@app.post("/alerts/pushover")
def alerts_pushover(payload: AlertPayload) -> Dict[str, Any]:
    return send_pushover(payload.message, payload.title)

'@
WF "backend\main.py" $c


# Add websockets to requirements.txt if not present
$req = Join-Path $Root "requirements.txt"
if (Test-Path $req) {
    $content = Get-Content $req -Raw
    if ($content -notmatch "websockets") {
        Add-Content $req "websockets>=12.0"
        Write-Info "Added websockets to requirements.txt"
    }
}

# Install websockets in WSL venv
Write-Info "Installing websockets in WSL venv..."
$wslRoot = ($Root -replace 'C:\\', '/mnt/c/') -replace '\\', '/'
wsl.exe bash -lc "cd '$wslRoot' && source venv/bin/activate && pip install websockets --quiet"
if ($LASTEXITCODE -eq 0) { Write-OK "websockets installed" }
else { Write-Info "pip install may have had warnings - continuing" }

if (-not $SkipGit -and (Test-Path (Join-Path $Root ".git"))) {
    Push-Location $Root
    git add -A
    if (git status --porcelain) {
        git commit -m "DXLink streaming backend: dx_streamer + account_streamer + WS endpoint + data_store live quotes"
        git push
        Write-OK "Git push complete."
    } else { Write-Info "Nothing to commit." }
    Pop-Location
}

Write-OK ""
Write-OK "=== DXLink Streaming Backend Installed ==="
Write-Host ""
Write-Host "New backend files:" -ForegroundColor Yellow
Write-Host "  dx_streamer.py      - DXLink WebSocket: live quotes, candles, Greeks"
Write-Host "  account_streamer.py - Tasty account WebSocket: fills, balances, positions"
Write-Host "  data_store.py       - Now stores live_quotes + option_greeks + live_balance"
Write-Host "  main.py             - New endpoints:"
Write-Host "      WS  /ws/stream                  <- React connects here for all events"
Write-Host "      POST /stream/subscribe/quotes   <- subscribe symbols to live quotes"
Write-Host "      POST /stream/subscribe/candles  <- subscribe symbol+period to candles"
Write-Host "      POST /stream/subscribe/greeks   <- subscribe option legs to live Greeks"
Write-Host "      GET  /stream/candles            <- get cached candles (DXLink or Schwab fallback)"
Write-Host "      GET  /stream/status             <- see what is connected and subscribed"
Write-Host "      GET  /quote/live                <- get latest live DXLink quote for symbol"
Write-Host ""
Write-Host "Restart the app to activate:" -ForegroundColor Cyan
Write-Host "  wsl bash -lc 'cd /mnt/c/Users/alexm/granite_trader && ./install_and_run_wsl.sh'"
Write-Host ""
Write-Host "Test the stream status after startup:" -ForegroundColor Cyan
Write-Host "  http://localhost:8000/stream/status"
Write-Host "  http://localhost:8000/health"
Write-Host ""
Write-Host "React frontend changes (ws/stream consumer) = NEXT SESSION" -ForegroundColor Yellow
