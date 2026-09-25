#!/bin/bash
# desk-takeover.sh — 全自动无网接力：stop 安卓 → kwin DRM 持屏 + Plasma 桌面 → 容器接管 WiFi。
# 顺序按用户要求：先桌面，再网络。全程不需要我在线（adb 走本机 emulator-5554 通道）。
# 任一关键步失败 → 自动回滚（恢复安卓全家，含 system_suspend 显式拉起，防 Scout 重启）。
ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DIR=$ROOT
LOGD=${LOG_DIR:-$(dirname "$ROOT")/logs}
mkdir -p "$LOGD"

# ---- 自脱钩（09-23 黑屏事故教训，同 desk-stop v2）：快捷方式从桌面 konsole 进来时，
#      konsole 是将被本脚本杀掉的 kwin 的客户端；kwin 一死 pty 关闭，前台脚本陪葬，
#      而此时安卓已 stop → 两头全黑。主体必须 setsid 脱离终端。 ----
if [ -z "$DESKSTART_ID" ]; then
    DESKSTART_ID="$$.start"
    export DESKSTART_ID
    setsid nohup "$0" >>"$LOGD/desk-takeover.log" 2>&1 </dev/null &
    CHILD=$!
    tail -n 60 --pid=$CHILD -f "$LOGD/desk-takeover.log" 2>/dev/null
    exit 0
fi
trap '' HUP INT TERM

exec >>"$LOGD/desk-takeover.log" 2>&1
set -x
echo "=== DESK-TAKEOVER START $(date +%F_%T) ==="

WIFI_CONF=/root/desk-wifi.conf
# 仅兜底；正常路径 dhcpcd 拿租约后动态探测 GW/网段（换网不用改这里）
IP=172.16.30.104
PREFIX=22
GW=172.16.30.1

DEV=$(adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "NO-ADB-DEVICE"; exit 1; }
run() {
    # 同 desk-stop：安卓侧 adb 调用一律限时，卡死=黑屏（09-24 16:52 轮实测 wake_unlock
    # 那一次 adb 调用永久阻塞，把回还流程钉死在半路）。超时必须进日志。
    local out rc
    out=$(timeout 12 adb -s "$DEV" shell "su -c '$1'" 2>&1); rc=$?
    [ $rc -eq 124 ] && echo "RUN-TIMEOUT(12s): $1"
    printf '%s\n' "$out"
    return $rc
}
kill_linux_stack() {
    # v2: 补全实际 cmdline 模式(v1 的 kwinwrap/socket 模式杀不掉真 kwin)，见 desk-stop.sh 头注
    pkill -9 -f "kwinwrap --out" 2>/dev/null
    pkill -9 -f "socket=taketest" 2>/dev/null
    pkill -9 -f "kwin_wayland_wrapper" 2>/dev/null
    pkill -9 -f "kwin_wayland --" 2>/dev/null
    # Xwayland 是 kwin 的子进程，kwin 被 -9 时不一定跟退；残留会占住 display 号，
    # 让下一轮 kwin --xwayland 挑到别的号或起不来（09-24 接入 XWayland 时同步加）
    pkill -9 -x Xwayland 2>/dev/null
    # Xwayland 是 kwin 的子进程；kwin 被 -9 时它不一定跟着退，残留会占着 /tmp/.X11-unix
    # 的 display 号，让下一轮 kwin --xwayland 挑到别的号或直接失败
    pkill -9 -x Xwayland 2>/dev/null
    # 会话里注入的是写死的 DISPLAY=:0，所以必须保证 :0 真的空出来：anland 遗留的
    # /tmp/.X11-unix/X0 是**没人 listen 的死 socket**，Xwayland bind 它会 EADDRINUSE
    # 而退到 :1，那样注入的 :0 就成了错的。上面已经 Xwayland 全杀，这里的 socket 文件
    # 一律是垃圾（整个容器里只有 anland/DRM 两套 kwin 会造 X socket）。
    rm -f /tmp/.X11-unix/X* /tmp/.X11-lock /tmp/.X*-lock 2>/dev/null
    pkill -9 -f "startplasma-wayland" 2>/dev/null
    pkill -9 -f "plasmashell" 2>/dev/null
    pkill -9 -f "kactivitymanagerd" 2>/dev/null
    pkill -9 -f "org_kde_powerdevil" 2>/dev/null
    pkill -9 -f "plasma-keyboard" 2>/dev/null
    pkill -x fcitx5 2>/dev/null
    pkill -x onboard 2>/dev/null
    pkill -9 -f "dmesg-harvester.sh" 2>/dev/null
    pkill -f 'wpa_supplicant.*desk-wifi' 2>/dev/null
    pkill -f "nm-drm.conf" 2>/dev/null
    pkill -x NetworkManager 2>/dev/null
    systemctl stop wpa_supplicant.service 2>/dev/null   # 清掉 systemd 侧的 supplicant
    pkill -x wpa_supplicant 2>/dev/null   # 09-24 起 supplicant 改为自拉 nohup 版，systemctl stop 管不到它
    pkill -x dhcpcd 2>/dev/null
    pkill -f "xdg-desktop-portal" 2>/dev/null
    sleep 1
    fuser -k /dev/dri/card0 2>/dev/null
    rm -f $DIR/takeover.ok
}
rollback() {
    echo "ROLLBACK: $* ($(date +%T))"
    kill_linux_stack
    # system_suspend 被 ctl.stop 后 `start` 拉不起它，新 system_server 会在
    # PowerManagerService.<init> waitForService(android.system.suspend) 卡死
    # → MIUIScout FW_SCOUT_HANG → 自动重启。必须先显式 ctl.start。
    run "echo qoderdbg > /sys/power/wake_unlock; setprop ctl.start system_suspend; setprop ctl.start vendor.qti.hardware.display.composer; start"
    sleep 6
    run "setprop ctl.stop bootanim; sleep 2; setprop ctl.stop bootanim"
    $DIR/bin/setbright 2048 >/dev/null 2>&1
    adb -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
    exit 1
}

# ---- 0) 预检+自动生成网络配置：从安卓现读当前连接的 SSID/PSK（换网零改动），
#         /root/desk-wifi.conf 仅作兜底；都没有也放行——网络尽力而为，桌面优先 ----
WIFI_GEN=/run/desk-wifi-dyn.conf
CUR_SSID=$(adb -s "$DEV" shell "cmd wifi status" 2>/dev/null | sed -n 's/.*connected to "\(.*\)".*/\1/p' | tr -d '\r')
# xtrace 会把 CUR_PSK 的赋值行和后面 nmcli connect 展开后的命令行原样写进
# logs/desk-takeover.log（09-24 12:21 轮实锤：password 明文在档）→ PSK 读写段静音
set +x
CUR_PSK=$(adb -s "$DEV" shell "su -c 'grep -A2 \"&quot;$CUR_SSID&quot;<\" /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml'" 2>/dev/null | sed -n 's/.*<string name="PreSharedKey">&quot;\(.*\)&quot;<.*/\1/p' | tr -d '\r' | head -1)
if [ -n "$CUR_SSID" ] && [ -n "$CUR_PSK" ]; then
    printf 'ctrl_interface=/run/wpa-takeover\nupdate_config=0\nap_scan=1\npmf=1\nsae_pwe=2\n' > "$WIFI_GEN"
    printf '%s' "$CUR_PSK" | wpa_passphrase "$CUR_SSID" >> "$WIFI_GEN"
    WIFI_CONF=$WIFI_GEN
    echo "WIFI-GEN OK for SSID[$CUR_SSID]"
else
    rm -f "$WIFI_GEN"   # 防上一轮遗留的过期配置被误用
    [ -f "$WIFI_CONF" ] && echo "WIFI-GEN miss(ssid=[$CUR_SSID]), fallback to static conf" \
        || echo "WIFI-GEN miss and no static conf: desktop will run WITHOUT network"
fi
set -x

# ---- 1) DRM 节点 + udev 合成记录（与 drm-takeover.sh 同源） ----
mkdir -p /dev/dri /dev/input
[ -c /dev/dri/card0 ] || mknod /dev/dri/card0 c 226 0
# NM 靠 rfkill netlink 控制 WiFi 射频；容器重启后 /dev 重建，缺这节点=扫不到任何热点（09-23 实锤）
[ -c /dev/rfkill ] || mknod /dev/rfkill c 10 242
chmod 666 /dev/rfkill 2>/dev/null
# pc-keyd（PC 布局组合键守护）的 uinput 注入要这个节点（内核 CONFIG_INPUT_UINPUT=y，只差节点）
[ -c /dev/uinput ] || mknod /dev/uinput c 10 223
chmod 666 /dev/uinput 2>/dev/null
# pc-keyd（组合键守护）必须在 kwin 之前在场。只从本脚本 nohup 起（防开机
# crash-loop 触发内核 uinput 防滥用；daemon 源码已独立成仓 droid-pc-keyboard，
# 装在 /usr/local/bin/pc-keyd.py。详见 https://github.com/Yizhou147/droid-pc-keyboard）。
pgrep -f "pc-keyd.py" >/dev/null || nohup python3 /usr/local/bin/pc-keyd.py > /tmp/pc-keyd.log 2>&1 &
# power-state-sync：小米 BSP 电流符号与内核 ABI 相反 → upower 永远判放电。
# bind-mount 取反 current_now + 周期 kick（脚本自带幂等挂载判断；跨会话常驻，
# desk-stop 不杀它，anland 托盘顺带受益）。
[ -f /usr/local/bin/power-state-sync.py ] && { pgrep -f "power-state-sync" >/dev/null || nohup python3 /usr/local/bin/power-state-sync.py > /tmp/power-sync.log 2>&1 & }
chmod 666 /dev/dri/card0 2>/dev/null
[ -c /dev/input/event11 ] || mknod /dev/input/event11 c 13 75
# BLE 外设（鼠标/键盘/手柄）走 BlueZ HOGP→内核 uhid 才会长出 /dev/input/eventN；
# 安卓侧有 /dev/uhid(10:239, CONFIG_UHID=y)，但容器这份 /dev 没有节点 ⇒ 设置里"连上了"
# 却完全没有指针（09-25 实测）。
[ -c /dev/uhid ] || mknod /dev/uhid c 10 239
chmod 666 /dev/uhid 2>/dev/null
chmod 666 /dev/input/event11 2>/dev/null
if [ ! -f /run/udev/data/c226:0 ] || ! grep -q DRIVER /run/udev/data/c226:0; then
    mkdir -p /run/udev/data
    printf 'Q:100\nE:DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/card0\nE:MAJOR=226\nE:MINOR=0\nE:SUBSYSTEM=drm\nE:DEVTYPE=drm_minor\nE:DEVNAME=dri/card0\nE:DRIVER=vmwgfx\nH:uaccess\nH:seat\n' > /run/udev/data/c226:0
    printf 'Q:101\nE:DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/renderD128\nE:MAJOR=226\nE:MINOR=128\nE:SUBSYSTEM=drm\nE:DEVTYPE=drm_minor\nE:DEVNAME=dri/renderD128\nE:DRIVER=vmwgfx\nH:uaccess\nH:seat\n' > /run/udev/data/c226:128
    printf 'Q:100\nE:DEVPATH=/devices/virtual/input/input11\nE:MAJOR=13\nE:MINOR=75\nE:SUBSYSTEM=input\nE:DEVNAME=input/event11\nE:ID_INPUT=1\nE:ID_INPUT_TOUCH=1\nE:ID_INPUT_TOUCHSCREEN=1\nE:LIBINPUT_DEVICE_GROUP=11/6/15d9:NVTCapacitiveTouchScreen\nE:LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1 0 0 1\nH:uaccess\nH:seat\n' > /run/udev/data/c13:75
    chmod -R a+rX /run/udev
fi

# ---- 2) 悬停保护 + 放倒安卓框架（网会掉 ~10-40s，属预期） ----
run "setprop ctl.stop system_suspend"
run "echo qoderdbg > /sys/power/wake_lock"
# 这里**不放** `svc bluetooth enable`（09-24 加了又撤）：实测两台次都在"enable→几秒后 stop"
# 之后 2–3 分钟内整机挂死、console 静默 ~86s 后看门狗复位（mtdoops reason=7），
# 机制上讲得通：enable 会拉起 com.android.bluetooth + btpower/cnss 的上电序列，
# 序列没走完就把 framework `stop` 掉 = 把协调者打断在半程（正是红线那类 combo 芯片事故）。
# 而且根本不需要它：本机开机安卓自己就把蓝牙开着（用户实测"重启后自动开，我无法控制"），
# 桥在冷 HAL 上（fd=0）自己 initialize 就能把传输开起来（09-24 23:05 实测）。
run "stop"
# stop 不动 class hal！composer HAL 活着就还持有 DRM master（SET_MASTER EBUSY），
# kwin 拿不到屏 → 黑屏（09-21 的坑，drm-takeover 同款处理）
run "setprop ctl.stop vendor.qti.hardware.display.composer"
sleep 5

# ---- IM：plasma-keyboard 本体路线（09-23 定案）----
# Qt 应用必须走 kwin 合成器 text-input 才会触发 kwin 自拉 plasma-keyboard，
# 所以本会话剥离 QT_IM_MODULE（/etc/environment 保持干净是给 anland 用的）；
# 中文=官方 Qt VirtualKeyboard Pinyin 插件（droid-pc-keyboard 仓库 scripts/install-pinyin-plugin.sh 一次性装入），
# 布局列表写 plasmakeyboardrc.enabledLocales。
sed -i 's/^\(enabledLocales=\).*/\1en_US,zh_CN/' /home/xieyizhou/.config/plasmakeyboardrc 2>/dev/null \
    || printf '[General]\nenabledLocales=en_US,zh_CN\n' > /home/xieyizhou/.config/plasmakeyboardrc
chown xieyizhou:xieyizhou /home/xieyizhou/.config/plasmakeyboardrc 2>/dev/null
grep -q "^VirtualKeyboardEnabled=true" /home/xieyizhou/.config/kwinrc 2>/dev/null \
    && : || sed -i 's/^VirtualKeyboardEnabled=.*/VirtualKeyboardEnabled=true/' /home/xieyizhou/.config/kwinrc

# ---- 3) kwin 接管显示（SF 已随 stop 死亡，master 天然空闲）→ 先出桌面 ----
kill_linux_stack
rm -f $DIR/takeover.ok
env KWINWRAP_HIJACK=1 KWINWRAP_FILTER=1 KWINWRAP_SECCOMP=1 \
    KWINWRAP_UID=1000 KWINWRAP_GID=1000 KWINWRAP_BRIGHTNESS=2048 \
    $DIR/bin/kwinwrap --out $LOGD/kwinatomic.log -- \
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
sleep 6
kill -0 $KPID 2>/dev/null || rollback "kwin died (see kwin.log)"
runuser -u xieyizhou -- env -u DISPLAY WAYLAND_DISPLAY=taketest \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    QT_QPA_PLATFORM=wayland \
    timeout 5 wayland-info > $LOGD/wayland-info.log 2>&1
[ $? = 0 ] || rollback "wayland-info self-check failed"
# ---- 3a) XWayland（09-24：DRM 桌面缺它，X11-only 应用全打不开——星火商店/ZCode 是
#      Electron 默认 x11 ozone，报 "Missing X server or $DISPLAY"；usb-manager 的 PyQt5
#      源码里硬把 QT_QPA_PLATFORM=wayland 改写成 xcb，连退路都没有）。
#      这里**不 poll 等 Xwayland 出现**：实测 KWin 6 起 Xwayland 的时机晚于 plasmashell
#      （23:17:42 plasmashell → 23:17:44 Xwayland），起完 kwin 等 10s 只拿得到空，
#      注入永远是缺省的。改成直接把 :0 写进会话环境（kill_linux_stack 已清掉遗留死
#      socket，:0 可预期），真实结果由 DESKTOP-UP 之后的 XWAYLAND-OK/MISMATCH 后台核对。
#      XAUTHORITY 不注入：kwin 起 Xwayland 不带 -auth，实测本地连接不需要 cookie。
XWARGS=("DISPLAY=:0")
# ---- 3b) 上屏取证 + 强制点亮：stop 时 system_server 死前会走关机流程把屏灭掉，
#      kwin 新 commit 不一定把 connector DPMS 拉回 On → 黑屏。主动写 dpms=0。 ----
$DIR/bin/crtcstate > $LOGD/crtcstate-desk.log 2>&1
$DIR/bin/connprops > $LOGD/connprops-desk.log 2>&1
$DIR/bin/setprop 0 DPMS
$DIR/bin/setbright 2048 > /dev/null 2>&1
sleep 2
$DIR/bin/crtcstate > $LOGD/crtcstate-desk2.log 2>&1

# ---- 4) Plasma 桌面 ----
# 09-23 黑屏根因：plasmashell 硬依赖 kactivitymanagerd，总线自动激活今天直接超时
# （"Aborting shell load: The activity manager daemon is not running" → 无壳黑屏）。
# 不再赌 dbus 激活：显式拉起并等名字出现。
nohup runuser -u xieyizhou -- env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE -u XMODIFIERS \
    QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=taketest \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    /usr/lib/aarch64-linux-gnu/libexec/kactivitymanagerd > $LOGD/kactivitymanagerd.log 2>&1 &
for i in $(seq 1 10); do
    runuser -u xieyizhou -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.ListNames 2>/dev/null | grep -q org.kde.ActivityManager && break
    sleep 1
done
runuser -u xieyizhou -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.ListNames 2>/dev/null | grep -q org.kde.ActivityManager \
    || echo "WARN: kactivitymanagerd not on bus, plasmashell may abort (see kactivitymanagerd.log)"
nohup runuser -u xieyizhou -- env -u QT_IM_MODULE -u GTK_IM_MODULE \
    -u SDL_IM_MODULE -u GLFW_IM_MODULE -u XMODIFIERS "${XWARGS[@]}" \
    WAYLAND_DISPLAY=taketest \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    QT_QPA_PLATFORM=wayland \
    /usr/bin/plasmashell --replace > $LOGD/plasma.log 2>&1 &
# plasmashell 起没起必须亲眼看到（09-24 黑屏事故的直接教训：`env` 参数顺序写错
# → plasmashell 压根没启动，而收尾那行照旧写 "plasma up"，连着三轮黑屏白猜）。
PSHELL=""
for i in 1 2 3 4 5 6 7 8; do
    PSHELL=$(pgrep -x plasmashell | head -1)
    [ -n "$PSHELL" ] && break
    sleep 1
done
if [ -n "$PSHELL" ]; then
    echo "PLASMA-UP pid=$PSHELL $(date +%T)"
else
    echo "PLASMA-FAIL $(date +%T): plasmashell 没起来 = 无壳黑屏，plasma.log 尾部："
    tail -n 5 $LOGD/plasma.log 2>&1
fi
# ---- 托盘亮度/电池（09-24 三根因定修）----
# 1) 容器 /sys 挂成 ro → backlighthelper 写亮度 EROFS；remount rw 解决
# 2) 无 logind active session → polkit 默认拒 org.kde.powerdevil.backlighthelper.*
# 3) DRM 会话不走 startplasma，powerdevil 守护根本没人拉
mount -o remount,rw /sys 2>/dev/null || echo "WARN: /sys remount failed, brightness slider will be read-only"
cat > /etc/polkit-1/rules.d/61-powerdevil-backlight.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.kde.powerdevil.backlighthelper.") === 0 &&
        subject.user === "xieyizhou") {
        return polkit.Result.YES;
    }
});
EOF
# 09-24 假设：同轮两处 try-restart polkit 恰好撞在 NM 启动的 polkit 权限查询窗口上
# → 10:47 轮 NM 主循环冻结。这里改成唯一一次 restart，并等 polkit 真正 active 再继续。
systemctl restart polkit 2>/dev/null
for i in $(seq 1 10); do systemctl is-active polkit >/dev/null 2>&1 && break; sleep 0.5; done
PDEV=$(ls /usr/lib/*/libexec/org_kde_powerdevil 2>/dev/null | head -1)
[ -n "$PDEV" ] && nohup runuser -u xieyizhou -- env -u DISPLAY -u QT_IM_MODULE \
    WAYLAND_DISPLAY=taketest \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    QT_QPA_PLATFORM=wayland \
    "$PDEV" > $LOGD/powerdevil.log 2>&1 &
# 任务栏点击启动应用走 xdg-desktop-portal；不带 KDE 环境起来的话只有 gtk 后端
nohup runuser -u xieyizhou -- env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE \
    -u SDL_IM_MODULE -u GLFW_IM_MODULE -u XMODIFIERS \
    WAYLAND_DISPLAY=taketest XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    QT_QPA_PLATFORM=wayland \
    /usr/libexec/xdg-desktop-portal > $LOGD/portal.log 2>&1 &
touch $DIR/takeover.ok
$DIR/bin/setbright 2048 > /dev/null 2>&1
echo "DESKTOP-UP $(date +%T) kwin pid $KPID"
# ---- 4a) XWayland 事后核对（异步，不阻塞桌面）：确认 kwin 真把 Xwayland 起在 :0，
#      也就是会话里注入的 DISPLAY 是对的。它比 plasmashell 晚 ~2s，但 kwin 起不来的
#      情况也得报出来，所以给 90s 窗口。
(
    for i in $(seq 1 90); do
        XP=$(pgrep -x Xwayland | head -1)
        [ -n "$XP" ] && break
        sleep 1
    done
    if [ -z "$XP" ]; then
        echo "XWAYLAND-ABSENT $(date +%T): kwin 没起 Xwayland，X11-only 应用仍打不开（看 kwin.log）"
    else
        XD=$(tr '\0' '\n' < /proc/$XP/cmdline 2>/dev/null | grep -E '^:[0-9]+$' | head -1)
        if [ "$XD" = ":0" ]; then
            echo "XWAYLAND-OK display=$XD pid=$XP $(date +%T)"
        else
            echo "XWAYLAND-MISMATCH display=$XD 但会话注入的是 :0 → 应用连不上，检查 /tmp/.X11-unix 残留"
        fi
    fi
) >> $LOGD/desk-takeover.log 2>&1 &

    # ---- 5) 容器接管 WiFi：NetworkManager 模式（DRM 桌面设置里可直接点热点、密码持久化） ----
    # 备份安卓策略路由后再动 rule——netd 已死没人管；desk-stop 会原样还原再 start。
    # 09-24 下午两连实锤：①`ip rule save` 是 iproute2 二进制格式，desk-stop 的
    # `ip rule restore` 原样回放 → save 时若带脏 pref0，每轮都被 bak 带病重启；
    # ②12:20 轮 dedup 到 1 后，轮内又漂回 2 条 pref0（无任何脚本再碰 rule）→
    # 备份前先收敛到只剩一条，从源头保证 bak 干净。
    while [ "$(ip -o rule show | grep -c '^0:')" -gt 1 ]; do
        ip rule del pref 0 table local 2>/dev/null || break
    done
    ip rule save > /run/desk-ip-rules.bak 2>/dev/null
    pkill -9 -f 'wpa_supplicant.*desk-wifi' 2>/dev/null
    pkill -x dhcpcd 2>/dev/null
    if command -v NetworkManager >/dev/null 2>&1; then
        ip link set wlan0 down; sleep 1; ip link set wlan0 up
        # 安卓把 main 表摘了、全塞 fwmark→1015，NM 的 DHCP 不吃这套 → 恢复内核标准三表
        ip rule flush
        ip rule add pref 0 table local        2>/dev/null
        ip rule add pref 100 table main       2>/dev/null
        ip rule add pref 32766 table default  2>/dev/null
        # 09-24 实锤：ip rule 曾堆到 24600 条（pref0 local 重复 24576 次），NM 启动的
        # 同步 link/rule dump 一次要 13s+。flush 在本内核不保证删净 pref0（实测会
        # 残留），逐条删到只剩一条（batch 版删除实测有效，这里单条循环更直白）。
        N0=$(ip -o rule show | grep -c '^0:')
        if [ "$N0" -gt 1 ]; then
            for d in $(seq 2 $N0); do ip rule del pref 0 table local 2>/dev/null || break; done
            echo "IPRULE-DEDUP removed=$(( N0 - $(ip -o rule show | grep -c '^0:') )) $(date +%T)"
        fi
        N0=$(ip -o rule show | grep -c '^0:')
        [ "$N0" -ne 1 ] && echo "IPRULE-ANOMALY pref0=$N0 $(date +%T)"
        # 09-24 12:4x：轮内出现"dedup 后无人操作却多回一条 pref0"的漂移，加一个只读
        # netlink 监听抓 re-adder 的现行（不碰 wlan0 流量）。只保留最近一轮的监听。
        pkill -f 'ip monitor rule' 2>/dev/null
        nohup ip monitor rule > $LOGD/ip-rule-monitor.log 2>&1 &
        ip -4 addr flush dev wlan0 2>/dev/null
    cat > /run/nm-drm.conf <<'EOF'
[main]
plugins=keyfile
[connectivity]
uri=
[keyfile]
# 回归根因补充实锤（09-24 下午读源码）：c27b36f 写的是 except:type=wifi;... ——
# 标签必须是 'type:'，'type=' 不是合法标签，该 except 谓词对任何设备都恒不命中，
# "除了 wifi 都 unmanaged" 的语义整个失效 → wlan0 每轮被判 unmanaged（回归轮的
# nmcli STATE=unmanaged 为证）。这里回到 09-23 上午实测可连的写法。
unmanaged-devices=except:type:wifi
# p2p0 排除为什么不能写进本行（nm-core-utils.c nm_match_spec_split/nm_match_spec_device）：
# ',' 与 ';' 完全同权、一律 OR；任一 except 命中即 NEG_MATCH（托管优先）——这套
# 语法根本表达不了"wifi 里再排除 p2p0"的 AND 取反。[device-*] 段也没有 managed 键
# （只存在于 /run/NetworkManager/devices/<ifindex> run-state，817eb6f 加的段实测零生效）。
# → p2p0 改走运行时 `nmcli dev set p2p0 managed no`（见 NM 启动等待段）。
[logging]
# 09-24 10:39 轮实锤：命令行 --log-level=DEBUG 在这套容器 journal 后端上完全无效
# （journal 里 debug 行数=0，NM 也没打 "Logging:" 自述行）→ 走官方 conf 路径。
# domains 必须显式带 DEFAULT:INFO，否则是白名单把整域静音（10:22 轮踩过）。
level=DEBUG
domains=DEFAULT:INFO,SUPPLICANT:DEBUG,DEVICE:DEBUG,WIFI:DEBUG,RFKILL:DEBUG,DBUS_PROPS:DEBUG
EOF
    mkdir -p /run/NetworkManager
    # NM 靠 D-Bus 激活 wpa_supplicant.service 拉起扫描/认证进程——它可以 disabled 但绝不能 masked
    systemctl unmask wpa_supplicant.service 2>/dev/null
    # plasma-nm 点击连接会被 polkit 拒（"Not authorized to control networking"，
    # 容器里无 logind active 会话）→ 给本用户放行 NM 动作（仅本机 DRM 场景）
    mkdir -p /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/60-nm-drm.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager") === 0 && subject.user === "xieyizhou")
        return polkit.Result.YES;
});
EOF
    # （原本这里还有第二处 try-restart polkit，已删——见托盘段的说明）
    # 09-24 断网根因：昨晚 35a8bff 给 udevd 加的 ExecCondition(enable_hw_access) drop-in
    # 在今天 09:41 重启后条件不满足（container.config 里=0）→ udevd 永久 skipped。
    # NM platform 以 "use udev" 建 link 缓存：拿不到 udev 设备对象 → 所有 link 永远
    # not-init → startup complete 卡在 'lo (link-init)' → 全设备 unmanaged（WiFi 永远转圈）。
    # 起 NM 前保证 udevd 活着并做 net 冷插拔；systemd 拉不动就直接手动起。
    # 09-24 16:25 实锤（回安卓后 WiFi 永久失效、只能整机重启，两次）：udevd + 下面那行
    # `udevadm trigger --action=add --subsystem-match=net` 会用 80-net-setup-link 的
    # 可预测命名把共享 netns 里的 wlan0 改名成 wlp1s0
    # （安卓 dmesg: "cnss_pci 0000:01:00.0 wlp1s0: renamed from wlan0 (while UP)"），
    # 而安卓 WiFi 状态机硬编码只认 wlan0 → logcat "WifiActiveModeWarden: One of the
    # native daemons died. Triggering recovery" + "MiuiWifiService: This interface
    # cannot be used" 无限循环，设置里开关点了没反应。容器改名对安卓是永久的（安卓不会
    # 自己改回来），所以只有重启才好。处置：把命名规则掩掉（只动容器 rootfs 的 /etc，
    # 不碰安卓），udevd 照常活着供 NM 用。
    ln -sf /dev/null /etc/udev/rules.d/80-net-setup-link.rules
    systemctl reset-failed systemd-udevd.service 2>/dev/null
    systemctl start systemd-udevd.service 2>/dev/null
    if ! pgrep -x systemd-udevd >/dev/null; then
        nohup /usr/lib/systemd/systemd-udevd >/dev/null 2>&1 &
        sleep 1
    fi
    udevadm trigger --action=add --subsystem-match=net 2>/dev/null
    udevadm settle --timeout=5 2>/dev/null
    echo "UDEVD_PID=$(pgrep -x systemd-udevd | head -1) NETRULES=$(ls /run/udev/data 2>/dev/null | grep -c '^n') $(date +%T)"
    # 09-24 实锤：kill 段的 `systemctl stop wpa_supplicant` 之后，NM 1.54 有时整个会话
    # 都不发起 fi.w1.wpa_supplicant1 的 D-Bus 激活（journal 零激活请求，wlan0 永久
    # unavailable，桌面里搜不到任何热点）。不再赌它的懒激活：起 NM 前先把 supplicant 拉活。
    # 10:47 轮教训：systemd 管的 supplicant（Type=dbus + Group=netdev 降权）进程不可
    # dumpable，strace attach 一律 EPERM，wpa 侧连续两轮 0 字节=盲区。改为自拉 nohup
    # 版（同 root，可 attach），-t 时间戳日志落文件。
    systemctl stop wpa_supplicant.service 2>/dev/null
    pkill -x wpa_supplicant 2>/dev/null
    sleep 1
    mkdir -p /run/wpa_supplicant
    nohup /usr/sbin/wpa_supplicant -u -t -O "DIR=/run/wpa_supplicant GROUP=netdev" \
        > $LOGD/wpa-drm.log 2>&1 &
    echo $! > /run/desk-wpa.pid   # desk-stop 按 PID 精确杀（cmdline 无 desk-wifi，模式杀不到）
    echo "WPA_PID=$! $(date +%T)"
    sleep 1
    # 09-24 10:22 轮教训：--log-domains 是白名单；10:39 轮教训：--log-level 命令行无效
    # → 日志级别全部走 /run/nm-drm.conf 的 [logging] 段。
    nohup NetworkManager --config /run/nm-drm.conf --no-daemon \
        > $LOGD/nm-drm.log 2>&1 &
    NMPID=$!
    echo "NM_PID=$NMPID $(date +%T)"
    # 同轮双 strace：wpa 侧 10:39 轮抓到的量=0（=NM 压根没对 supplicant 发过 dbus 调用，
    # 这是重要负证据）→ 这轮从 NM 侧看它到底发了什么/为什么不发。
    WPAPID=$(pgrep -x wpa_supplicant | head -1)
    [ -n "$WPAPID" ] && nohup strace -f -tt -s 400 -e trace=network -p "$WPAPID" \
        -o $LOGD/wpa-strace.txt >/dev/null 2>&1 &
    nohup strace -f -tt -s 400 -e trace=network -p "$NMPID" \
        -o $LOGD/nm-strace.txt >/dev/null 2>&1 &
    for i in $(seq 1 15); do nmcli status >/dev/null 2>&1 && break; sleep 1; done
    nmcli radio wifi on 2>/dev/null   # 清掉可能的软阻塞（上一轮残留状态）
    # p2p0（Wi-Fi Direct 虚拟口）配置语法排除不了（见 /run/nm-drm.conf 注释）→
    # 走 run-state。它由 supplicant P2P 初始化时慢建，NM 重启也会重置该标记，
    # 所以后台带重试收敛，不阻塞主流程。
    (
        for i in $(seq 1 20); do
            sleep 3
            nmcli dev set p2p0 managed no 2>/dev/null && break
        done
    ) &
    # 首轮引导：NM 刚起扫描缓存是空的，先 rescan 再带重试连接；
    # 成功即自动落 keyfile(0600)，以后自连、plasma-nm 面板可改
    if [ -n "$CUR_SSID" ] && [ -n "$CUR_PSK" ]; then
        (
            # 子 shell 继承 xtrace，nmcli connect 展开后的 password 会进日志（09-24 泄漏实锤）
            set +x
            for t in 1 2 3 4 5; do
                sleep 3
                # 09-24 12:21 轮：连上后循环仍又跑了几次（profile 名匹配不总是及时）→
                # 直接以 wlan0 状态收口，防重入 rescan/connect 抖动已建好的链路
                LC_ALL=C nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -q '^wlan0:connected' && break
                nmcli -g NAME connection list 2>/dev/null | grep -qxF "$CUR_SSID" && break
                nmcli device wifi rescan 2>/dev/null
                nmcli device wifi connect "$CUR_SSID" password "$CUR_PSK" >> $LOGD/nm-drm.log 2>&1 && break
            done
        ) &
    fi
    OK=0
    # 旧检查 `nmcli device status wlan0` 是非法语法（status 不接受设备名参数），
    # 永远返回空 → 每轮都误报 NET-FAILED（09-23 晚其实已连上并拿到 DHCP，lease 为证）。
    # LC_ALL=C 钉死英文，防中文 locale 把 "connected" 翻成 "已连接" 再次错过匹配。
    for i in $(seq 1 60); do
        [ "$(LC_ALL=C nmcli -t -f DEVICE,STATE device 2>/dev/null | grep '^wlan0:' | cut -d: -f2)" = "connected" ] && { OK=1; break; }
        sleep 1
    done
    if [ "$OK" = 1 ]; then
        echo "WIFI-ASSOC OK (NM) $(date +%T)"
        NET=0
        for i in 1 2 3; do
            ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && { NET=1; break; }
            sleep 2
        done
        if [ "$NET" = 1 ]; then
            echo "NET-TAKEOVER OK (NM) $(date +%T)"
        else
            echo "--- egress diagnosis (NM) ---"
            ip route show; nmcli device show wlan0 | head -20
            echo "NET-EGRESS-FAIL (NM) $(date +%T): desktop kept"
        fi
    else
        echo "--- NM diagnosis ---"
        # 10:39 轮：REASON 不是本版本 device 表的合法字段。StateReason 走 D-Bus 属性。
        LC_ALL=C nmcli -t -f DEVICE,TYPE,STATE device 2>&1 | grep -vE '^(lo|dummy|p2p)' | head -8
        WP=$(nmcli -t -f DEVICE,DBUS-PATH device 2>/dev/null | awk -F: '/^wlan0:/{print $2}')
        echo "wlan0 dbus path: $WP"
        busctl get-property org.freedesktop.NetworkManager "$WP" org.freedesktop.NetworkManager.Device StateReason 2>&1
        busctl introspect org.freedesktop.NetworkManager "$WP" 2>/dev/null | grep -cE "Wireless|Supplicant" 
        gdbus call --system --dest fi.w1.wpa_supplicant1 --object-path /fi/w1/wpa_supplicant1 --method org.freedesktop.DBus.Properties.Get fi.w1.wpa_supplicant1 Interfaces 2>&1 | head -c 300; echo " <-supplicant Interfaces"
        echo "--- polkit health (重启等待是否生效、NM 权限查询通不通) ---"
        systemctl is-active polkit 2>&1
        timeout 5 nmcli general permissions 2>&1 | head -6
        tail -n 20 $LOGD/wpa-drm.log 2>/dev/null
        tail -n 60 $LOGD/nm-drm.log
        echo "NET-FAILED (NM) $(date +%T): desktop kept, NO network"
    fi
else
# ---- 5L) legacy 手管段（NM 未安装时的 fallback，原 wpa+dhcpcd+表1015 方案） ----
if [ -f "$WIFI_GEN" ] || [ -f "$WIFI_CONF" ]; then
[ -f "$WIFI_GEN" ] && WIFI_CONF="$WIFI_GEN"
pkill -f 'wpa_supplicant.*desk-wifi' 2>/dev/null
pkill -x dhcpcd 2>/dev/null
sleep 1
ip link set wlan0 down; sleep 1; ip link set wlan0 up
mkdir -p /run/wpa-takeover
/usr/sbin/wpa_supplicant -i wlan0 -c "$WIFI_CONF" -P /run/wpa-takeover.pid > /run/wpa-takeover.log 2>&1 &
OK=0
for i in $(seq 1 30); do
    sleep 1
    wpa_cli -p /run/wpa-takeover -i wlan0 status 2>/dev/null | grep -q "wpa_state=COMPLETED" && { OK=1; break; }
done
if [ "$OK" != 1 ]; then
    echo "--- wpa diagnosis ---"
    wpa_cli -p /run/wpa-takeover -i wlan0 status
    tail -n 25 /run/wpa-takeover.log
    # 网络尽力而为：关联失败不连坐桌面（安卓已 stop，网络要等 desk-stop/回滚才恢复）
    pkill -f 'wpa_supplicant.*desk-wifi' 2>/dev/null
    echo "NET-FAILED $(date +%T): desktop kept, NO network (SSID/PSK 没对上？返回安卓再试)"
fi
if [ "$OK" = 1 ]; then
echo "WIFI-ASSOC OK $(date +%T), now DHCP"
# 安卓 netd 留的旧地址是 noprefixroute（main 表没直连路由，默认路由会被拒
# "Nexthop has invalid gateway"）→ 先冲干净，让 dhcpcd 完整接管；
# 兜底路由必须带 onlink 跳过网关可达性检查。
ip addr flush dev wlan0
dhcpcd -k wlan0 2>/dev/null
pkill -9 -x dhcpcd 2>/dev/null; sleep 1
dhcpcd -4 -w -t 20 wlan0 || echo "dhcpcd exited rc=$?"
sleep 1
ip -4 route show default dev wlan0 | grep -q default || ip -4 route replace default via $GW dev wlan0 onlink
# 动态取租约网段+网关（换网免改脚本）
LEASED=$(ip -4 -br addr show wlan0 | awk '{print $3}' | head -1)
DYN_GW=$(ip -4 route show default dev wlan0 | awk '{print $3; exit}')
if [ -n "$LEASED" ]; then
    NETV=$(python3 -c "import ipaddress,sys; a=ipaddress.IPv4Interface(sys.argv[1]); print(a.network)" "$LEASED" 2>/dev/null)
fi
[ -n "$DYN_GW" ] && GW="$DYN_GW"
# 安卓删掉了 "lookup main" 规则，本机所有包（含 root ping）都走
# "fwmark 0/0xffff lookup 1015"；link down/up 又清空了 1015 → main 配再好也不通。
ip -4 route replace ${NETV:-172.16.30.0/22} dev wlan0 table 1015
ip -4 route replace default via $GW dev wlan0 table 1015 onlink
ip -4 addr show dev wlan0
ip -4 route show
rm -f /etc/resolv.conf
printf 'nameserver 223.5.5.5\nnameserver 114.114.114.114\n' > /etc/resolv.conf
NET=0
for i in 1 2 3; do
    ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && { NET=1; break; }
    sleep 2
done
if [ "$NET" != 1 ]; then
    echo "--- egress diagnosis ---"
    ip route show table all | head -n 30
    cat /etc/resolv.conf
    echo "NET-EGRESS-FAIL $(date +%T): desktop kept, egress broken (路由/表1015 问题?)"
else
    echo "NET-TAKEOVER OK $(date +%T)"
fi
fi
else
    echo "NET-SKIPPED $(date +%T): 无可用 wifi 配置(安卓 SSID/PSK 没读到)，只起桌面"
fi
fi

# ---- 5c) 蓝牙：容器侧 BlueZ 直接吃安卓的蓝牙 HAL（见 droid-bluetooth-bridge 仓库）----
# 链路 09-24 实测通了：桥 initialize(oneway,码2) → HAL 自己开 ttyHS0/glink →
# 桥用 pty+N_HCI 在共享内核里注册真 hci0 并双向搬运 HCI（裸包，不带 H4 类型字节）→
# 容器 bluetoothctl 看到 Controller（UP RUNNING、真 BD_ADDR、扫到周围设备）。
# 但**默认关闭**（BT_BRIDGE=1 才开）：带桥跑的那两轮之后设备各出现一次
# "console 静默 ~86s → 看门狗复位"（mtdoops reason=7），在 A/B 排除之前不让它上默认路径。
# 交还时 desk-stop 先 pkill -x bthci-bridge：进程一退 tty 就关 → 内核自动注销 hci0。
if [ "${BT_BRIDGE:-0}" = 1 ]; then
BTBIN=/data/local/tmp/bthci-bridge
# 桥的 kickHci 是"借容器 bluetoothd 的 ns 跑 hciconfig hci0 up"，bluetoothd 不在就没内核侧 init
systemctl start bluetooth 2>/dev/null
run "test -x $BTBIN || echo BT-NO-BIN; pgrep -x bthci-bridge || nohup $BTBIN --keep 0 >>/data/local/tmp/bt-bridge.log 2>&1 &"
sleep 8
run "tail -n 2 /data/local/tmp/bt-bridge.log 2>/dev/null"
if bluetoothctl list 2>/dev/null | grep -q "^Controller"; then
    # 名字：E:Name 来自芯片自己的 Read_Local_Name（这台是主机名 Ubuntu），列表里像陌生机器；
    # BlueZ 对外广播/展示用 Alias，这里钉成稳定可认的名字（改不动 Name）。
    bluetoothctl system-alias "Piano BT" >/dev/null 2>&1
    echo "BT-NATIVE OK $(date +%T): $(bluetoothctl list | head -1)"
    echo "  配对要先让对方发现你：bluetoothctl discoverable on（默认 180s 超时，不默认开）"
else
    echo "BT-NATIVE FAIL $(date +%T): 容器里看不到 Controller（查 $BTBIN 是否活、bluetooth 服务、bt-bridge.log）"
fi
else
    echo "BT-BRIDGE SKIPPED $(date +%T)（默认关，要验蓝牙跑 BT_BRIDGE=1 的那轮）"
fi

# ---- 6) 收尾：取证收割机 + 状态 ----
# pref0 终态计数：轮内再漂移的话，$LOGD/ip-rule-monitor.log 里会留着 re-adder 现场
echo "IPRULE-FINAL pref0=$(ip -o rule show | grep -c '^0:') total=$(ip -o rule show | wc -l) $(date +%T)"
DEV=$DEV nohup bash $DIR/scripts/dmesg-harvester.sh > /dev/null 2>&1 &
adb -s "$DEV" shell "su -c 'free -m | head -2'"
if [ -z "$PSHELL" ]; then
    echo "=== DESK-TAKEOVER DONE $(date +%T): kwin pid $KPID, **PLASMA 没起来=黑屏**（见上面 PLASMA-FAIL） ==="
else
    echo "=== DESK-TAKEOVER DONE $(date +%T): kwin pid $KPID, plasmashell pid $PSHELL ==="
fi
