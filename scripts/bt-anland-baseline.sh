#!/bin/bash
# bt-anland-baseline.sh — anland 正常态的蓝牙电源基线（对照 DRM 轮内看到的 bt_power soft=1）
# 只读：不碰 rfkill、不重启服务、不按键。锁屏请用户自己做（Doze 才有机会进）。
# 每 5s 采内核侧便宜信号；每 30s 采一次安卓侧贵信号；soft 一翻转就立刻 dump 现场。
DEV=$(adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "NO-ADB"; exit 1; }
R=${1:-600}
HEAVY=${HEAVY:-6}            # 每几次采样走一次 adb（见下面观测者效应注释）
# 自定位：仓库同级 logs
ROOT=${ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
OUT=${OUT:-$(dirname "$ROOT")/logs/bt-anland-baseline-$(date +%m%d-%H%M%S).log}
run() { timeout 10 adb -s "$DEV" shell "su -c '$1'" 2>&1 | tr -d '\r'; }
rf_read() {
    for f in /sys/class/rfkill/rfkill*; do
        [ "$(cat $f/name 2>/dev/null)" = "$1" ] && { echo "$(cat $f/soft 2>/dev/null)/$(cat $f/hard 2>/dev/null)"; return; }
    done
    echo NOREAD
}
IBS_COUNT() { run "logcat -d -t 400 2>/dev/null | grep -ci -e ibs_ -e SerialClockVote" | tail -1; }
PREV=""
echo "=== BT-ANLAND-BASELINE START $(date +%F_%T) 时长=${R}s 输出=$OUT ==="
echo "说明：本脚本只读观测（不碰 rfkill、不重启服务、不按键）；Doze 需要设备自己idle且未插电" | tee -a "$OUT"
end=$(( $(date +%s) + R )); N=0
while [ "$(date +%s)" -lt "$end" ]; do
    TS=$(date +%T); S=$(rf_read bt_power)
    printf "%s bt_power=%s" "$TS" "$S"
    # HEAVY=每几次采样走一次 adb（本地 sysfs 读是免费的，adb 才有成本）。
    # ⚠ 观测者效应：adb 轮询本身会产生 binder/网络活动，可能推迟 deviceidle 进 IDLE
    #   （idle 超时要求一段时间无网络活动）。跑长窗口时把 HEAVY 调大（比如 12=60s 一次），
    #   并在结论里记住"这轮是在被低频打扰的状态下测的"。
    if [ "$((N % HEAVY))" = 0 ]; then
        BT=$(run "dumpsys bluetooth_manager 2>/dev/null | grep -m1 State:")
        HALS=$(run "getprop persist.vendor.bluetooth.state")
        SCR=$(run "dumpsys power 2>/dev/null | grep -m1 -e mWakefulness= -e mScreenOnEarly=")
        DZ=$(run "dumpsys deviceidle 2>/dev/null | grep -m1 -e mState= -e mIdleMode=")
        # mPlugged 必须一起看：插着电时安卓一般不进 deep doze，
        # 那么"整轮 mState 一直 ACTIVE、soft 一直 0"就不能当成"正常态永不翻转"的结论
        # 注意 `-e AC powered` 会被设备侧 shell 拆成"模式 AC + 文件 powered"（grep 报
        # No such file or directory），内层又不能再用单引号 ⇒ 用 `.` 顶替空格
        PLUG=$(run "dumpsys battery 2>/dev/null | grep -m1 -e AC.powered -e USB.powered -e AC.online")
        # IBS 计数=最近 400 行 logcat 里 ibs_/SerialClockVote 的行数（UART 传输层省电节奏的代理量）。
        # 它和 bt_power 的 soft 是两件事：前者只是 UART 时钟 vote，后者才是芯片电源域。
        IC=$(IBS_COUNT)
        printf " | %s | %s | %s | plugged=[%s] | halBT=%s | ibs400=%s" \
            "$(echo "$BT" | tr -s ' ' | head -1)" "$(echo "$SCR" | tr -s ' ' | head -1)" \
            "$(echo "$DZ" | tr -s ' ' | head -1)" \
            "$(echo "$PLUG" | tr '\n' ' ')" "${HALS:-NOREAD}" "${IC:-NOREAD}"
    fi
    if [ -n "$PREV" ] && [ "$S" != "$PREV" ]; then
        printf "\n>>> 沿 %s: bt_power %s → %s —— dump 现场 <<<\n" "$TS" "$PREV" "$S"
        run "dmesg 2>/dev/null | grep -i -e btpower -e bt_power -e bluetooth -e hci -e cnss | tail -8" | sed 's/^/      dmesg /'
        run "logcat -d -t 600 2>/dev/null | grep -i -e ibs_handler -e SerialClockVote -e wake_lock -e BluetoothAdapterProperties -e bt_state | grep -v -e adbd -e ShellService | tail -12" | sed 's/^/      logcat /' | tee -a "$OUT"
    fi
    PREV=$S
    echo
    N=$((N+1)); sleep 5
done
echo "=== BT-ANLAND-BASELINE DONE $(date +%T) 共 $N 个采样点；soft 翻转见上面 >>> 行（没有即全程未翻转）==="
