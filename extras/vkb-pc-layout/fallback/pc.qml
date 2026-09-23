// Copyright (C) 2026 Yizhou — piano-patch full-size PC layout (v8)
// SPDX-License-Identifier: GPL-3.0-or-later
// 全尺寸 PC 布局。进入/退出：主键盘 "PC" 键（Qt.Key_F13 + Keyboard.qml pcMode 补丁）。
// v8（外观回退+补齐）：
//   - Enter/退格/空格恢复 EnterKey/BackspaceKey/SpaceKey 原组件原图标（内联派生加 combo）
//   - Menu 恢复 ☰；⇧ 恢复箭头图标
//   - Ctrl/Alt/⇧ 标签首字母大写（uppercased:false），点亮指示恢复底部小横条
//   - 多字功能键 40px 小字（配套 Breeze style.qml piano-patch 一行）
//   - ⇧ 按下时键帽实时换字（字母→大写、数字符号→上档字符）
//   - combo 通道全键盘（继承 v7）：Ctrl/Alt 任意组合 + routeShift 键的 ⇧ 组合走 daemon

import QtQuick
import QtQuick.Layouts
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components
import org.kde.plasma.keyboard
import org.kde.kirigami as Kirigami

KeyboardLayout {
    id: pcRoot
    keyWeight: 100
    inputMode: InputEngine.InputMode.Latin

    function combo(upperKey, mods) {
        var x = new XMLHttpRequest()
        x.open("GET", "http://127.0.0.1:48222/combo?key=" + upperKey + "&mods=" + mods)
        x.send()
    }

    function modsNow() {
        var mods = []
        if (ctrlKey.mode) mods.push("ctrl")
        if (altKey.mode) mods.push("alt")
        if (shiftKey2.mode) mods.push("shift")
        return mods.join(",")
    }

    function releaseModes() {
        ctrlKey.mode = false
        altKey.mode = false
        shiftKey2.mode = false
    }

    // 粘滞修饰键：普通 Key 面板（40px 小字 + MixedCase 首字母大写，靠 Breeze
    // functionKey 补丁与 uppercased:false）。
    // v8.2 点亮态修正：Breeze 的 highlightedKeyBackgroundColor 与 normal 同色，
    // 且原生横条用 textColor（和键文字同色、极细）→ 完全看不出。改为自绘：
    // 半透明高亮底铺满内层背景 + 一根加粗高对比底部条，用 Kirigami highlightColor。
    component ModeButton: Key {
        property bool mode
        key: Qt.Key_unknown
        functionKey: true
        noKeyEvent: true
        uppercased: false
        onClicked: mode = !mode
        // 内层可视背景（对齐 BreezeKeyPanel 的 keyBackgroundMargin 内缩）
        Rectangle {
            id: modeTint
            anchors.fill: parent
            anchors.margins: BreezeConstants.keyBackgroundMargin
            radius: BreezeConstants.buttonRadius
            color: Kirigami.Theme.highlightColor
            opacity: 0.30
            visible: parent.mode
        }
        Rectangle {
            id: modeBar
            anchors.bottom: modeTint.bottom
            anchors.horizontalCenter: modeTint.horizontalCenter
            anchors.bottomMargin: Math.max(3, Math.round(modeTint.height * 0.12))
            width: Math.round(modeTint.width * 0.55)
            height: Math.max(3, Math.round(modeTint.height * 0.10))
            radius: height / 2
            color: Kirigami.Theme.highlightColor
            visible: modeTint.visible
        }
    }

    // 字母键：Ctrl/Alt 走 uinput；⇧ 本地转大写；键帽实时跟随 ⇧
    component PCKeep: Key {
        property int upperKey
        readonly property bool modActive: ctrlKey.mode || altKey.mode
        noKeyEvent: modActive
        // BaseKey.uppercased 默认跟 InputContext.uppercase（Konsole 恒真 bug 根源），
        // 本页大小写只认 ⇧
        uppercased: shiftKey2.mode
        key: shiftKey2.mode ? upperKey : (upperKey + 32)
        text: shiftKey2.mode ? String.fromCharCode(upperKey) : String.fromCharCode(upperKey + 32)
        displayText: text
        onClicked: {
            if (modActive) {
                pcRoot.combo(upperKey, pcRoot.modsNow())
                pcRoot.releaseModes()
            } else {
                shiftKey2.mode = false
            }
        }
    }

    // 打印字符键（数字/符号）：⇧ 本地出上档字符并实时显示；Ctrl/Alt 走 daemon
    component PCKey: Key {
        property int comboCode: Qt.Key_unknown
        property string baseText: ""
        property string shiftText: ""
        property string label: ""
        property bool routeShift: false
        readonly property bool modActive: ctrlKey.mode || altKey.mode || (routeShift && shiftKey2.mode)
        functionKey: true
        noKeyEvent: modActive
        uppercased: false
        key: comboCode
        text: shiftKey2.mode && shiftText.length > 0 ? shiftText : baseText
        displayText: label.length > 0
                       ? (shiftKey2.mode && shiftText.length > 0 ? shiftText : label)
                       : (routeShift ? "" : text)
        onClicked: {
            if (modActive) {
                pcRoot.combo(comboCode, pcRoot.modsNow())
                pcRoot.releaseModes()
            } else {
                shiftKey2.mode = false
            }
        }
    }

    KeyboardRow {
        PCKey { comboCode: Qt.Key_Escape; label: "Esc" }
        PCKey { comboCode: Qt.Key_F1; label: "F1" }
        PCKey { comboCode: Qt.Key_F2; label: "F2" }
        PCKey { comboCode: Qt.Key_F3; label: "F3" }
        PCKey { comboCode: Qt.Key_F4; label: "F4" }
        PCKey { comboCode: Qt.Key_F5; label: "F5" }
        PCKey { comboCode: Qt.Key_F6; label: "F6" }
        PCKey { comboCode: Qt.Key_F7; label: "F7" }
        PCKey { comboCode: Qt.Key_F8; label: "F8" }
        PCKey { comboCode: Qt.Key_F9; label: "F9" }
        PCKey { comboCode: Qt.Key_F10; label: "F10" }
        PCKey { comboCode: Qt.Key_F11; label: "F11" }
        PCKey { comboCode: Qt.Key_F12; label: "F12" }
    }
    KeyboardRow {
        PCKey { comboCode: Qt.Key_QuoteLeft; baseText: "`"; shiftText: "~"; label: "`" }
        PCKey { comboCode: Qt.Key_1; baseText: "1"; shiftText: "!"; label: "1" }
        PCKey { comboCode: Qt.Key_2; baseText: "2"; shiftText: "@"; label: "2" }
        PCKey { comboCode: Qt.Key_3; baseText: "3"; shiftText: "#"; label: "3" }
        PCKey { comboCode: Qt.Key_4; baseText: "4"; shiftText: "$"; label: "4" }
        PCKey { comboCode: Qt.Key_5; baseText: "5"; shiftText: "%"; label: "5" }
        PCKey { comboCode: Qt.Key_6; baseText: "6"; shiftText: "^"; label: "6" }
        PCKey { comboCode: Qt.Key_7; baseText: "7"; shiftText: "&"; label: "7" }
        PCKey { comboCode: Qt.Key_8; baseText: "8"; shiftText: "*"; label: "8" }
        PCKey { comboCode: Qt.Key_9; baseText: "9"; shiftText: "("; label: "9" }
        PCKey { comboCode: Qt.Key_0; baseText: "0"; shiftText: ")"; label: "0" }
        PCKey { comboCode: Qt.Key_Minus; baseText: "-"; shiftText: "_"; label: "-" }
        PCKey { comboCode: Qt.Key_Equal; baseText: "="; shiftText: "+"; label: "=" }
        BackspaceKey {
            weight: 150
            noKeyEvent: ctrlKey.mode || altKey.mode
            onClicked: {
                if (ctrlKey.mode || altKey.mode) {
                    pcRoot.combo(Qt.Key_Backspace, pcRoot.modsNow())
                    pcRoot.releaseModes()
                }
            }
        }
        PCKey { comboCode: Qt.Key_Insert; label: "Ins"; routeShift: true }
        PCKey { comboCode: Qt.Key_Delete; label: "Del"; routeShift: true }
    }
    KeyboardRow {
        PCKey { comboCode: Qt.Key_Tab; label: "Tab"; routeShift: true; weight: 150 }
        PCKeep { upperKey: Qt.Key_Q }
        PCKeep { upperKey: Qt.Key_W }
        PCKeep { upperKey: Qt.Key_E }
        PCKeep { upperKey: Qt.Key_R }
        PCKeep { upperKey: Qt.Key_T }
        PCKeep { upperKey: Qt.Key_Y }
        PCKeep { upperKey: Qt.Key_U }
        PCKeep { upperKey: Qt.Key_I }
        PCKeep { upperKey: Qt.Key_O }
        PCKeep { upperKey: Qt.Key_P }
        PCKey { comboCode: Qt.Key_BracketLeft; baseText: "["; shiftText: "{"; label: "[" }
        PCKey { comboCode: Qt.Key_BracketRight; baseText: "]"; shiftText: "}"; label: "]" }
        PCKey { comboCode: Qt.Key_Backslash; baseText: "\\"; shiftText: "|"; label: "\\" }
        PCKey { comboCode: Qt.Key_Home; label: "Home"; routeShift: true }
        PCKey { comboCode: Qt.Key_PageUp; label: "Pgup"; routeShift: true }
    }
    KeyboardRow {
        ModeButton {
            id: shiftKey2
            displayText: "\u21e7"
            weight: 150
        }
        PCKeep { upperKey: Qt.Key_A }
        PCKeep { upperKey: Qt.Key_S }
        PCKeep { upperKey: Qt.Key_D }
        PCKeep { upperKey: Qt.Key_F }
        PCKeep { upperKey: Qt.Key_G }
        PCKeep { upperKey: Qt.Key_H }
        PCKeep { upperKey: Qt.Key_J }
        PCKeep { upperKey: Qt.Key_K }
        PCKeep { upperKey: Qt.Key_L }
        PCKey { comboCode: Qt.Key_Semicolon; baseText: ";"; shiftText: ":"; label: ";" }
        PCKey { comboCode: Qt.Key_Apostrophe; baseText: "'"; shiftText: "\""; label: "'" }
        EnterKey {
            weight: 150
            noKeyEvent: ctrlKey.mode || altKey.mode || shiftKey2.mode
            onClicked: {
                if (ctrlKey.mode || altKey.mode || shiftKey2.mode) {
                    pcRoot.combo(Qt.Key_Return, pcRoot.modsNow())
                    pcRoot.releaseModes()
                }
            }
        }
        PCKey { comboCode: Qt.Key_End; label: "End"; routeShift: true }
        PCKey { comboCode: Qt.Key_PageDown; label: "Pgdn"; routeShift: true }
    }
    KeyboardRow {
        ModeButton {
            id: ctrlKey
            displayText: "Ctrl"
            weight: 125
        }
        PCKeep { upperKey: Qt.Key_Z }
        PCKeep { upperKey: Qt.Key_X }
        PCKeep { upperKey: Qt.Key_C }
        PCKeep { upperKey: Qt.Key_V }
        PCKeep { upperKey: Qt.Key_B }
        PCKeep { upperKey: Qt.Key_N }
        PCKeep { upperKey: Qt.Key_M }
        PCKey { comboCode: Qt.Key_Comma; baseText: ","; shiftText: "<"; label: "," }
        PCKey { comboCode: Qt.Key_Period; baseText: "."; shiftText: ">"; label: "." }
        PCKey { comboCode: Qt.Key_Slash; baseText: "/"; shiftText: "?"; label: "/" }
        PCKey { comboCode: Qt.Key_Up; label: "\u2191"; routeShift: true }
    }
    KeyboardRow {
        ModeButton {
            id: altKey
            displayText: "Alt"
            weight: 125
        }
        PCKey { comboCode: Qt.Key_F13; label: "PC"; weight: 125 }
        SpaceKey {
            weight: 500
            noKeyEvent: ctrlKey.mode || altKey.mode
            onClicked: {
                if (ctrlKey.mode || altKey.mode) {
                    pcRoot.combo(Qt.Key_Space, pcRoot.modsNow())
                    pcRoot.releaseModes()
                }
            }
        }
        PCKey { comboCode: Qt.Key_Menu; label: "\u2630"; weight: 125 }
        PCKey { comboCode: Qt.Key_Left; label: "\u2190"; routeShift: true }
        PCKey { comboCode: Qt.Key_Down; label: "\u2193"; routeShift: true }
        PCKey { comboCode: Qt.Key_Right; label: "\u2192"; routeShift: true }
    }
}
