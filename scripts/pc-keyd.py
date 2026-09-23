#!/usr/bin/env python3
"""pc-keyd — uinput 组合键注入守护（plasma-keyboard PC 布局的 Ctrl/Alt 组合通道）。

背景：input-method-v1 的 send_key 协议不带 modifiers，VKB 的 sendKeyClick 修饰键
会被 qtwayland 丢弃；唯一可靠通道是 /dev/uinput 注入真实按键。
用法：GET http://127.0.0.1:48222/combo?key=67&mods=ctrl,alt   （key=Qt::Key 码）
      GET /ping -> pong
无需 root（/dev/uinput 由接管脚本建好并 666）。单实例：端口占用即退出。
"""
import ctypes, fcntl, os, struct, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

UINPUT_FD = os.open("/dev/uinput", os.O_WRONLY)
EV_SYN, EV_KEY = 0, 1
UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x5501, 0x5502
# struct uinput_user_dev: name[80] u32 bustype vendor product version u16 id[80] effect[32]
def _open_kb():
    fcntl.ioctl(UINPUT_FD, UI_SET_EVBIT, EV_KEY)
    for code in range(0x2ff + 1):
        fcntl.ioctl(UINPUT_FD, UI_SET_KEYBIT, code)
    name = b"plasma-keyboard-pc"
    data = name.ljust(80, b"\0") + struct.pack("HHHHI", 0x11, 0x01, 0x01, 0x01, 0) + bytes(4 * 64 * 4)  # ABS_CNT=64 (sizeof(uinput_user_dev)=1116, measured)
    os.write(UINPUT_FD, data)
    fcntl.ioctl(UINPUT_FD, UI_DEV_CREATE)

def _ev(t, code, value):
    os.write(UINPUT_FD, struct.pack("llHHi", 0, 0, t, code, value))

# Qt::Key -> evdev keycode
MODMAP = {"ctrl": 29, "shift": 42, "alt": 56, "meta": 125}
def qt_to_evdev(key):
    k = int(key)
    if 0x41 <= k <= 0x5A: return k - 0x41 + 30          # A-Z
    if 0x61 <= k <= 0x7A: return k - 0x61 + 30          # a-z
    if 0x30 <= k <= 0x39: return k - 0x30 + 2 if k > 0x30 else 11  # 1..9,0
    table = {0x20:57, 0x2D:12, 0x3D:13, 0x5B:26, 0x5D:27, 0x5C:43, 0x3B:39,
             0x27:40, 0x2C:51, 0x2E:52, 0x2F:53, 0x60:41, 0x09:15, 0x0D:28,
             0x1B:1, 0x08:14,
             0x01000000:106, 0x01000001:108, 0x01000004:102, 0x01000005:103,
             0x01000006:104, 0x01000007:105, 0x01000008:107, 0x01000009:109,
             0x0100000A:110, 0x0100000B:111}
    return table.get(k)
# Qt function key block: Key_Escape=0x1B, Key_Tab=0x1000001, Home=0x01000010...
QTFUNC = {0x01000000:1, 0x01000001:15, 0x01000004:102, 0x01000005:103,
          0x01000006:104, 0x01000007:105, 0x01000008:106, 0x01000009:108,
          0x0100000A:107, 0x0100000B:109, 0x01000010:102, 0x01000011:107,
          0x01000012:103, 0x01000013:108, 0x01000014:105, 0x01000015:106,
          0x01000016:104, 0x01000017:109}

def resolve(key):
    k = int(key)
    if k in QTFUNC: return QTFUNC[k]
    return qt_to_evdev(k)

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/unstick":
            for c in (29, 42, 56, 125, 100, 97, 105):
                _ev(EV_KEY, c, 0); _ev(EV_SYN, 0, 0)
            self.send_response(204); self.end_headers(); return
        if u.path == "/ping":
            self.send_response(204); self.end_headers(); return
        if u.path == "/combo":
            q = parse_qs(u.query)
            code = resolve(q["key"][0]) if "key" in q else None
            mods = [m for m in q.get("mods", [""])[0].split(",") if m in MODMAP]
            if code is not None:
                try:
                    for m in mods: _ev(EV_KEY, MODMAP[m], 1); _ev(EV_SYN, 0, 0)
                    _ev(EV_KEY, code, 1); _ev(EV_SYN, 0, 0)
                    _ev(EV_KEY, code, 0); _ev(EV_SYN, 0, 0)
                finally:
                    # 抬起必须无条件执行，否则内核里留下卡住的修饰键（09-23 实锤）
                    for m in reversed(mods):
                        try: _ev(EV_KEY, MODMAP[m], 0); _ev(EV_SYN, 0, 0)
                        except OSError: pass
            if u.path == "/unstick":
                pass
            self.send_response(204); self.end_headers(); return
        self.send_response(404); self.end_headers()
    def log_message(self, *a): pass

if __name__ == "__main__":
    _open_kb()
    srv = HTTPServer(("127.0.0.1", 48222), H)
    sys.stderr.write("pc-keyd up\n"); sys.stderr.flush()
    srv.serve_forever()
