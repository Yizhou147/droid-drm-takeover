#!/bin/bash
# drm-stop.sh — 结束常驻接管：杀容器里的 kwin/kwinwrap，恢复 Android 显示。
# 以 root 运行（容器）。
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DIR=$ROOT
LOGD=${LOG_DIR:-$(dirname "$ROOT")/logs}
mkdir -p "$LOGD"
exec >>"$LOGD/drm-takeover.log" 2>&1
set -x
DEV=$(adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "NO-ADB-DEVICE"; exit 1; }
run() { adb -s "$DEV" shell "su -c '$1'"; }

adb -s "$DEV" shell "su -c 'dmesg'" > $LOGD/dmesg-raw.log 2>/dev/null
grep -iE 'drm|sde|atomic|propert|commit' $LOGD/dmesg-raw.log | tail -n 400 > $LOGD/dmesg.log

pkill -9 -f "kwinwrap --out" 2>/dev/null
pkill -9 -f "socket=taketest" 2>/dev/null
pkill -9 -x Xwayland 2>/dev/null   # desk-takeover 起的 kwin 带 --xwayland，它是 kwin 的子进程
pkill -9 -f "keepbright.sh" 2>/dev/null
pkill -9 -f "dmesg-harvester.sh" 2>/dev/null
sleep 1

# 一条链完成恢复（停→起全程 ≤ ~15s，喂饱 hangdetect）
# system_server 在常驻接管期间被 SIGSTOP 冻结（drm-takeover.sh PERSIST 分支），
# 必须先解冻再拉起 SF/composer，否则它的 binder 客户端全线挂住。
run "kill -CONT \$(pidof system_server)"
run "setprop ctl.start vendor.qti.hardware.display.composer; sleep 1; setprop ctl.start surfaceflinger; sleep 3; setprop ctl.stop bootanim; sleep 2; setprop ctl.stop bootanim; echo 0x0 > /sys/module/drm/parameters/debug; echo 0x20 > /sys/module/msm_drm/parameters/debugpolicy; echo 0x0 > /sys/module/msm_drm/parameters/debug_level"
# 恢复 watchdog/stability（接管期间被解除武装，见 drm-takeover.sh）
run "settings delete global watchdog_timeout; settings delete global watchdog; settings delete global stay_on_while_plugged_in; setprop persist.sys.stability.nativehang.enable true; setprop persist.sys.stability.nativehangII.enable true; setprop persist.sys.stability.qcom_hang_task.enable true"
$DIR/bin/setbright 2048 >/dev/null 2>&1
run "echo qoderdbg > /sys/power/wake_unlock; setprop ctl.start system_suspend"
adb -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
sleep 1
run "setprop ctl.stop bootanim"
adb -s "$DEV" shell "su -c 'wm dismiss-keyguard; am start -a android.settings.DISPLAY_SETTINGS'" >/dev/null 2>&1
adb -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
rm -f $DIR/takeover.ok $ROOT/takeover.ok
run "getprop init.svc.surfaceflinger; getprop init.svc.vendor.qti.hardware.display.composer"
echo "DRM-STOP DONE $(date +%T)"
