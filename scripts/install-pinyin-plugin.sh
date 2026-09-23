#!/bin/bash
# install-pinyin-plugin.sh — 给 Qt VirtualKeyboard 补装官方 Pinyin 输入插件。
# 背景：Ubuntu 的 Qt6 VirtualKeyboard 构建砍掉了中文插件（INPUT_lang_ch_CN=no），
# 导致 plasma-keyboard 自带的 zh_CN 布局（引用 PinyinInputMethod）无法工作。
# 本脚本从 code.qt.io 拉与已装 VKB 同版本的源码，只编 pinyin 插件并装入系统 QML 路径。
# 需 root；版本自动从 dpkg 探测（qml6-module-qtquick-virtualkeyboard）。
set -e
VER=$(dpkg-query -W -f='${Version}' qml6-module-qtquick-virtualkeyboard | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/v\1/')
TAG="$VER"
[ -n "$TAG" ] || { echo "探测 VKB 版本失败"; exit 1; }
D=${1:-/tmp/qtvirtualkeyboard-$TAG}
command -v ninja >/dev/null && command -v cmake >/dev/null || { echo "需要 cmake ninja qt6-virtualkeyboard-dev"; exit 1; }
[ -d "$D" ] || git clone --depth 1 --branch "$TAG" https://code.qt.io/qt/qtvirtualkeyboard.git "$D"
cmake -S "$D" -B "$D/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DINPUT_lang_ch_CN=yes >/dev/null
ninja -C "$D/build" qtvkbpinyinplugin
SRC=$(find "$D/build" -type d -name Pinyin -path "*VirtualKeyboard/Plugins*" | head -1)
DEST=/usr/lib/aarch64-linux-gnu/qt6/qml/QtQuick/VirtualKeyboard/Plugins
mkdir -p "$DEST/Pinyin"
cp -r "$SRC"/* "$DEST/Pinyin/"
grep -q Pinyin "$DEST/qmldir" || sed -i "/import QtQuick.VirtualKeyboard.Plugins.Hangul auto/i import QtQuick.VirtualKeyboard.Plugins.Pinyin/auto" "$DEST/qmldir"
echo "PINYIN-PLUGIN INSTALLED: $DEST/Pinyin (tag $TAG)"
