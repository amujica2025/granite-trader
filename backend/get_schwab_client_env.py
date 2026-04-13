from schwab.auth import client_from_manual_flow
from dotenv import load_dotenv
import os

load_dotenv()
API_KEY = os.environ["SCHWAB_CLIENT_ID"]
APP_SECRET = os.environ["SCHWAB_CLIENT_SECRET"]
CALLBACK_URL = os.getenv("SCHWAB_REDIRECT_URI", "https://127.0.0.1:8182")
TOKEN_PATH = os.getenv("SCHWAB_TOKEN_PATH", "/mnt/c/Users/alexm/granite_trader/backend/schwab_token.json")

client = client_from_manual_flow(api_key=API_KEY, app_secret=APP_SECRET, callback_url=CALLBACK_URL, token_path=TOKEN_PATH)
print("SUCCESS")
print(f"Token file saved to: {TOKEN_PATH}")
r = client.get_quote("SPY")
print(r.status_code)
print(r.json())
