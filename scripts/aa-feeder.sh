#!/bin/sh
# 接管轮容器侧喂流器（A 路）：
#   1) 建一个 **Pulse 也能看见** 的虚拟输出 droid_out（"Droid_Speaker"）并设为默认 ——
#      这样右下角托盘出现可点/可调音量的真实设备，走 Pulse 的应用（浏览器等）也不再掉进 auto_null 变静音。
#      （容器里没有物理声卡：真喇叭归安卓 AudioReach，故只能造虚拟 sink，见《直连音频HAL方案》§35。）
#   2) 抓该 sink 的 monitor（s16/48k/立体声）推到安卓侧 HAL sink（argsloop，127.0.0.1:PORT）。
#   3) 退出（含被 desk-stop/rollback pkill 的 SIGTERM）时卸掉该模块，交还 anland 正常态。
# 用法：sh aa-feeder.sh [host:port]      默认 127.0.0.1:44777
set -u
TGT=${1:-127.0.0.1:44777}
HOST=${TGT%%:*}
PORT=${TGT##*:}
SR=${SR:-48000}
CH=${CH:-2}
NAME=droid_out

# 先清掉上一轮可能残留的同名模块，避免重复。
pactl unload-module module-null-sink 2>/dev/null
MID=$(pactl load-module module-null-sink sink_name="$NAME" \
        sink_properties=device.description=Droid_Speaker media.class=Audio/Sink 2>/dev/null)
if [ -z "$MID" ]; then
  echo "pactl 建 droid_out 失败（PipeWire/pipewire-pulse 没起？）" >&2
else
  pactl set-default-sink "$NAME" 2>/dev/null
fi

cleanup() { [ -n "${MID:-}" ] && pactl unload-module "$MID" 2>/dev/null; }
trap 'cleanup; exit 0' INT TERM EXIT

# droid_out 的 wpctl 数字 id（pw-cat 录制用 --target=<sink id> 会去连它的 monitor）。
sink_id() {
  wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' \
    | grep -a Droid_Speaker | grep -ao '[0-9]\+' | head -1
}

while :; do
  ID=$(sink_id)
  if [ -z "$ID" ]; then echo "找不到 droid_out sink，2s 后重试" >&2; sleep 2; continue; fi
  echo "抓 droid_out(#$ID) monitor → $HOST:$PORT" >&2
  pw-cat -r --target="$ID" --format=s16 --rate="$SR" --channels="$CH" - 2>/dev/null \
    | nc -q1 "$HOST" "$PORT"
  echo "喂流断开（安卓侧 sink 未起或收流），3s 后重连" >&2
  sleep 3
done
