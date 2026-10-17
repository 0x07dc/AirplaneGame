#!/usr/bin/env python3
"""
AIRPLANE COMBAT SIMULATOR // AUTOMATED MASTER SERVER
Lightweight, zero-dependency master server registry and heartbeat monitor.

Endpoints:
  GET  /api/servers       -> JSON array of active game servers
  GET  /api/servers.txt   -> Plaintext list (name|ip|port|players|max_players|ping|mode)
  POST /api/heartbeat     -> Register or update a game server heartbeat
  POST /api/unregister   -> Remove a game server immediately upon shutdown
  GET  /health            -> Health check endpoint
  GET  /                  -> Web dashboard showing active servers, player counts, and latencies
"""

import argparse
import json
import logging
import os
import sys
import threading
import time
from http import HTTPStatus
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

class ServerRegistry:
    def __init__(self, timeout_sec=45.0):
        self.lock = threading.Lock()
        self.timeout_sec = timeout_sec
        # key: (ip, port) -> dict
        self.servers = {}

    def heartbeat(self, ip: str, port: int, name: str, players: int, max_players: int, mode: str, ping_hint: int = 15):
        now = time.time()
        key = f"{ip}:{port}"
        with self.lock:
            is_new = key not in self.servers
            self.servers[key] = {
                "id": key,
                "name": name[:48],
                "ip": ip,
                "port": port,
                "players": max(0, min(64, players)),
                "max_players": max(1, min(64, max_players)),
                "mode": mode[:24],
                "ping": ping_hint,
                "last_seen": now,
                "created_at": self.servers[key]["created_at"] if not is_new else now,
            }
            if is_new:
                logging.info(f"[REGISTER] New server registered: {name} ({key}) [Mode: {mode}, Players: {players}/{max_players}]")
            else:
                logging.debug(f"[HEARTBEAT] Updated {key}: {players}/{max_players} players")

    def unregister(self, ip: str, port: int):
        key = f"{ip}:{port}"
        with self.lock:
            if key in self.servers:
                srv = self.servers.pop(key)
                logging.info(f"[UNREGISTER] Server removed: {srv['name']} ({key})")
                return True
        return False

    def get_active_servers(self):
        now = time.time()
        with self.lock:
            active = []
            for s in self.servers.values():
                if now - s["last_seen"] <= self.timeout_sec:
                    # Calculate ping estimate based on freshness
                    elapsed = now - s["last_seen"]
                    s_copy = dict(s)
                    s_copy["age_sec"] = round(elapsed, 1)
                    active.append(s_copy)
            # Sort by player count descending, then name
            active.sort(key=lambda x: (-x["players"], x["name"]))
            return active

    def prune_stale(self):
        now = time.time()
        with self.lock:
            keys_to_remove = [k for k, s in self.servers.items() if now - s["last_seen"] > self.timeout_sec]
            for k in keys_to_remove:
                srv = self.servers.pop(k)
                logging.info(f"[EXPIRED] Pruned inactive server: {srv['name']} ({k}) (No heartbeat in {self.timeout_sec}s)")

registry = ServerRegistry(timeout_sec=45.0)

def prune_worker():
    while True:
        time.sleep(5.0)
        try:
            registry.prune_stale()
        except Exception as e:
            logging.error(f"Error during pruning: {e}")

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AIRPLANE GAME // MASTER SERVER</title>
  <style>
    :root {
      --bg: #090d13;
      --card-bg: #101622;
      --border: #1b263b;
      --cyan: #00e5ff;
      --gold: #ffb703;
      --text: #e0e6ed;
      --dim: #7f8c9d;
      --green: #00f59b;
    }
    body {
      background-color: var(--bg);
      color: var(--text);
      font-family: 'JetBrains Mono', 'Courier New', monospace;
      margin: 0;
      padding: 30px;
      display: flex;
      flex-direction: column;
      align-items: center;
    }
    .container {
      width: 100%;
      max-width: 980px;
    }
    header {
      border-bottom: 2px solid var(--cyan);
      padding-bottom: 15px;
      margin-bottom: 25px;
      display: flex;
      justify-content: space-between;
      align-items: flex-end;
    }
    h1 {
      margin: 0;
      color: var(--cyan);
      font-size: 24px;
      letter-spacing: 2px;
      text-transform: uppercase;
    }
    .badge {
      display: inline-block;
      padding: 4px 10px;
      border-radius: 3px;
      font-size: 12px;
      font-weight: bold;
      letter-spacing: 1px;
    }
    .badge-online {
      background: rgba(0, 245, 155, 0.15);
      border: 1px solid var(--green);
      color: var(--green);
    }
    .metrics {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 15px;
      margin-bottom: 25px;
    }
    .metric-card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      padding: 15px;
      border-radius: 4px;
      text-align: center;
    }
    .metric-val {
      font-size: 28px;
      font-weight: bold;
      color: var(--gold);
    }
    .metric-lbl {
      color: var(--dim);
      font-size: 12px;
      margin-top: 5px;
      text-transform: uppercase;
      letter-spacing: 1px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 4px;
      overflow: hidden;
    }
    th, td {
      padding: 12px 16px;
      text-align: left;
      border-bottom: 1px solid var(--border);
      font-size: 14px;
    }
    th {
      background: #0d121c;
      color: var(--cyan);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 1px;
    }
    tr:hover {
      background: rgba(0, 229, 255, 0.04);
    }
    .server-name {
      font-weight: bold;
      color: #fff;
    }
    .status-dot {
      display: inline-block;
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: var(--green);
      margin-right: 8px;
    }
    .empty-state {
      padding: 40px;
      text-align: center;
      color: var(--dim);
    }
    footer {
      margin-top: 30px;
      text-align: center;
      color: var(--dim);
      font-size: 12px;
    }
  </style>
  <script>
    setInterval(() => location.reload(), 5000);
  </script>
</head>
<body>
  <div class="container">
    <header>
      <div>
        <h1>Airplane Combat // Master Server</h1>
        <div style="color: var(--dim); font-size: 12px; margin-top: 4px;">GLOBAL MULTIPLAYER SQUADRON REGISTRY</div>
      </div>
      <div>
        <span class="badge badge-online">SYSTEM ACTIVE</span>
      </div>
    </header>

    <div class="metrics">
      <div class="metric-card">
        <div class="metric-val" id="srv-count">{SERVER_COUNT}</div>
        <div class="metric-lbl">Active Servers</div>
      </div>
      <div class="metric-card">
        <div class="metric-val" id="pilot-count">{PILOT_COUNT}</div>
        <div class="metric-lbl">Pilots In Flight</div>
      </div>
      <div class="metric-card">
        <div class="metric-val" id="max-slots">{SLOT_COUNT}</div>
        <div class="metric-lbl">Total Capacity</div>
      </div>
    </div>

    <table>
      <thead>
        <tr>
          <th>Status</th>
          <th>Server Name</th>
          <th>Endpoint</th>
          <th>Game Mode</th>
          <th>Pilots</th>
          <th>Heartbeat</th>
        </tr>
      </thead>
      <tbody>
        {TABLE_ROWS}
      </tbody>
    </table>

    <footer>
      Auto-refreshing every 5s • Server endpoints queryable via <code>GET /api/servers</code> and <code>GET /api/servers.txt</code>
    </footer>
  </div>
</body>
</html>
"""

class MasterServerHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Override to keep logs clean
        logging.info(f"{self.client_address[0]} - - {format % args}")

    def send_json(self, status: int, data: any):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, status: int, text: str):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self.send_json(HTTPStatus.OK, {"status": "ok", "time": time.time()})
            return

        if self.path == "/api/servers":
            servers = registry.get_active_servers()
            self.send_json(HTTPStatus.OK, {"servers": servers, "count": len(servers)})
            return

        if self.path == "/api/servers.txt":
            servers = registry.get_active_servers()
            # Format: NAME|IP|PORT|PLAYERS|MAX_PLAYERS|PING|MODE
            lines = []
            for s in servers:
                line = f"{s['name']}|{s['ip']}|{s['port']}|{s['players']}|{s['max_players']}|{s['ping']}|{s['mode']}"
                lines.append(line)
            self.send_text(HTTPStatus.OK, "\n".join(lines) + ("\n" if lines else ""))
            return

        if self.path == "/" or self.path.startswith("/?"):
            servers = registry.get_active_servers()
            total_pilots = sum(s["players"] for s in servers)
            total_slots = sum(s["max_players"] for s in servers)

            if servers:
                rows = []
                for s in servers:
                    row = f"""<tr>
                      <td><span class="status-dot"></span>LIVE</td>
                      <td class="server-name">{s['name']}</td>
                      <td><code>{s['ip']}:{s['port']}</code></td>
                      <td>{s['mode']}</td>
                      <td><b>{s['players']}</b> / {s['max_players']}</td>
                      <td style="color: var(--dim)">{s['age_sec']}s ago</td>
                    </tr>"""
                    rows.append(row)
                table_content = "\n".join(rows)
            else:
                table_content = """<tr><td colspan="6" class="empty-state">No servers currently broadcasting. Launch host mode or start a dedicated server to appear here!</td></tr>"""

            html = DASHBOARD_HTML.replace("{SERVER_COUNT}", str(len(servers))) \
                                .replace("{PILOT_COUNT}", str(total_pilots)) \
                                .replace("{SLOT_COUNT}", str(total_slots)) \
                                .replace("{TABLE_ROWS}", table_content)
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html.encode("utf-8"))))
            self.end_headers()
            self.wfile.write(html.encode("utf-8"))
            return

        self.send_json(HTTPStatus.NOT_FOUND, {"error": "Not Found"})

    def do_POST(self):
        content_len = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_len) if content_len > 0 else b"{}"

        try:
            data = json.loads(post_data.decode("utf-8"))
        except Exception:
            data = {}

        client_ip = self.client_address[0]
        # Allow loopback override if specified in data
        reported_ip = data.get("ip")
        effective_ip = reported_ip if (reported_ip and reported_ip != "0.0.0.0") else client_ip

        if self.path == "/api/heartbeat":
            name = data.get("name", "Dedicated Server")
            port = int(data.get("port", 7777))
            players = int(data.get("players", 1))
            max_players = int(data.get("max_players", 16))
            mode = data.get("mode", "COMBAT 16v16")
            ping = int(data.get("ping", 15))

            registry.heartbeat(effective_ip, port, name, players, max_players, mode, ping)
            self.send_json(HTTPStatus.OK, {
                "status": "registered",
                "ip": effective_ip,
                "port": port,
                "timeout": registry.timeout_sec,
            })
            return

        if self.path == "/api/unregister":
            port = int(data.get("port", 7777))
            removed = registry.unregister(effective_ip, port)
            self.send_json(HTTPStatus.OK, {"status": "unregistered", "removed": removed})
            return

        self.send_json(HTTPStatus.NOT_FOUND, {"error": "Endpoint not found"})


def main():
    parser = argparse.ArgumentParser(description="Airplane Combat Simulator Master Server")
    parser.add_argument("--host", default="0.0.0.0", help="Listen address (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8080, help="Listen HTTP port (default: 8080)")
    parser.add_argument("--timeout", type=float, default=45.0, help="Server expiration timeout in seconds (default: 45)")
    args = parser.parse_args()

    registry.timeout_sec = args.timeout

    # Background pruning thread
    t = threading.Thread(target=prune_worker, daemon=True)
    t.start()

    server = ThreadedHTTPServer((args.host, args.port), MasterServerHandler)
    logging.info(f"================================================================================")
    logging.info(f"   AIRPLANE COMBAT SIMULATOR // MASTER SERVER ONLINE")
    logging.info(f"   Listening on http://{args.host}:{args.port}")
    logging.info(f"   Endpoints: /api/servers, /api/servers.txt, /api/heartbeat, /health")
    logging.info(f"================================================================================")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Shutting down master server...")
        server.shutdown()
        server.server_close()

if __name__ == "__main__":
    main()
