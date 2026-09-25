#!/bin/bash
# input-node-sync.sh — 接管期把内核 input 设备补成 /dev/input/eventN 节点。
#
# 为什么需要：容器里的 udevd 是被 Droid Spaces 的 ExecCondition(enable_hw_access=1)
# 挡起来的（systemd 单元 skipped），desk-takeover 只能裸 `nohup systemd-udevd` 兜底；
# 这种实例会写 /run/udev/data（所以 udev 标签是对的），但**不建 /dev 节点**
# （/run/udev/control 也不存在）。BLE 鼠标/键盘走 BlueZ HOGP→内核 uhid 时长出新的
# input 设备，节点不在 → libinput 打不开 → 静默跳过，现象就是"显示连上了但没指针"
# （09-25 实测：/proc/bus/input/devices 里有 BT1 Mouse→event16、DB 里 ID_INPUT_MOUSE
# 和 seat 标签都齐，只有 /dev/input/event16 不存在）。
#
# 做法：3 秒一圈幂等扫描 /sys/class/input/*，缺节点就按里面的 major:minor 自己 mknod，
# 建完再向内核补发一次 uevent。只碰 input，绝不碰 net（wlan0→wlp1s0 改名是 09-24 的
# WiFi 报废事故，见工作总结 5.23）。
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
RULE=/etc/udev/rules.d/99-drm-input-seat.rules

# libinput 只吃"分到座位上"的设备；seat/uaccess 平时由 logind 会话给，容器里没有 ⇒ 自己补
if ! grep -q 'ID_SEAT' "$RULE" 2>/dev/null; then
    mkdir -p /etc/udev/rules.d
    cat > "$RULE" <<'R'
# 容器无 logind 会话 ⇒ uaccess/seat 标签没人打，libinput 直接跳过设备（见 scripts/input-node-sync.sh）
SUBSYSTEM=="input", ENV{ID_INPUT}=="1", ENV{ID_SEAT}="seat0", TAG+="seat", TAG+="uaccess"
R
    udevadm control --reload 2>/dev/null
fi

sync_one() {
    local d="$1" n mj mn
    [ -e "$d/dev" ] || return 0
    n=$(basename "$d")
    case "$n" in event*) ;; *) return 0 ;; esac
    [ -e "/dev/input/$n" ] && return 0
    IFS=: read -r mj mn < "$d/dev"
    [ -n "$mj" ] && [ -n "$mn" ] || return 0
    mknod "/dev/input/$n" c "$mj" "$mn" 2>/dev/null
    chmod 666 "/dev/input/$n" 2>/dev/null
    echo "input-node-sync: made /dev/input/$n ($mj:$mn) $(date +%T)"
    # 关键：libinput 和我们听的是同一条 uevent 广播，它很可能**先**收到、那时节点还不存在，
    # 于是打开失败就再也不管这个设备了。节点建好后自己补发一次 add，让它重来一遍。
    [ -w "$d/uevent" ] && echo add > "$d/uevent" 2>/dev/null
}

# 轮询而不是只挂 monitor：monitor 只给"通知"，补发 uevent 需要我们在节点建好后再动一次手，
# 3 秒一圈的幂等扫描比和广播抢顺序可靠（input 设备总共十来个，开销可忽略）。
while :; do
    for d in /sys/class/input/*; do sync_one "$d"; done
    sleep 3
done
