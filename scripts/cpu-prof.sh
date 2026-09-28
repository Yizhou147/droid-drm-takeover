#!/system/bin/sh
# cpu-prof.sh — 设备侧（安卓 root）探针：核占用 + 线程落点 + 每核频率 + caps + GPU 档。
# 用途：判"负载到底跑在哪几个核上"（vkmark/游戏分数归因）。
# 装到安卓：adb -s <EP> push scripts/cpu-prof.sh /data/local/tmp/
#           adb -s <EP> shell "su -c 'chmod 755 /data/local/tmp/cpu-prof.sh'"
# 跑：     adb -s <EP> shell "su -c 'sh /data/local/tmp/cpu-prof.sh'"
# 注意：同一时间只能有一个被测进程，否则 busy% 会把多个实例混在一起（09-28 踩过）。
PROC=${1:-vkmark}
P=$(pgrep -x "$PROC" | head -1)
[ -n "$P" ] || { echo "NO-PROC $PROC"; exit 1; }
echo "PID=$P"
grep -E "^cpu[0-9]+ " /proc/stat > /tmp/_s1
sleep 5
grep -E "^cpu[0-9]+ " /proc/stat > /tmp/_s2
echo "== per-cpu busy% (5s):"
awk 'NR==FNR{t[$1]=$2+$3+$4+$5+$6+$7+$8; i[$1]=$4+$5; next}{T=($2+$3+$4+$5+$6+$7+$8)-t[$1]; I=($4+$5)-i[$1]; printf "%s %.1f\n", $1, (T>0?100*(T-I)/T:0)}' /tmp/_s1 /tmp/_s2
echo "== threads (tid state lastcpu utime):"
for d in /proc/$P/task/*; do awk '{printf "%s %s %s %s\n", $1, $3, $39, $14}' "$d/stat"; done
echo "== per-cpu cur_freq:"
for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do printf "%s " "$(basename $(dirname $(dirname $c)))"; cat "$c"; done
echo "== caps (policy min max):"
for p in /sys/devices/system/cpu/cpufreq/policy*; do printf "%s " "$(basename $p)"; cat "$p/scaling_min_freq" "$p/scaling_max_freq" | tr '\n' ' '; echo; done
echo "== gpu cur_freq / min_pwrlevel / throttling:"
cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq /sys/class/kgsl/kgsl-3d0/min_pwrlevel /sys/class/kgsl/kgsl-3d0/throttling
