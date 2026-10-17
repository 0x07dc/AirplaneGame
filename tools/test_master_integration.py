#!/usr/bin/env python3
"""
Automated End-to-End Verification of the Master Server Protocol & REST API.
"""

import subprocess
import time
import urllib.request
import json
import socket
import sys

def main():
    print("=" * 80)
    print("   AUTOMATED MASTER SERVER INTEGRATION TEST SUITE")
    print("=" * 80)

    # Disable proxy for loopback
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    urllib.request.install_opener(opener)

    port = 8089
    proc = subprocess.Popen([sys.executable, "tools/master_server.py", "--port", str(port)])
    time.sleep(0.5)

    try:
        # Step 1: Health Check
        print("[TEST 1] Testing /health endpoint...")
        res = urllib.request.urlopen(f"http://127.0.0.1:{port}/health").read().decode()
        data = json.loads(res)
        assert data.get("status") == "ok", "Expected status ok"
        print("  -> Health status OK")

        # Step 2: Register Host via HTTP POST
        print("[TEST 2] Testing /api/heartbeat registration...")
        hb_payload = json.dumps({
            "name": "US-PACIFIC // FLEET STRIKE",
            "port": 7777,
            "players": 6,
            "max_players": 16,
            "mode": "CARRIER ASSAULT",
            "ping": 18
        }).encode("utf-8")
        req = urllib.request.Request(f"http://127.0.0.1:{port}/api/heartbeat", data=hb_payload, headers={"Content-Type": "application/json"})
        res = urllib.request.urlopen(req).read().decode()
        hb_resp = json.loads(res)
        assert hb_resp.get("status") == "registered", "Expected registered"
        print("  -> Host registered successfully")

        # Step 3: Query Plaintext Format (/api/servers.txt)
        print("[TEST 3] Testing /api/servers.txt plaintext format for engine...")
        res_txt = urllib.request.urlopen(f"http://127.0.0.1:{port}/api/servers.txt").read().decode().strip()
        print(f"  -> Plaintext line: {res_txt}")
        parts = res_txt.split("|")
        assert len(parts) == 7, f"Expected 7 columns, got {len(parts)}"
        assert parts[0] == "US-PACIFIC // FLEET STRIKE"
        assert parts[1] == "127.0.0.1"
        assert parts[2] == "7777"
        assert parts[3] == "6"
        assert parts[4] == "16"
        assert parts[6] == "CARRIER ASSAULT"
        print("  -> Plaintext columns parsed and validated")

        # Step 4: Query Web HTML Dashboard (/)
        print("[TEST 4] Testing GET / web dashboard...")
        res_html = urllib.request.urlopen(f"http://127.0.0.1:{port}/").read().decode()
        assert "Airplane Combat // Master Server" in res_html
        assert "US-PACIFIC // FLEET STRIKE" in res_html
        print("  -> Cyberpunk avionics web dashboard verified")

        # Step 5: Unregister Host
        print("[TEST 5] Testing /api/unregister upon host shutdown...")
        unreg_payload = json.dumps({"port": 7777}).encode("utf-8")
        req = urllib.request.Request(f"http://127.0.0.1:{port}/api/unregister", data=unreg_payload, headers={"Content-Type": "application/json"})
        res = urllib.request.urlopen(req).read().decode()
        unreg_resp = json.loads(res)
        assert unreg_resp.get("status") == "unregistered"
        assert unreg_resp.get("removed") is True
        print("  -> Host unregistered successfully")

        # Step 6: Verify Empty Plaintext
        res_empty = urllib.request.urlopen(f"http://127.0.0.1:{port}/api/servers.txt").read().decode().strip()
        assert res_empty == "", f"Expected empty list, got: {res_empty}"
        print("  -> Server list correctly empty after unregister")

        print("\n" + "=" * 80)
        print("   ALL MASTER SERVER INTEGRATION TESTS PASSED (6/6)")
        print("=" * 80)

    finally:
        proc.terminate()
        proc.wait()

if __name__ == "__main__":
    main()
