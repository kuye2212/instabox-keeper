#!/usr/bin/env python3
"""本地测试用的假 InstaBox API，只实现 keeper.sh 用到的那几个端点。"""
import json
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {
    "state": "running",
    "startedAt": None,      # epoch 秒
    "cooldownUntil": None,  # ISO8601
    "maxRunMinutes": 120,   # 免费号实测值
}
EVENTS = []
LOCK = threading.Lock()


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _machine(self):
        return {
            "id": "m_test",
            "state": STATE["state"],
            "startedAt": iso(STATE["startedAt"]) if STATE["startedAt"] else None,
            "runStartedAt": iso(STATE["startedAt"]) if STATE["startedAt"] else None,
            "cooldownUntil": STATE["cooldownUntil"],
            "maxRunMinutes": STATE["maxRunMinutes"],
            "autoSuspendAfterSeconds": 1800,
        }

    def do_GET(self):
        p = self.path.split("?")[0]
        with LOCK:
            if p == "/__events":
                return self._send(200, EVENTS)
            if p == "/__body":
                return self._send(200, self._machine())
            if p.startswith("/v1/machines/"):
                return self._send(200, self._machine())
        self._send(404, {"error": "not found"})

    def do_PUT(self):
        p = self.path.split("?")[0]
        with LOCK:
            if "/activity-leases/" in p:
                EVENTS.append({"t": time.time(), "action": "lease"})
                ttl = 300
                try:
                    body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                    ttl = int(body.get("ttlSeconds", ttl))
                except Exception:
                    pass
                return self._send(200, {
                    "id": p.rsplit("/", 1)[-1],
                    "machineId": "m_test",
                    "expiresAt": iso(time.time() + ttl),
                })
        self._send(404, {"error": "not found"})

    def do_DELETE(self):
        p = self.path.split("?")[0]
        with LOCK:
            if "/activity-leases/" in p:
                EVENTS.append({"t": time.time(), "action": "lease-release"})
                return self._send(204, {})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        p = self.path.split("?")[0]
        with LOCK:
            if p == "/__set":
                q = dict(x.split("=", 1) for x in self.path.split("?")[1].split("&")) if "?" in self.path else {}
                if "state" in q:
                    STATE["state"] = q["state"]
                if "startedAgoMin" in q:
                    STATE["startedAt"] = time.time() - float(q["startedAgoMin"]) * 60
                if "cooldown" in q:
                    STATE["cooldownUntil"] = q["cooldown"] or None
                if "maxRunMinutes" in q:
                    STATE["maxRunMinutes"] = int(q["maxRunMinutes"])
                if q.get("clearEvents") == "1":
                    EVENTS.clear()
                return self._send(200, {"ok": True})
            if p.endswith("/start"):
                EVENTS.append({"t": time.time(), "action": "start"})
                STATE["state"] = "running"
                STATE["startedAt"] = time.time()
                STATE["cooldownUntil"] = None
                return self._send(202, {"id": "m_test"})
            if p.endswith("/stop"):
                EVENTS.append({"t": time.time(), "action": "stop"})
                STATE["state"] = "stopped"
                STATE["cooldownUntil"] = iso(time.time() + 600)
                return self._send(202, {"id": "m_test"})
            if p.endswith("/suspend"):
                EVENTS.append({"t": time.time(), "action": "suspend"})
                STATE["state"] = "suspended"
                return self._send(202, {"id": "m_test"})
            if p.endswith("/resume"):
                EVENTS.append({"t": time.time(), "action": "resume"})
                STATE["state"] = "running"
                STATE["startedAt"] = time.time()
                STATE["cooldownUntil"] = None
                return self._send(202, {"id": "m_test"})
        self._send(404, {"error": "not found"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    STATE["startedAt"] = time.time()
    HTTPServer(("127.0.0.1", port), H).serve_forever()
