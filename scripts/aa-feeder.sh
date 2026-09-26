#!/bin/sh
# 容器侧喂流器：把默认 sink（anland-speaker）的 monitor 裸 PCM 推给安卓侧 aa-bridge。
# 链路：容器应用 → PipeWire 混音 → monitor → pw-cat -r → 环回 TCP → aa-bridge → AAudio → audioserver
# 容器与安卓共享 netns（实测双向 TCP 可达），所以 127.0.0.1 就够，不需要额外挂载。
# 用法：sh aa-feeder.sh [host:port]      默认 127.0.0.1:44777
#   安卓侧先起：su -c 'PORT=44777 /data/local/tmp/aa-bridge'
set -u
TGT=${1:-127.0.0.1:44777}
HOST=${TGT%%:*}
PORT=${TGT##*:}
SR=${SR:-48000}
CH=${CH:-2}

sink_id() {
  wpctl status 2>/dev/null | awk '/├─ Sinks:/{f=1;next} /├─ Sources:/{f=0} f' \
    | grep '\*' | grep -o '[0-9]\+' | head -1
}

while :; do
  ID=$(sink_id)
  if [ -z "$ID" ]; then echo "找不到默认 sink，2s 后重试" >&2; sleep 2; continue; fi
  echo "抓 sink #$ID → $HOST:$PORT" >&2
  pw-cat -r -a --target="$ID" --format=s16 --rate="$SR" --channels="$CH" - 2>/dev/null \
    | nc -q1 "$HOST" "$PORT"
  echo "喂流断开（桥未起或收流），3s 后重连" >&2
  sleep 3
done
