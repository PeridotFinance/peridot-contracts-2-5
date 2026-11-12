# DefiLlama coins API (public): hourly market/oracle-aggregate USD prices for the tokens, 90 days. Used only as a reference price (labelled).
import json, urllib.request, os, time
OUT = os.path.join(os.path.dirname(__file__), "..", "data")
TOK = {"WBTC": "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c", "BTCb": "0x152b9d0FdC40C096757F570A51E494bd4b943E50",
       "AUSD": "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", "USDC": "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
       "USDt": "0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7", "sAVAX": "0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE",
       "WAVAX": "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", "BLACK": "0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6", "PHAR": "0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7"}
START = 1785974400  # 6 Aug 2026 00:00 UTC
out = {}
for n, a in TOK.items():
    k = f"avax:{a}"; pts = []; sym = None
    for chunk in range(2):
        st = START + chunk * 300 * 4 * 3600
        u = f"https://coins.llama.fi/chart/{k}?start={st}&span=300&period=4h&searchWidth=4h"
        try:
            r = json.load(urllib.request.urlopen(u, timeout=60)); c = r["coins"].get(k, {}); sym = c.get("symbol"); pts += c.get("prices", [])
        except Exception as e: print(n, "ERR", e)
        time.sleep(0.5)
    out[n] = {"symbol": sym, "prices": pts}; print(n, sym, len(pts))
json.dump(out, open(os.path.join(OUT, "llama_4h.json"), "w"))
