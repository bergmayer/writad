#!/usr/bin/env python3
"""
HTTP bridge: receives shortcut requests from Maestro and forwards them
to the iOS Simulator via osascript. Maestro's runScript can't shell out
directly, so we proxy through this tiny localhost server.

Endpoints:
  GET /shortcut?key=X&mods=cmd,shift      -> send ⌘⇧X to Simulator
  GET /paste?text=URL_ENCODED              -> set clipboard then ⌘V
  GET /press?key=Up                        -> arrow keys / function keys
  GET /quit                                -> shutdown
"""
import http.server
import socketserver
import subprocess
import sys
import threading
import urllib.parse

PORT = 9876

MOD_MAP = {
    "cmd":     "command down",
    "command": "command down",
    "shift":   "shift down",
    "opt":     "option down",
    "option":  "option down",
    "alt":     "option down",
    "ctrl":    "control down",
    "control": "control down",
    "fn":      "function down",
}

# Special keys map to AppleScript key codes (System Events).
KEY_CODE = {
    "up":        126,
    "down":      125,
    "left":      123,
    "right":     124,
    "home":      115,
    "end":       119,
    "pageup":    116,
    "pagedown":  121,
    "esc":       53,
    "tab":       48,
    "return":    36,
    "enter":     36,
    "delete":    51,
    "forwarddelete": 117,
}


def osa(script: str) -> int:
    return subprocess.run(["osascript", "-e", script], capture_output=True).returncode


def send_shortcut(key: str, mods: str) -> int:
    parts = [MOD_MAP[m.strip().lower()] for m in mods.split(",") if m.strip()]
    using = "{" + ", ".join(parts) + "}" if parts else ""
    code = KEY_CODE.get(key.lower())
    if code is not None:
        stroke = f'key code {code}' + (f' using {using}' if using else '')
    else:
        safe_key = key.replace('"', '\\"')
        stroke = f'keystroke "{safe_key}"' + (f' using {using}' if using else '')
    script = (
        'tell application "Simulator" to activate\n'
        'delay 0.12\n'
        f'tell application "System Events" to {stroke}\n'
    )
    return osa(script)


def set_clipboard(text: str) -> int:
    # Use stdin via heredoc-style script to avoid escaping nightmares.
    return subprocess.run(["pbcopy"], input=text.encode("utf-8")).returncode


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        # Quiet — Maestro polls; we don't need access-log noise.
        pass

    def _ok(self, body=b"ok"):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(parsed.query)
        path = parsed.path

        if path == "/shortcut":
            key = q.get("key", [""])[0]
            mods = q.get("mods", [""])[0]
            send_shortcut(key, mods)
            return self._ok()

        if path == "/paste":
            text = q.get("text", [""])[0]
            set_clipboard(text)
            send_shortcut("v", "cmd")
            return self._ok()

        if path == "/press":
            key = q.get("key", [""])[0]
            mods = q.get("mods", [""])[0]
            send_shortcut(key, mods)
            return self._ok()

        if path == "/clipboard":
            result = subprocess.run(["pbpaste"], capture_output=True)
            return self._ok(result.stdout)

        if path == "/quit":
            self._ok(b"bye")
            threading.Thread(target=lambda: (server.shutdown(),), daemon=True).start()
            return

        if path == "/ping":
            return self._ok(b"pong")

        self.send_error(404, "unknown endpoint")


if __name__ == "__main__":
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as server:
        print(f"shortcut-bridge listening on :{PORT}", flush=True)
        server.serve_forever()
