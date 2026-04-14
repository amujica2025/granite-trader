from __future__ import annotations
import os
from typing import Any
import requests

PUSHOVER_USER  = os.getenv("PUSHOVER_USER_KEY",  "uw8mofrtidtoc46hth3v86dymnssyi")
PUSHOVER_TOKEN = os.getenv("PUSHOVER_API_TOKEN", "a9sgeqip8nhorgd9mb4r1f1qkcrf4j")
PUSHOVER_URL   = "https://api.pushover.net/1/messages.json"

def send_pushover(message: str, title: str = "Granite Trader") -> dict[str, Any]:
    if not PUSHOVER_USER or not PUSHOVER_TOKEN:
        return {"ok": False, "error": "Pushover credentials not configured"}
    try:
        resp = requests.post(PUSHOVER_URL, data={
            "user": PUSHOVER_USER, "token": PUSHOVER_TOKEN,
            "message": message, "title": title, "sound": "pushover",
        }, timeout=8)
        data = resp.json() if resp.text else {}
        return {"ok": data.get("status") == 1, "pushover": data}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}

def send_whatsapp_message(message: str) -> dict[str, Any]:
    return {"ok": False, "note": "WhatsApp replaced by Pushover"}
