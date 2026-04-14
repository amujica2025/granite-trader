from tasty_adapter import fetch_account_snapshot
import requests, os

snap = fetch_account_snapshot()
tok = snap.get('session_token', '')
print('token length:', len(tok))
print('first 40:', tok[:40])

resp = requests.get(
    'https://api.tastytrade.com/api-quote-tokens',
    headers={'Authorization': 'Bearer ' + tok},
    timeout=10
)
print('status:', resp.status_code)
print('body:', resp.text[:400])
