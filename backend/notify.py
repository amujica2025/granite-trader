from __future__ import annotations
import os
from typing import Any, Dict
import requests

def send_whatsapp_message(message: str) -> Dict[str, Any]:
    access_token = os.getenv("WHATSAPP_ACCESS_TOKEN", "").strip()
    phone_number_id = os.getenv("WHATSAPP_PHONE_NUMBER_ID", "").strip()
    recipient = os.getenv("WHATSAPP_RECIPIENT", "+19512342083").strip()
    if not access_token or not phone_number_id:
        return {"enabled": False, "sent": False, "detail": "WhatsApp Cloud API env vars not configured."}
    payload = {"messaging_product": "whatsapp", "to": recipient, "type": "text", "text": {"body": message}}
    response = requests.post(f"https://graph.facebook.com/v22.0/{phone_number_id}/messages", headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"}, json=payload, timeout=20)
    try:
        body = response.json()
    except Exception:
        body = {"raw": response.text}
    return {"enabled": True, "sent": response.ok, "status_code": response.status_code, "body": body}
