#!/system/bin/sh
# perfmax.sh — 设备侧（安卓 root）"能把这台机器能拧的旋钮都拧到顶"的唯一实现。
#
# 为什么是 sysfs 而不是 perflock（09-28 实测，详见工作总结 §48）：
#   - MIUI/QTI perf HAL（IMiPerf::callPerfLock / perf2 IPerf::perfHint）对调用方做**按包名的白名单校验**
#     （证据：IMiPerf::getXmlcont 返回的就是 "包名 × 场景 × PERF_LOCK_ACQUIRE" 表），
#     root(uid 0) 发过去一律 EX_SERVICE_SPECIFIC(-8)。
#   - 而我们关心的三组旋钮**都能用 sysfs 直接拧**，不需要 HAL：CPU 档频、GPU 档频/DCVS、DDR/LLCC 频率地板。
#
# 子命令：
#   pin      一次性记录原值+原 mode 到 /data/local/tmp/perfmax.orig，然后全部拧到顶（无记录不拧）
#   loop     pin + 周期重申（perf 守护进程会在几秒内把 scaling_max_freq 改回去，必须重申；默认 1800 轮 ×2s=60min 自动退出）
#   stop     让 loop 退出（写 stop 文件）
#   restore  按记录还原全部节点的值与 mode，并回读自证
#   status   打印当前关键节点值
#
# 用法（容器侧）：
#   adb -s <EP> push scripts/perfmax.sh /data/local/tmp/perfmax.sh
#   adb -s <EP> shell "su -c 'chmod 755 /data/local/tmp/perfmax.sh'"
#   adb -s <EP> shell "su -c 'setsid nohup sh /data/local/tmp/perfmax.sh loop >/data/local/tmp/perfmax.out 2>&1 &'"
#   adb -s <EP> shell "su -c 'sh /data/local/tmp/perfmax.sh stop; sh /data/local/tmp/perfmax.sh restore'"
#
# 坑（都实测过，别再踩）：
#   1. 这些节点绝大多数是 **0444**：sysfs/kernfs 无写位时 **CAP_DAC_OVERRIDE 不豁免**，
#      必须先 chmod 再写（见 §43）；还原时把原 mode 一并写回，别留 0664 给安卓。
#   2. CPU 地板=min 与 max **必须成对写**：只提 min 在 max 被压时是空操作（§45.1）。
#   3. 记录文件写不成功就绝不拧（防孤儿钉泄漏给 anland/安卓）。
#   4. 满频+满带宽的代价是发热耗电：pin 态下 die 温度实测能到 65~69°C ⇒ 只作实验/跑分，勿常驻。
#      另外电池供电时内核会另有一层限制（实测 prime 被压在 3072000），别把"写不进去"当成 SELinux。

REC=/data/local/tmp/perfmax.orig
STOP=/data/local/tmp/perfmax.stop
TAB="$(printf '\t')"

# ---- 节点清单 ----
CPU_MIN="0 6"                                   # policy0(little, 6核) / policy6(prime, 2核)
GPU_BASE=/sys/class/kgsl/kgsl-3d0
GPU_NODES="$GPU_BASE/min_pwrlevel $GPU_BASE/pwrscale $GPU_BASE/hwcg $GPU_BASE/ifpc"
DDR_BASE=/sys/devices/system/cpu/bus_dcvs
MEM_NODES=""
for d in gold gold-compute prime prime-latfloor; do
    f=$DDR_BASE/DDR/soc:qcom,memlat:ddr:$d/min_freq
    [ -w "$f" ] || [ -e "$f" ] && MEM_NODES="$MEM_NODES $f"
done
for g in LLCC DDRQOS; do
    for sub in $DDR_BASE/$g/*/min_freq; do
        [ -e "$sub" ] && MEM_NODES="$MEM_NODES $sub"
    done
done
[ -e $DDR_BASE/DDR/min_freq ] && MEM_NODES="$MEM_NODES $DDR_BASE/DDR/min_freq"

# 目标值：CPU=各 policy 的 cpuinfo_max_freq；MEM=该节点同目录 available_frequencies/hw_max_freq 的最高档；
# GPU=0（min_pwrlevel 0=最高档；pwrscale/hwcg/ifpc=0 关 DCVS/时钟门控/瞬时断电）
cpu_target() { cat /sys/devices/system/cpu/cpufreq/policy$1/cpuinfo_max_freq 2>/dev/null | tr -d '\r'; }
mem_target() {
    p=$1; d=$(dirname "$p")
    v=$(cat "$d/hw_max_freq" 2>/dev/null | tr -d '\r')
    [ -z "$v" ] && v=$(cat "$d/available_frequencies" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1)
    echo "$v"
}

record() {
    tmp=$REC.new
    : > "$tmp" || return 1
    for n in $CPU_MIN; do
        for k in scaling_min_freq scaling_max_freq; do
            p=/sys/devices/system/cpu/cpufreq/policy$n/$k
            [ -e "$p" ] || continue
            m=$(stat -c %a "$p" 2>/dev/null); v=$(cat "$p" 2>/dev/null | tr -d '\r')
            [ -n "$m" ] && [ -n "$v" ] || return 1
            printf '%s%s%s%s%s\n' "$m" "$TAB" "$p" "$TAB" "$v" >> "$tmp" || return 1
        done
    done
    for p in $GPU_NODES $MEM_NODES; do
        [ -e "$p" ] || continue
        m=$(stat -c %a "$p" 2>/dev/null); v=$(cat "$p" 2>/dev/null | tr -d '\r')
        [ -n "$m" ] || continue
        printf '%s%s%s%s%s\n' "$m" "$TAB" "$p" "$TAB" "$v" >> "$tmp"
    done
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$REC" || { rm -f "$tmp"; return 1; }
    return 0
}

dowrite() {   # chmod -> write -> 复原 mode（值保持，mode 只影响后续写入）
    p=$1; val=$2; mode=$3
    [ -e "$p" ] || return 0
    chmod 0664 "$p" 2>/dev/null
    echo "$val" > "$p" 2>/dev/null
    [ -n "$mode" ] && chmod "$mode" "$p" 2>/dev/null
}

apply_once() {
    for n in $CPU_MIN; do
        T=$(cpu_target $n)
        [ -n "$T" ] || continue
        dowrite /sys/devices/system/cpu/cpufreq/policy$n/scaling_max_freq "$T" 0664
        dowrite /sys/devices/system/cpu/cpufreq/policy$n/scaling_min_freq "$T" 0664
    done
    for p in $GPU_NODES; do dowrite "$p" 0 0644; done
    for p in $MEM_NODES; do
        T=$(mem_target "$p")
        [ -n "$T" ] && dowrite "$p" "$T" 0644
    done
}

verify() {
    for n in $CPU_MIN; do
        echo "CPU policy$n min/max=$(cat /sys/devices/system/cpu/cpufreq/policy$n/scaling_min_freq 2>/dev/null)/$(cat /sys/devices/system/cpu/cpufreq/policy$n/scaling_max_freq 2>/dev/null) cur=$(cat /sys/devices/system/cpu/cpufreq/policy$n/scaling_cur_freq 2>/dev/null)"
    done
    echo "GPU min_pwrlevel=$(cat $GPU_BASE/min_pwrlevel 2>/dev/null) pwrscale=$(cat $GPU_BASE/pwrscale 2>/dev/null) hwcg=$(cat $GPU_BASE/hwcg 2>/dev/null) ifpc=$(cat $GPU_BASE/ifpc 2>/dev/null) cur=$(cat $GPU_BASE/devfreq/cur_freq 2>/dev/null)"
    echo "DDR cur=$(cat $DDR_BASE/DDR/cur_freq 2>/dev/null)"
}

case "$1" in
pin)
    # 无记录不拧：记录失败（非 root/文件系统异常）时宁可什么都不改
    if ! record; then
        echo "PERFMAX SKIP: 记录写不进 $REC ⇒ 无记录不拧"
        exit 1
    fi
    apply_once
    sleep 1
    echo "PERFMAX PINNED"
    verify
    ;;
loop)
    if [ ! -s "$REC" ]; then
        record || { echo "PERFMAX SKIP: 记录写不进 $REC ⇒ 无记录不拧"; exit 1; }
    fi
    i=0
    echo "PERFMAX LOOP STARTED（上限 ${PERFMAX_LOOPS:-1800} 轮 ×2s，到点自动退出）"
    while [ $i -lt ${PERFMAX_LOOPS:-1800} ]; do
        [ -f "$STOP" ] && { rm -f "$STOP"; echo "PERFMAX LOOP STOPPED at $i"; exit 0; }
        apply_once
        i=$((i+1))
        sleep 2
    done
    echo "PERFMAX LOOP 到达迭代上限自动退出（防被忘了长期满频）"
    ;;
stop)
    : > "$STOP"
    echo "PERFMAX STOP-REQUESTED"
    ;;
restore)
    if [ ! -s "$REC" ]; then
        echo "PERFMAX RESTORE: 无 $REC ⇒ 没拧过或记录丢失（手工核对 CPU/GPU/DDR 是否还在顶档）"
        exit 0
    fi
    bad=0
    while IFS="$(printf '\t')" read -r mode path val; do
        case "$val" in ''|*[!0-9]*) continue ;; esac
        [ -e "$path" ] || continue
        chmod 0664 "$path" 2>/dev/null
        echo "$val" > "$path" 2>/dev/null
        chmod "$mode" "$path" 2>/dev/null
        now=$(cat "$path" 2>/dev/null | tr -d '\r')
        [ "$now" = "$val" ] || { echo "PERFMAX RESTORE-FAIL $path 回读=$now 预期=$val"; bad=$((bad+1)); }
    done < "$REC"
    rm -f "$REC" "$STOP"
    if [ $bad -eq 0 ]; then
        echo "PERFMAX RESTORE OK"
    else
        echo "PERFMAX RESTORE 有 $bad 处未还原 ⇒ 可能还有旋钮留在顶档（发热/耗电），手工核对"
    fi
    verify
    ;;
status|"")
    verify
    ;;
*)
    echo "usage: $0 {pin|loop|stop|restore|status}"
    exit 2
    ;;
esac
