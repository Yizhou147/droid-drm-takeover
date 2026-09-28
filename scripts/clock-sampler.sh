#!/system/bin/sh
# clock-sampler.sh — 设备侧周期采样：cpu0/cpu6 当前频率、GPU 档频、最热 zone、cpufreq 上下限。
# 用途：证明一次跑分期间频率是 sustained 的，而不是开头冲高后被降档（09-28 教训：
#       内联 `su -c '... while ...'` 的嵌套单引号会被本地吃掉，必须落成脚本推上去跑）。
# 用法：adb -s <EP> push scripts/clock-sampler.sh /data/local/tmp/
#       adb -s <EP> shell "su -c 'sh /data/local/tmp/clock-sampler.sh 30 /data/local/tmp/sampler.log'"
N=${1:-30}; OUT=${2:-/data/local/tmp/sampler.log}
: > "$OUT"
i=0
while [ $i -lt "$N" ]; do
    c0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
    c6=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null)
    g=$(cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq 2>/dev/null)
    t=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
    m0=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)
    m6=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null)
    th=$(cat /sys/class/kgsl/kgsl-3d0/throttling 2>/dev/null)
    echo "S $i cpu0=$c0 cpu6=$c6 gpu=$g max=$m0/$m6 thr=$th peak=$t" >> "$OUT"
    i=$((i+1))
    sleep 4
done
