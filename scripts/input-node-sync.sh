#!/bin/bash
# input-node-sync.sh — 接管期把内核 input 设备补成可用的 /dev/input/eventN 节点。
#
# 为什么需要（09-25 一整天踩出来的两条）：
# 1) **节点根本不存在**：容器里 udevd 被 Droid Spaces 的
#    ExecCondition(enable_hw_access=1) 挡成 skipped，接管脚本只能裸 `nohup systemd-udevd`
#    兜底；那种实例会写 /run/udev/data（标签是对的）但**不建 /dev 节点**，
#    /run/udev/control 也没有。BLE 鼠标经 BlueZ HOGP→内核 uhid 长出 input20/event16 后，
#    `/proc/bus/input/devices` 有、DB 里 ID_INPUT_MOUSE+seat 标签都有，就是没有节点，
#    现象＝"显示连上了但没指针"。
# 2) **节点在但权限不对**：真 udevd 单元起来后按规则规范属主/权限（`crw-rw---- root:input`），
#    而容器没有 logind ⇒ `TAG+="uaccess"` 只是个标记、**没人下发 ACL** ⇒ 以 uid 1000 跑的
#    kwin 打不开任何输入设备，触摸屏 + BLE 鼠标 + 2.4G 鼠标**一起失效**。
#    旧版本只处理"缺节点"，没处理"节点在但权限错"，所以这条当时没被拦住。
#
# 所以：规则里把 seat/uaccess/ID_SEAT 和 `MODE="0666"` 一起钉死；已存在的节点每轮补 chmod。
# 只碰 input，绝不碰 net（wlan0→wlp1s0 改名是 09-24 的 WiFi 报废事故，见工作总结 5.23）。
RULE=/etc/udev/rules.d/99-drm-input-seat.rules

mkdir -p /etc/udev/rules.d
if ! grep -q 'MODE="0666"' "$RULE" 2>/dev/null; then
    cat > "$RULE" <<'R'
# 容器没有 logind 会话：seat/uaccess 标签没人打 ⇒ libinput 直接跳过设备；
# uaccess 的 ACL 也没人下发 ⇒ root:input 0660 的节点，uid 1000 的 kwin 打不开。
# 两件事一起解决（09-25 实测：触摸屏和鼠标会同时失效）。
SUBSYSTEM=="input", ENV{ID_INPUT}=="1", ENV{ID_SEAT}="seat0", TAG+="seat", TAG+="uaccess"
SUBSYSTEM=="input", KERNEL=="event*", MODE="0666", GROUP="input"
KERNEL=="uhid", MODE="0666"
R
    udevadm control --reload 2>/dev/null
fi

sync_one() {
    local d="$1" n mj mn
    [ -e "$d/dev" ] || return 0
    n=$(basename "$d")
    case "$n" in event*) ;; *) return 0 ;; esac
    if [ -e "/dev/input/$n" ]; then
        chmod 666 "/dev/input/$n" 2>/dev/null   # 权限被 udev 规范成 0660 也要救
        return 0
    fi
    IFS=: read -r mj mn < "$d/dev"
    [ -n "$mj" ] && [ -n "$mn" ] || return 0
    mknod "/dev/input/$n" c "$mj" "$mn" 2>/dev/null
    chmod 666 "/dev/input/$n" 2>/dev/null
    echo "input-node-sync: made /dev/input/$n ($mj:$mn) $(date +%T)"
    # 关键：libinput 和我们听的是同一条 uevent 广播，它很可能**先**收到、那时节点还不存在，
    # 于是打开失败就再也不管这个设备了。节点建好后自己补发一次 add，让它重来一遍。
    [ -w "$d/uevent" ] && echo add > "$d/uevent" 2>/dev/null
}

# 轮询而不是只挂 monitor：monitor 只给"通知"，而补节点/补权限/补发 uevent 必须我们在
# 事件之后动手才拦得住那个竞态。3 秒一圈幂等扫描（input 设备总共十来个，开销可忽略）。
while :; do
    for d in /sys/class/input/*; do sync_one "$d"; done
    sleep 3
done
