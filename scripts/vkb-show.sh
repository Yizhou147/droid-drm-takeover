#!/bin/bash
# vkb-show.sh — 召唤虚拟键盘（X11 应用也能用）。
# 原理：kwin 官方 D-Bus org.kde.kwin.VirtualKeyboard.forceActivate()
# （kwin 6.6 VirtualKeyboardDBus，源码 src/virtualkeyboard_dbus.cpp）。
# 总线自动探测：anland 会话用 dbus-run-session 私有总线（从 plasmashell 环境读）；
# DRM 轮用 /run/user/1000/bus（desk-takeover 硬编码）。两模式通吃。
# 放置：/usr/local/bin/vkb-show.sh；桌面启动器「显示虚拟键盘」调用它。

ADDR=""
if [ -r /run/user/1000/bus ] && grep -q 'display.sock' /proc/$(pgrep -x kwin_wayland | tail -1)/environ 2>/dev/null; then
    ADDR=""   # DRM 轮：kwin 的会话总线 = /run/user/1000/bus（默认）
fi
# 从 plasmashell 环境读实际会话总线（anland 的私有 bus / DRM 的默认 bus 二者取一）
p=$(pgrep -x plasmashell | head -1)
if [ -n "$p" ]; then
    b=$(tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep '^DBUS_SESSION_BUS_ADDRESS=' | cut -d= -f2-)
    [ -n "$b" ] && ADDR="$b"
fi
if [ -z "$ADDR" ]; then
    ADDR="unix:path=/run/user/1000/bus"
fi

export DBUS_SESSION_BUS_ADDRESS="$ADDR"
for i in 1 2 3; do
    gdbus call --session --dest org.kde.KWin --object-path /VirtualKeyboard \
        --method org.kde.kwin.VirtualKeyboard.forceActivate >/dev/null 2>&1 && exit 0
    sleep 1
done
echo "召唤失败：plasma-keyboard 未运行或 kwin 无 VirtualKeyboard 接口" >&2
exit 1
