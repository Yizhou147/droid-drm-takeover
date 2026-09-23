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
    # 09-23 教训：①原名 plasma-keyboard-pc 已作废；②开机时 crash-loop 在 24s 内反复
    # 拉起（虽未建成设备，但加上白天调试期十几次设备建删风暴）把小米内核的 uinput
    # 注入防滥用打满 —— 本启动会话内所有后续注入被静默丢弃（write 仍返回 24，evdev
    # 0 包），冷却或重启恢复。因此：设备名换新；服务禁止 systemd 自启（防开机风暴）；
    # 调试时严禁反复重启守护进程/反复建删 uinput 设备，一次起、一次验。
    name = b"pc-keyd-kbd"
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

def _expose_devnode():
    """容器里没有 udevd：手动补 /dev/input/eventNN 节点 + udev 数据库记录，
    否则 kwin(libinput) 看不见这个虚拟键盘（09-23 DRM 侧实锤）。"""
    import re, time
    time.sleep(0.3)
    try:
        txt = open("/proc/bus/input/devices").read()
        m = re.search(r'Name="pc-keyd-kbd".*?Handlers=event(\d+)', txt, re.S)
        if not m: return
        ev = "event" + m.group(1)
        dev = open("/sys/class/input/%s/dev" % ev).read().strip()  # "13:80"
        minor = int(dev.split(":")[1])
        node = "/dev/input/" + ev
        if not os.path.exists(node):
            # mknod 的 mode 会被进程 umask 削掉（systemd 默认 022 → 0644，
            # kwin 以 xieyizhou 身份 open 直接 EACCES），必须显式 chmod 兜底
            os.mknod(node, 0o666 | 0o020000, os.makedev(13, minor))
        os.chmod(node, 0o666)
        data = "/run/udev/data/c13:%d" % minor
        with open(data, "w") as f:
            f.write("Q:100\n"
                    "E:DEVPATH=/devices/virtual/input/%s\n"
                    "E:MAJOR=13\nE:MINOR=%d\nE:SUBSYSTEM=input\n"
                    "E:DEVNAME=input/%s\nE:ID_INPUT=1\nE:ID_INPUT_KEY=1\n"
                    "E:ID_INPUT_KEYBOARD=1\nE:LIBINPUT_DEVICE_GROUP=11/1/1:pc-keyd-kbd\n"
                    "H:uaccess\nH:seat\n" % (ev, minor, ev))
        sys.stderr.write("exposed %s c13:%d\n" % (node, minor))
    except OSError as e:
        sys.stderr.write("expose failed (need root?): %s\n" % e)

if __name__ == "__main__":
    _open_kb()
    _expose_devnode()
    srv = HTTPServer(("127.0.0.1", 48222), H)
    sys.stderr.write("pc-keyd up\n"); sys.stderr.flush()
    srv.serve_forever()
