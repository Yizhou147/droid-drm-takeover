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
# 每轮的实验开关放这儿（/run 是 tmpfs，重启即回默认，不会偷偷留着上轮的实验设定）。
# 里面可以写 BT_BRIDGE=1 之类的开关，这样从桌面快捷方式进轮也能带上实验设定。
[ -f /run/drm-round.conf ] && . /run/drm-round.conf
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
# supplicant 收尾先优雅退出、超时才 -9（机制上站得住：cfg80211 的 scheduled-scan `Match`
# 只有它自己退出时才注销，被 SIGKILL 就没人清）。
# **但别把它当"第二轮 WiFi 炸"的解药** —— 历史日志里可比的是"自拉 supplicant + WIFI-ASSOC 探针
# 都存在"之后的 23 轮（16 OK / 7 失败）：7 个失败轮里 **4 个 Match 和 flags(UP) 两种签名都没有**，
# Match 只覆盖 2 轮（09-24 15:20、09-25 09:41），flags(UP) 覆盖 2 轮（09:41、10:20）。
# ⇒ 这是"少一个已知错误来源"的卫生修复，主因还没定（明细表见工作总结 5.33）。
stop_supplicant() {
    # 没进程就立刻返回：本机 `systemctl stop wpa_supplicant.service`（unit 不存在也一样）
    # 实测要 7.2s，而 kill_linux_stack / rollback 一条路径上可能进来好几次。
    pgrep -x wpa_supplicant >/dev/null || { rm -f /run/desk-wpa.pid; return 0; }
    # 自拉 nohup 版和 systemd 实例一起按名字处理；先 TERM，超时才 -9（原因见函数头注）
    pkill -TERM -x wpa_supplicant 2>/dev/null   # systemd 管的实例同样吃这个 TERM
    for i in 1 2 3 4 5 6; do
        pgrep -x wpa_supplicant >/dev/null || break
        sleep 1
    done
    if pgrep -x wpa_supplicant >/dev/null; then
        echo "WPA-STOP 优雅退出超时，补 -9（下一轮 WiFi 可能残留 Match，需 WIFI-PRECLEAR 兜）"
        pkill -9 -x wpa_supplicant 2>/dev/null
        sleep 1
    fi
    # 杀完又冒出来 = systemd 按 unit 复活了它，只有这种才付 systemctl 那 7s
    pgrep -x wpa_supplicant >/dev/null && systemctl stop wpa_supplicant.service 2>/dev/null
    rm -f /run/desk-wpa.pid
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
    pkill -f "nm-drm.conf" 2>/dev/null
    pkill -x NetworkManager 2>/dev/null
    # 原来这行是 `pkill -f 'wpa_supplicant.*desk-wifi'`：按命令行匹配既杀不到自拉的 -u 版，
    # 又会把"命令行里提到这串字"的调用方 shell 一起杀（09-25 实测 rc=143）。
    # supplicant 一律交给下面的 stop_supplicant（按名字、TERM 优先）。
    stop_supplicant   # systemd 侧 + 自拉 nohup 版都管；TERM 优先、超时才 -9（见函数注释）
    pkill -x dhcpcd 2>/dev/null
    pkill -f "xdg-desktop-portal" 2>/dev/null
    sleep 1
    fuser -k /dev/dri/card0 2>/dev/null
    rm -f $DIR/takeover.ok
}
rollback() {
    echo "ROLLBACK: $* ($(date +%T))"
    kill_linux_stack
    # 交还安卓前必须放掉蓝牙桥：桥活着 = 我们和安卓的蓝牙栈同时持有 HAL 客户端位，
    # 抢同一颗 combo 芯片的电源协调（09-25 两轮把 WiFi 打进 recovery 死循环的直接嫌疑）。
    # rollback 不走 desk-stop，所以这里也得自己杀（见工作总结 5.30）。
    run "pkill -x bthci-bridge"
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
# GPU 计算节点的兜底（**真因不在这儿**，见 5.34①：kwinwrap 切 uid 时丢了补充组，
# 已经用 initgroups 修掉；节点本来就存在，是 `crw-rw---- root:droidspaces-gpu(786)`）。
# 这里仍保留"缺则建 + chmod"，因为它兜的是另一类情况：容器重启后 /dev 是合成的，
# 节点可能压根没被 udev 建出来（card0/renderD128 都出现过这种轮）。
# chmod 是放宽，不是主修；主修在 src/kwinwrap.c 的 initgroups。
mk_dri_node() {  # $1=sysfs 类下的相对路径  $2=落地的 /dev 路径
    local d mj mn
    d="/sys/class/$1"
    [ -e "$d/dev" ] || return 1
    IFS=: read -r mj mn < "$d/dev"
    [ -n "$mj" ] && [ -n "$mn" ] || return 1
    if [ -c "$2" ]; then echo "GPU-NODE 已有 $2 = $mj:$mn"; return 0; fi
    mknod "$2" c "$mj" "$mn" 2>/dev/null || { echo "GPU-NODE mknod 失败 $2"; return 1; }
    # 只对**这里新建出来的**节点生效：mknod 出来是 0600 root:root，桌面用户（uid 1000）
    # 根本用不了 ⇒ 必须放宽，做法与 card0 那行 `chmod 666 /dev/dri/card0` 一致。
    # 注意：**已存在的节点一个字节都不碰**（上面 return 0）—— udev/ueventd 建的
    # renderD128 是 `crw-rw---- root:droidspaces-gpu(786)`，那是系统的策略，不该由轮来改。
    # 09-25 我曾给已存在的节点也 chmod 666，那是多余动作且白开权限，已去掉。
    chgrp droidspaces-gpu "$2" 2>/dev/null; chmod 660 "$2" 2>/dev/null
    echo "GPU-NODE 新建 $2 = $mj:$mn"
}
# renderD128 在 drm 类下（可能不止一个），kgsl-3d0 在 kgsl 类下
for r in /sys/class/drm/renderD*; do
    [ -e "$r/dev" ] || continue
    mk_dri_node "drm/$(basename "$r")" "/dev/dri/$(basename "$r")"
done
mk_dri_node "kgsl/kgsl-3d0" "/dev/kgsl-3d0"
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
# 触摸屏的 eventN 在**同一开机的第二轮**会被活的 udevd 冷插成别的号（09-25 实测：第二轮
# "2.4G 鼠标能用、触屏挂"）⇒ 节点号/major:minor 一律按设备名现查，不再硬编码 event11(13:75)。
find_touch() {
    local e
    for e in /sys/class/input/event*; do
        [ -e "$e/device/name" ] || continue
        grep -qi "NVTCapacitiveTouchScreen" "$e/device/name" 2>/dev/null && { printf '%s\n' "$e"; return 0; }
    done
    printf '%s\n' /sys/class/input/event11   # 兜底：sysfs 名字没读到时退回老节点
}
TS=$(find_touch)
TSNODE=$(basename "$TS")
TSMAJ=""; TSMIN=""
if [ -e "$TS/dev" ]; then
    TSMAJ=$(cut -d: -f1 "$TS/dev"); TSMIN=$(cut -d: -f2 "$TS/dev")
    [ -c "/dev/input/$TSNODE" ] || mknod "/dev/input/$TSNODE" c "$TSMAJ" "$TSMIN"
else
    # sysfs 里没有它 ⇒ 宁可不建：按老 13:75 硬建一个节点只会造成"假触摸屏"（节点名对、
    # 号段却是别的设备），libinput 打开后什么都收不到，比明着没有更难查。
    echo "TOUCH-SYSFS FAIL: $TS 无 dev ⇒ 本轮触摸屏不可用（查 NVT 驱动是否 probe）"
fi
# BLE 外设（鼠标/键盘/手柄）走 BlueZ HOGP→内核 uhid 才会长出 /dev/input/eventN；
# 安卓侧有 /dev/uhid(10:239, CONFIG_UHID=y)，但容器这份 /dev 没有节点 ⇒ 设置里"连上了"
# 却完全没有指针（09-25 实测）。
[ -c /dev/uhid ] || mknod /dev/uhid c 10 239
chmod 666 /dev/uhid 2>/dev/null
# ---- 1b) 输入热插拔：起裸 udevd（不碰单元）+ 把 net 规则冻死 ----
# 症状与已证事实（09-25）：libinput 的热插拔监听走 libudev 的 "udev" 作用域，要连
# `/run/udev/control`；那个 socket 不在 ⇒ kwin 整轮没有输入热插拔（"蓝牙鼠标连上但没指针"、
# 新插的 2.4G 鼠标也不动，而触摸屏可用因为它在 kwin 之前就有节点）。
# 实测（09-25 11:0x，anland 里）：`nohup /usr/lib/systemd/systemd-udevd` 这种裸实例**会**建
# /run/udev/control（之前我说"裸实例不建 socket"是错的，那次是单元 skipped 且没等够时间）。
# 所以热插拔不需要动单元。改名风险另有屏蔽：/etc/udev/rules.d/80-net-setup-link.rules → /dev/null，
# 其余带 NAME= 的 net 规则只匹配 idrac/ibmimm 那种 USB 网卡，碰不到 wlan0。
# （试过 `OPTIONS+="last_rule"` 冻结 net，本机 udev 直接报 Invalid value 忽略 ⇒ 无效配置，删掉。）
# 教训保留（别再犯）：用 zz-* 命名的 drop-in 清 Droid Spaces 的 ExecCondition 再
# `systemctl restart systemd-udevd` —— 那一轮 WiFi 炸 + 返回链卡死（见 5.31；
# 顺带记着 99-drm-* 会排在 99-hwaccess-* 前面、空赋值会被覆盖）。
ln -sf /dev/null /etc/udev/rules.d/80-net-setup-link.rules
# **绝不在接管轮里 restart 真 udevd 单元**（09-25 隔离实验的结论）：
#   UDEV_FORCE=0 的那轮 → WIFI-ASSOC OK / NET-TAKEOVER OK，触屏与鼠标启动前设备都在；
#   UDEV_FORCE=1 的那轮 → WiFi 炸 + 「返回安卓」卡死（只能强启）。
# 注意（用户 09-25 纠正，别再拿 anland 当对照）：**anland 走的是安卓的网络**（容器里是转发口，
# wlan0 归安卓 netd），而接管轮里是**容器的 NM 直接持有 wlan0（共享 netns）**——两场景不可比，
# 所以"anland 也有活 udevd 却没事"证明不了 udevd 无罪。
# 但 09-24 那些 WiFi 正常的好轮**本来就在跑裸 udevd**（WiFi 段的兜底），所以本轮沿用同一方式：
# socket 不存在时只起裸实例，不碰单元、不碰 ExecCondition。
if [ ! -S /run/udev/control ]; then
    pgrep -x systemd-udevd >/dev/null || { nohup /usr/lib/systemd/systemd-udevd >/dev/null 2>&1 & sleep 3; }
fi
if [ -S /run/udev/control ]; then
    echo "UDEV-HOTPLUG OK $(date +%T)（裸 udevd 在跑，未碰单元；改名规则已屏蔽）"
else
    echo "UDEV-HOTPLUG OFF $(date +%T)：裸 udevd 没建出 /run/udev/control ⇒ 本轮新插设备要重启 kwin 才认（触屏不受影响）"
fi
# 输入设备节点常驻同步器（详见 scripts/input-node-sync.sh 头注）：**必须在 kwin 之前**起，
# 因为 libinput 只在启动时枚举一次 /dev/input。
# 用 setsid+nohup：绝不能挂在我的调用链上（09-25 黑屏事故的直接教训）。
nohup setsid bash $DIR/scripts/input-node-sync.sh > $LOGD/input-node-sync.log 2>&1 &
chmod 666 "/dev/input/$TSNODE" 2>/dev/null
# 自证探针（09-25 教训：整轮都是"权限不对但没人报错"）：以**桌面用户身份**试读触摸屏。
# 读不到就等于触摸屏 + 一切鼠标全失效，必须当场喊出来，而不是等用户报"用不了"。
if runuser -u xieyizhou -- test -r "/dev/input/$TSNODE" 2>/dev/null; then
    echo "INPUT-PERM OK $(date +%T)：uid 1000 可读 /dev/input/$TSNODE"
else
    echo "INPUT-PERM FAIL $(date +%T)：uid 1000 读不了 /dev/input/$TSNODE ⇒ 触摸屏与所有鼠标都会失效"
    echo "   多半是 udev 把节点规范成 root:input 0660 而容器无 logind ⇒ 没人下发 uaccess ACL；"
    echo "   解法＝scripts/input-node-sync.sh 里那条 MODE=\"0666\" 规则（已随同步器安装）"
fi
# GPU 同一条纪律：kwin 是 uid 1000 起的，打不开 render 节点就**静默退回软件渲染**
# （llvmpipe），画面照样出，只是花屏/掉帧，最容易被骗成"GPU 驱动炸了"。当场以桌面用户身份验。
GPU_OK=1
for n in /dev/dri/renderD128 /dev/kgsl-3d0; do
    if runuser -u xieyizhou -- test -r "$n" -a -w "$n" 2>/dev/null; then
        echo "GPU-PERM OK $(date +%T)：uid 1000 可读写 $n"
    else
        echo "GPU-PERM FAIL $(date +%T)：uid 1000 读写不了 $n ⇒ kwin 会退软件渲染（花屏/无动效）"
        GPU_OK=0
    fi
done
[ "$GPU_OK" = 1 ] || echo "   解法＝src/kwinwrap.c 的 initgroups（补充组才是真因，见工作总结 5.34①），其次才是上面 mk_dri_node 的兜底"
mkdir -p /run/udev/data
# 原来这三份合成记录**共用一个条件**（c226:0 存在就整块跳过）⇒ 同一开机的第二轮里
# card0 记录还在、触摸屏那份却没重写，而触摸屏节点号这时已经被活的 udevd 冷插成别的
# eventN（09-25 实测第二轮"2.4G 鼠标能用、触屏挂"） ⇒ 拆成各自独立判断。
if ! grep -q DRIVER /run/udev/data/c226:0 2>/dev/null; then
    printf 'Q:100\nE:DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/card0\nE:MAJOR=226\nE:MINOR=0\nE:SUBSYSTEM=drm\nE:DEVTYPE=drm_minor\nE:DEVNAME=dri/card0\nE:DRIVER=vmwgfx\nH:uaccess\nH:seat\n' > /run/udev/data/c226:0
fi
if ! grep -q DRIVER /run/udev/data/c226:128 2>/dev/null; then
    printf 'Q:101\nE:DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/renderD128\nE:MAJOR=226\nE:MINOR=128\nE:SUBSYSTEM=drm\nE:DEVTYPE=drm_minor\nE:DEVNAME=dri/renderD128\nE:DRIVER=vmwgfx\nH:uaccess\nH:seat\n' > /run/udev/data/c226:128
fi
# 触摸屏记录：**按设备名找它现在的 major:minor**，不再硬编码 13:75/event11。
if [ -n "$TSMAJ" ] && [ -n "$TSMIN" ]; then
    TSPATH=$(readlink -f "$TS/device"); TSPATH=${TSPATH#/sys}
    chmod 666 "/dev/input/$TSNODE" 2>/dev/null
    printf 'Q:100\nE:DEVPATH=%s\nE:MAJOR=%s\nE:MINOR=%s\nE:SUBSYSTEM=input\nE:DEVNAME=input/%s\nE:ID_INPUT=1\nE:ID_INPUT_TOUCH=1\nE:ID_INPUT_TOUCHSCREEN=1\nE:LIBINPUT_DEVICE_GROUP=11/6/15d9:NVTCapacitiveTouchScreen\nE:LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1 0 0 1\nH:uaccess\nH:seat\n' \
        "$TSPATH" "$TSMAJ" "$TSMIN" "$TSNODE" > "/run/udev/data/c$TSMAJ:$TSMIN"
    echo "TOUCH-RECORD $TSNODE ($TSMAJ:$TSMIN) 已按设备名重写"
else
    echo "TOUCH-RECORD FAIL: 拿不到触摸屏的 major:minor ⇒ 触摸会失效"
fi
chmod -R a+rX /run/udev

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
# 桌面进程的环境补丁：**接管轮是 runuser+env 起的，不过 PAM**，所以 pam_env 给常态桌面的
# 配置里，只有语言这一类是真的缺（09-25 用户实报"好多东西变英文"）：
#   /etc/default/locale 的 LANG/LC_ALL=zh_CN.UTF-8 ⇒ 缺了 kwin/plasma 就报
#   "Detected locale C … 不是 UTF-8"，界面退英文。值从文件现读，不在脚本里抄（抄了必漂移）。
#
# **血泪边界：MESA_* / TU_DEBUG 一律不注入。** 09-25 我照 kwin.log 里
# `EGL setup failed, disabling glamor → falling back to sw` 判定"接管轮一直软渲染"，
# 于是把 `/etc/environment` 的 `MESA_LOADER_DRIVER_OVERRIDE=kgsl` 喂进 kwin —— 结果 kwin 换到
# kgsl winsys，`kgsl_bo_new_dmabuf: Failed to allocate dma-buf` 刷 544 次、一帧都送不出去，
# **从"花屏"直接变成"纯黑且不回滚"**，用户只能强制重启。而这条噪音该怎么解读，
# 工作总结里已经写过两次：见 5.14/5.23 更正（"不是软件回退，Mesa 栈完整、vkmark 1w+ 分"）
# 与 5.34④ 旁边那条"同一噪音第三次误用"。**接管不需要动这套 Mesa**（见 §Mesa 结论：
# kgsl 缓冲只进不出，bo 导不出 dmabuf，KMS 直显方向相反）。
# 要判 GPU 到底用没用上，用下面的 GPU-WHICH 实测探针，不看日志措辞。
# 另外 `DISPLAY/WAYLAND_DISPLAY/QT_IM_MODULE/XMODIFIERS` 也**故意不收**：轮里走
# plasma-keyboard 路线（见上面 IM 段）；后面各条命令的 -u 仍会照摘。
# **env 的选项必须排在第一个 KEY=VALUE 之前**（5.28 的老坑，我今天又踩一次：写反 ⇒
# `env: '-u': No such file or directory` ⇒ kwin 没起 ⇒ 黑屏回滚）。
DESK_ENV=()
for f in /etc/default/locale /etc/environment; do
    [ -r "$f" ] || continue
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        case "$line" in
            LANG=*|LC_*=*|XCURSOR_SIZE=*|QT_QPA_PLATFORMTHEME=*)
                DESK_ENV+=("$line") ;;
        esac
    done < "$f"
done
echo "DESK-ENV 补 ${#DESK_ENV[@]} 条: ${DESK_ENV[*]:-（空！/etc 那两份文件读不到，界面会继续变英文+软件渲染）}"
kill_linux_stack
rm -f $DIR/takeover.ok
env KWINWRAP_HIJACK=1 KWINWRAP_FILTER=1 KWINWRAP_SECCOMP=1 \
    KWINWRAP_UID=1000 KWINWRAP_GID=1000 KWINWRAP_BRIGHTNESS=2048 \
    $DIR/bin/kwinwrap --out $LOGD/kwinatomic.log -- \
    env -u DISPLAY -u WAYLAND_DISPLAY ${DESK_ENV[@]+"${DESK_ENV[@]}"} HOME=/home/xieyizhou \
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
    ${DESK_ENV[@]+"${DESK_ENV[@]}"} QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=taketest \
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
    -u SDL_IM_MODULE -u GLFW_IM_MODULE -u XMODIFIERS "${XWARGS[@]}" ${DESK_ENV[@]+"${DESK_ENV[@]}"} \
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
# ---- 4b) kded5：接管轮里**从来没人起它** ⇒ 所有 kded 模块不加载。
# 直接现象就是用户 09-25 报的"右下角看不到蓝牙"：bluedevil 的托盘图标与配对接缝（agent）
# 都是 kded 模块（§26.5 当时只记了"要 plasmashell 重启一次才加载"，其实根本没人拉起 kded）。
# 本机是 KF6：二进制叫 /usr/bin/kded6（常态会话里 pid 1563 就是它，由 startplasma-wayland 带起）。
# 之前我 glob 了 kded5/libexec 两处，全落空 ⇒ 13:03 轮报 KDED-SKIP，等于这条修复压根没生效。
KDED=$(ls /usr/bin/kded6 /usr/bin/kded5 /usr/libexec/kded5 /usr/lib/*/kded5 2>/dev/null | head -1)
KDNAME=$(basename "$KDED" 2>/dev/null)   # KF6 那份叫 kded，判活必须跟着实际名字走
if [ -n "$KDED" ]; then
    nohup runuser -u xieyizhou -- env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE \
        -u SDL_IM_MODULE -u GLFW_IM_MODULE -u XMODIFIERS \
        ${DESK_ENV[@]+"${DESK_ENV[@]}"} WAYLAND_DISPLAY=taketest XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
        HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        QT_QPA_PLATFORM=wayland "$KDED" > $LOGD/kded.log 2>&1 &
    KDPID=""
    for i in 1 2 3 4 5; do
        KDPID=$(pgrep -x "$KDNAME" | head -1)
        [ -n "$KDPID" ] && break
        sleep 1
    done
    if [ -n "$KDPID" ]; then
        echo "KDED-UP pid=$KDPID $(date +%T)（bluedevil 托盘图标/配对接缝的宿主）"
    else
        echo "KDED-FAIL $(date +%T): $KDED 没起来 ⇒ 蓝牙图标一类 kded 件仍然缺席，kded.log 尾部："
        tail -n 5 $LOGD/kded.log 2>&1
    fi
else
    echo "KDED-SKIP 容器里找不到 kded5（装 kde-cli-tools/plasma-workspace 哪个包带的？）"
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
    ${DESK_ENV[@]+"${DESK_ENV[@]}"} WAYLAND_DISPLAY=taketest \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    QT_QPA_PLATFORM=wayland \
    "$PDEV" > $LOGD/powerdevil.log 2>&1 &
# 任务栏点击启动应用走 xdg-desktop-portal；不带 KDE 环境起来的话只有 gtk 后端
nohup runuser -u xieyizhou -- env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE \
    -u SDL_IM_MODULE -u GLFW_IM_MODULE -u XMODIFIERS \
    ${DESK_ENV[@]+"${DESK_ENV[@]}"} WAYLAND_DISPLAY=taketest XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    QT_QPA_PLATFORM=wayland \
    /usr/libexec/xdg-desktop-portal > $LOGD/portal.log 2>&1 &
touch $DIR/takeover.ok
$DIR/bin/setbright 2048 > /dev/null 2>&1
echo "DESKTOP-UP $(date +%T) kwin pid $KPID"
# ---- 4a-2) GPU 实测（后台，不阻塞）：**判有没有硬渲染只认这个，不认 kwin.log 的措辞** ----
# 09-25 教训：kwin.log 里 "disabling glamor / falling back to sw" 是 Xwayland 开不到
# renderD128 时 Xwayland 自己的输出，历史上已三次被误读成"整个桌面软渲染"（vkmark 1w+ 早就
# 证否过一次）。这里直接问渲染器名字：
#   Adreno …        = kgsl DRI 硬渲染
#   zink Vulkan …   = 默认路径（turnip 过 Vulkan），同样是硬渲染 —— 接管轮 21 轮一直是这条
#   llvmpipe        = 真软渲染，才算问题
# 探针不成立时打 NO-PROBE（glxinfo 没输出/连不上 :0），绝不说成"没有 GPU"。
(
    sleep 12
    R=$(runuser -u xieyizhou -- env DISPLAY=:0 timeout 12 glxinfo -B 2>/dev/null | sed -n 's/^OpenGL renderer string: //p' | head -1)
    case "$R" in
        *llvmpipe*) echo "GPU-WHICH $(date +%T): $R ⇒ **软渲染**，Xwayland 打不开 render 节点（查补充组/GPU-NODE）" ;;
        "")         echo "GPU-WHICH $(date +%T): NO-PROBE（glxinfo 无输出/连不上 :0）⇒ 这条没测到，别当作没有 GPU" ;;
        *)          echo "GPU-WHICH $(date +%T): $R ⇒ 硬渲染可用" ;;
    esac
) &

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
    # 精确化（09-25）：容器有独立 PID ns，`-x` 在这里看不到安卓的 supplicant，本来就不致命中；
    # 但按 desk-wpa.pid + `-u` 特征杀仍然更正确——它同时清掉"NM 经 D-Bus 激活的容器 systemd 版"，
    # 并且若将来这段被挪到安卓 ns 里执行（run()），不会变成 5.30 那种无差别杀。LEAK 只点名不动手。
    if [ -f /run/desk-wpa.pid ]; then
        kill "$(cat /run/desk-wpa.pid)" 2>/dev/null
        rm -f /run/desk-wpa.pid
    fi
    pkill -9 -f 'wpa_supplicant -u' 2>/dev/null
    pgrep -fa wpa_supplicant | grep -v ' -u' >/dev/null 2>&1 && \
        echo "WPA-KEEP(安卓侧实例，容器 ns 本不可见，仅记录) $(date +%T)"
    pkill -x dhcpcd 2>/dev/null
    if command -v NetworkManager >/dev/null 2>&1; then
        # 【09-25 傍晚 根因实锤，见工作总结 5.36】这里原有的 down;sleep 1;up **永不进可信路径**：
        # STA 已连接 + 芯片 idle ~36min 时，down 硬拆链路（SYS MC STOP）后 1s 的 up 撞进 cnss 的
        # MHI 上电流程（POWER_ON -110 超时 → recovery ASSERT），`ip` 永久 D 在 cnss_idle_restart
        # 并持有 rtnl_lock —— 此后连只读 `ip link show` 都进 D，安卓 netd 一并冻结，只能强启。
        # 接管只需要 L3（地址/路由清理），supplicant/NM 在已 UP 的口上工作是常态路径；
        # "此刻是否 UP"的检查统一放到 WIFI-PRESTATE 之后（那里只读探测并置 WIFI_SKIP）。
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
        # 【5.36 方案 A】原来这三样靠 down/up 顺带清，现在禁 flap ⇒ 显式做（全是 L3，零 admin 动作）
        ip route flush dev wlan0 2>/dev/null
        ip -6 route flush dev wlan0 2>/dev/null
        ip neigh flush dev wlan0 2>/dev/null
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
    stop_supplicant                       # 上一轮残留：先 TERM 等它自己注销 cfg80211 请求
    # 失败轮的**真签名**（09-25 09:41 / 10:20 两轮）是 supplicant 每 10s 重试都报
    #   Could not set interface wlan0 flags (UP): Invalid argument
    #   WEXT: Could not set interface 'wlan0' UP → wlan0: Failed to initialize driver interface
    # 也就是**内核拒绝把 wlan0 拉 UP**；而"是谁拒的"当时没采到 ⇒ 起 supplicant 前一次采全：
    # rfkill 软/硬阻塞、全部 wdev（看有没有上一任的残骸）、接口 flags、驱动是否在做 recovery。
    # 只采状态、不下判断（避免"OK"打在没验证的对象上，见工作总结的探针自证纪律）。
    {
        echo "WIFI-PRESTATE $(date +%T) uptime=$(cut -d. -f1 /proc/uptime)s"
        # 容器 /dev 里没有 /dev/rfkill（同 /dev/uhid 那类缺件，见 5.29②），所以走 sysfs；
        # 读不到就明着打 READ-FAIL —— 权限盲区比"没有阻塞"更危险，不能让它伪装成后者。
        # **判阻塞以 soft/hard 为准，别信 state**：本机实测 wlan 那份 `soft=0 hard=0` 却
        # `state=1`（安卓侧 WiFi 正在连接中，显然没被阻塞）—— 与 power-state-sync 那条
        # "小米 BSP 的 current_now 符号反了"同族的口径坑。
        for r in /sys/class/rfkill/rfkill*; do
            [ -e "$r/soft" ] || continue
            so=$(cat "$r/soft" 2>/dev/null) || so=READ-FAIL
            ha=$(cat "$r/hard" 2>/dev/null) || ha=READ-FAIL
            st=$(cat "$r/state" 2>/dev/null) || st=READ-FAIL
            echo "  $(basename $r) type=$(cat $r/type 2>/dev/null) name=$(cat $r/name 2>/dev/null) soft=$so hard=$ha (state=$st，仅参考)"
        done
        echo "  --- wdev 一览（看有没有上一任留下的残骸 iface）---"
        iw dev 2>&1 | grep -E "phy|Interface|ifindex|wdev|type" | head -30
        ip -o -br link show wlan0 2>&1
        # 驱动 recovery 状态**必须走安卓侧 dmesg**：容器的 dmesg 里 cnss/wlan 一条都没有
        # （实测 15590 行里 0 命中），安卓侧 root 读才有（同刻实测 4 命中，含 cnss-daemon 行）。
        run "dmesg | grep -icE \"cnss|is_driver_recovering|subsys.*(restart|crash|fatal)\""
        run "dmesg | grep -iE \"cnss|is_driver_recovering|wlan0\" | tail -8"
    } 2>&1 | tee $LOGD/wifi-prestate.txt
    iw dev wlan0 scan abort >/dev/null 2>&1
    # 【09-25 傍晚】原来的 PRECLEAR down;sleep 1;up 就是 5.36 定案的致命动作本身（探针不能拿
    # 命换信息）⇒ 改只读。此刻若已 DOWN，up 的路径归射频状态机（安卓 toggle / supplicant
    # 自带 up），我们不替它做 ⇒ 置 WIFI_SKIP 走"无网桌面"分支（desk-stop 照常交还）。
    # ⚠ UP 判定必须解析 flags 尖括号（16:29 轮实锤的自身 bug：`ip -o -br link` 输出
    # "wlan0 DOWN ... <NO-CARRIER,BROADCAST,MULTICAST,UP>"，operstate 列是 DOWN 但 IFF_UP
    # 在 flags 里；`grep ' UP'` 要求空格前缀永远不命中 ⇒ 把 admin-UP 误判成 DOWN，
    # 白跳过整段 WiFi。探针错一次，结论全反——先自证探针会命中再信它的否定）。
    LFLAGS=$(ip -o link show wlan0 2>/dev/null | head -1 | sed -n 's/.*<\([A-Z_,]*\)>.*/,\1,/p')
    case "$LFLAGS" in
        *,UP,*)
            echo "WIFI-ADMIN UP（不 flap，只做 L3 清理） $(date +%T)"
            ;;
        *)
            echo "WIFI-SKIP(admin-down) $(date +%T)：wlan0 flags=$LFLAGS 无 UP，禁 flap 红线生效，本轮跳过 WiFi 段"
            WIFI_SKIP=1
            ;;
    esac
    if [ "$WIFI_SKIP" = 1 ]; then
        :
    else
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
    fi   # WIFI_SKIP 分流收尾（起 supplicant/NM 的 else 支路到此为止）
else
# ---- 5L) legacy 手管段（NM 未安装时的 fallback，原 wpa+dhcpcd+表1015 方案） ----
if [ -f "$WIFI_GEN" ] || [ -f "$WIFI_CONF" ]; then
[ -f "$WIFI_GEN" ] && WIFI_CONF="$WIFI_GEN"
pkill -TERM -x wpa_supplicant 2>/dev/null   # legacy 段本就只在容器内跑；-x 命中容器实例
pkill -x dhcpcd 2>/dev/null
sleep 1
# 5.36 禁 flap 红线同样适用于本 fallback 段（只读确认，不 down/up；非 UP 就让 wpa 自己失败
# 走 NET-FAILED 支路，桌面照留，交还不冻结 rtnl）
ip -o -br link show wlan0 2>/dev/null
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
    pkill -TERM -x wpa_supplicant 2>/dev/null
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
# **默认开**（`BT_BRIDGE=0` 可关）。09-25 实测：裸 udevd + 桥同轮跑，WiFi 全程正常
# （ping 通、dmesg 里 `is_driver_recovering` 计数 0），蓝牙鼠标连上可用；
# 之前"默认开就炸 WiFi"是错的归因，真凶是**同轮里 restart 服务化 udevd**（见 5.31）。
# 桥本身只走 BT 的 glink/ttyHS，绝不下固件、绝不碰 btpower ioctl。
# 三道护栏（都是被实测逼出来的，缺一不可）：
#   ① 桥自熔断：每 10s 查 init.svc.surfaceflinger，一旦 running 就自退
#      （曾抓到 surfaceflinger=running 时桥还活着 = 安卓蓝牙栈与我们同时持有 HAL 客户端位）；
#   ② desk-stop 的 kill_desktop 与 50s 看门狗都 pkill -x bthci-bridge；
#   ③ desk-takeover 的 rollback 分支也 pkill（KDE 重启/回滚都不走 desk-stop）。
# 交还时 desk-stop 先 pkill -x bthci-bridge：进程一退 tty 就关 → 内核自动注销 hci0。
if [ "${BT_BRIDGE:-1}" = 1 ]; then
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
    echo "BT-BRIDGE SKIPPED $(date +%T)（本轮 /run/drm-round.conf 或环境变量里显式 BT_BRIDGE=0）"
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
