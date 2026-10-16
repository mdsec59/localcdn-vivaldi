#!/usr/bin/env python3
"""Cliente CDP mínimo (solo biblioteca estándar) para Vivaldi/Chromium.

Uso:
    cdp.py list   <puerto>
    cdp.py eval   <puerto> <subcadena-del-target> <expresion-js>
    cdp.py shot   <puerto> <subcadena-del-target> <fichero.png>
    cdp.py listen <puerto> <subcadena-del-target> [segundos] [subcadena-de-filtro]
    cdp.py close  <puerto>

Ejemplos:
    cdp.py list 9333
    cdp.py eval 9333 "127.0.0.1:8899" "document.title"
    cdp.py eval 9333 "background.html" "chrome.storage.local.get(null)"
    cdp.py shot 9333 "localcdn.org" /tmp/opencode/test-oficial.png
    cdp.py listen 9333 "127.0.0.1:8903" 6 "webfonts" "location.reload()"
    cdp.py close 9333
"""

import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.request


def http_json(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=15) as fh:
        return json.load(fh)


class WebSocket:
    def __init__(self, url):
        assert url.startswith("ws://"), url
        hostport, _, path = url[5:].partition("/")
        host, _, port = hostport.partition(":")
        self.sock = socket.create_connection((host, int(port or 80)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n".encode()
        )
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError("handshake cerrado por el navegador")
            buf += chunk
        head, _, self.buf = buf.partition(b"\r\n\r\n")
        if b"101" not in head.split(b"\r\n")[0]:
            raise IOError(f"handshake fallido: {head!r}")
        self._id = 0

    def _take(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise IOError("conexión websocket cerrada")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, method, params=None):
        self._id += 1
        payload = json.dumps(
            {"id": self._id, "method": method, "params": params or {}}
        ).encode()
        mask, header, n = os.urandom(4), bytearray(b"\x81"), len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + mask + masked)
        return self._id

    def _frame(self):
        b1, b2 = self._take(2)
        opcode, ln = b1 & 0x0F, b2 & 0x7F
        masked = b2 & 0x80
        if ln == 126:
            ln = struct.unpack(">H", self._take(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", self._take(8))[0]
        mask = self._take(4) if masked else None
        data = self._take(ln)
        if mask:
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        return opcode, data

    def call(self, method, params=None):
        want = self.send(method, params)
        while True:
            opcode, data = self._frame()
            if opcode == 0x8:
                raise IOError("websocket cerrado por el navegador")
            if opcode not in (0x1, 0x2):
                continue
            msg = json.loads(data)
            if msg.get("id") == want:
                return msg

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def find_target(port, needle):
    targets = http_json(port, "/json/list")
    for t in targets:
        blob = json.dumps(t)
        if needle in blob:
            return t
    return None


def _short(value, limit=200):
    value = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return value if len(value) <= limit else value[:limit] + "…"


def _summarize_event(method, params, by_id):
    """Resume un evento Network.* en un dict compacto y trazable por requestId."""
    if method == "Network.requestWillBeSent":
        rid = params.get("requestId")
        by_id[rid] = params.get("request", {}).get("url", "")
        return {
            "ev": "request",
            "id": rid,
            "url": params.get("request", {}).get("url", ""),
            "type": params.get("type"),
            "initiator": _short(
                (params.get("initiator") or {}).get("url")
                or (params.get("initiator") or {}).get("type", ""),
                120,
            ),
        }
    if method == "Network.responseReceived":
        rid = params.get("requestId")
        response = params.get("response", {})
        by_id.setdefault(rid, response.get("url", ""))
        return {
            "ev": "response",
            "id": rid,
            "status": response.get("status"),
            "tipo": response.get("mimeType"),
            "url": response.get("url", ""),
        }
    if method == "Network.loadingFailed":
        rid = params.get("requestId")
        return {
            "ev": "failed",
            "id": rid,
            "error": params.get("errorText"),
            "bloqueado": params.get("blockedReason"),
            "url": by_id.get(rid, "?"),
        }
    if method == "Network.requestWillBeSentExtraInfo":
        rid = params.get("requestId")
        return {
            "ev": "enviado-extra",
            "id": rid,
            "url": by_id.get(rid, "?"),
            "cabeceras": {
                k.lower(): v
                for k, v in (params.get("headers") or {}).items()
                if k.lower()
                in ("origin", "referer", "cookie", "user-agent", "sec-fetch-site")
            },
        }
    if method == "Network.responseReceivedExtraInfo":
        rid = params.get("requestId")
        return {
            "ev": "recibido-extra",
            "id": rid,
            "url": by_id.get(rid, "?"),
            "codigo": params.get("statusCode"),
        }
    return None


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, port = argv[1], int(argv[2])

    if cmd == "list":
        for t in http_json(port, "/json/list"):
            print(
                f"{t.get('type'):16} {t.get('id')}  {t.get('title', '')[:40]}  {t.get('url', '')[:90]}"
            )
        return 0

    if cmd == "shot":
        if len(argv) < 5:
            print(
                "faltan argumentos: shot <puerto> <subcadena> <fichero.png>",
                file=sys.stderr,
            )
            return 2
        target = find_target(port, argv[3])
        if not target:
            print(f"[x] No hay target que contenga: {argv[3]}", file=sys.stderr)
            return 1
        ws = WebSocket(target["webSocketDebuggerUrl"])
        try:
            ws.call("Page.enable")
            reply = ws.call(
                "Page.captureScreenshot",
                {"format": "png", "captureBeyondViewport": True},
            )
        finally:
            ws.close()
        data = reply.get("result", {}).get("data")
        if not data:
            print("[x] El navegador no devolvió datos de captura", file=sys.stderr)
            return 1
        with open(argv[4], "wb") as fh:
            fh.write(base64.b64decode(data))
        print(f"[i] Captura guardada en {argv[4]}")
        return 0

    if cmd == "listen":
        # listen <puerto> <subcadena-del-target> [segundos] [filtro] [js-a-ejecutar]
        if len(argv) < 4:
            print(
                "faltan argumentos: listen <puerto> <subcadena> [segundos] [filtro] [js]",
                file=sys.stderr,
            )
            return 2
        needle = argv[3]
        duration = float(argv[4]) if len(argv) > 4 else 5.0
        pattern = argv[5] if len(argv) > 5 else ""
        script = argv[6] if len(argv) > 6 else ""
        target = find_target(port, needle)
        if not target:
            print(f"[x] No hay target que contenga: {needle}", file=sys.stderr)
            return 1
        ws = WebSocket(target["webSocketDebuggerUrl"])
        collected, by_id = [], {}
        try:
            ws.call("Network.enable")
            ws.call("Page.enable")
            if script:
                # Se lanza ANTES de escuchar: así se capturan las peticiones que provoca.
                ws.call(
                    "Runtime.evaluate",
                    {
                        "expression": script,
                        "awaitPromise": False,
                        "returnByValue": False,
                    },
                )
            deadline = time.time() + duration
            while True:
                remaining = deadline - time.time()
                if remaining <= 0:
                    break
                ws.sock.settimeout(remaining)
                try:
                    opcode, data = ws._frame()
                except (socket.timeout, TimeoutError, OSError, IOError):
                    break
                if opcode not in (0x1, 0x2):
                    continue
                msg = json.loads(data)
                method = msg.get("method", "")
                if not method.startswith("Network."):
                    continue
                params = msg.get("params", {})
                blob = json.dumps(params, ensure_ascii=False)
                if pattern and pattern not in blob:
                    continue
                event = _summarize_event(method, params, by_id)
                if event:
                    collected.append(event)
        finally:
            ws.close()
        print(json.dumps(collected, ensure_ascii=False, indent=2))
        return 0

    if cmd == "close":
        t = http_json(port, "/json/version")
        ws = WebSocket(t["webSocketDebuggerUrl"])
        ws.call("Browser.close")
        ws.close()
        return 0

    if cmd == "eval":
        if len(argv) < 5:
            print("faltan argumentos: eval <puerto> <subcadena> <js>", file=sys.stderr)
            return 2
        needle, expr = argv[3], argv[4]
        target = find_target(port, needle)
        if not target:
            print(f"[x] No hay target que contenga: {needle}", file=sys.stderr)
            return 1
        ws = WebSocket(target["webSocketDebuggerUrl"])
        try:
            reply = ws.call(
                "Runtime.evaluate",
                {
                    "expression": expr,
                    "awaitPromise": True,
                    "returnByValue": True,
                    "allowUnsafeEvalBlockedByCSP": True,
                },
            )
        finally:
            ws.close()
        result = reply.get("result", {})
        if "exceptionDetails" in result:
            print(
                json.dumps(result["exceptionDetails"], ensure_ascii=False),
                file=sys.stderr,
            )
            return 1
        print(
            json.dumps(
                result.get("result", {}).get("value"), ensure_ascii=False, indent=2
            )
        )
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
