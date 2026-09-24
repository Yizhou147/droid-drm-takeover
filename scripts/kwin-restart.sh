#!/bin/bash
# kwin-restart.sh — 常驻接管模式下只重启容器侧 kwinwrap+kwin(不碰 Android 桌面)。
# 以 root 运行。
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DIR=$ROOT
LOGD=${LOG_DIR:-$(dirname "$ROOT")/logs}
mkdir -p "$LOGD"
pkill -9 -f "kwinwrap --out" 2>/dev/null
pkill -9 -f "socket=taketest" 2>/dev/null
pkill -9 -x Xwayland 2>/dev/null   # kwin 的子进程，不补刀会占住 display 号
sleep 1
env KWINWRAP_HIJACK=1 KWINWRAP_FILTER=1 KWINWRAP_SECCOMP=1 \
    KWINWRAP_UID=1000 KWINWRAP_GID=1000 \
    "$DIR/bin/kwinwrap" --out $LOGD/kwinatomic.log -- \
    env -u DISPLAY -u WAYLAND_DISPLAY HOME=/home/xieyizhou \
        KWIN_DRM_DEVICES=/dev/dri/card0 \
        FD_MESA_DEBUG=noubwc \
        KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 \
        XDG_SESSION_ID=bogus \
        XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        kwin_wayland --socket=taketest --xwayland \
    > $LOGD/kwin.log 2>&1 &
KPID=$!
sleep 5
if kill -0 $KPID 2>/dev/null; then
    echo "KWIN-RESTART OK pid=$KPID"
    # XWayland 的 display 号/xauth 由 kwin 挑，只能事后读；plasmashell 的 DISPLAY 是
    # 启动时定死的，kwin 换过 Xwayland 后要让它生效必须连带重启 plasmashell
    # （desk-takeover.sh 第 3a/4 节就是这么串的）。这里只报状态不改环境。
    XP=$(pgrep -x Xwayland | head -1)
    if [ -n "$XP" ]; then
        echo "XWAYLAND pid=$XP display=$(tr '\0' '\n' < /proc/$XP/cmdline | grep -E '^:[0-9]+$' | head -1)"
    else
        echo "WARN: no Xwayland → X11-only apps broken until next desk-takeover"
    fi
    grep -iE "input|libinput|touch" $LOGD/kwin.log | tail -8
else
    echo "KWIN-RESTART FAILED; kwin.log tail:"; tail -15 $LOGD/kwin.log
fi
