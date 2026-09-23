// Copyright (C) 2026 Yizhou — piano-patch full-size PC layout (v5)
// SPDX-License-Identifier: GPL-3.0-or-later
// 全尺寸 PC 布局。进入/退出：主键盘 "PC" 键（Qt.Key_F13 + Keyboard.qml pcMode 补丁）。
// v5：Ctrl/Alt/Shift 用 ModeKey 自身 mode 作唯一状态源（点亮状态可见、可再按取消）；
//     组合键经 pc-keyd 守护（localhost:48222）走 /dev/uinput 注入真实按键序列
//     （input-method-v1 的 send_key 协议不带 modifiers，必须绕道）；
//     本页强制英文（inputMode: Latin）。

import QtQuick
import QtQuick.Layouts
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

KeyboardLayout {
    id: pcRoot
    keyWeight: 100
    inputMode: InputEngine.InputMode.Latin

    function combo(upperKey, mods) {
        var x = new XMLHttpRequest()
        x.open("GET", "http://127.0.0.1:48222/combo?key=" + upperKey + "&mods=" + mods)
        x.send()
    }

    // 字母键：按住 Ctrl/Alt 时改走 uinput 组合通道；Shift 只放大写字母且一击复位
    component PCKeep: Key {
        property int upperKey
        noKeyEvent: ctrlKey.mode || altKey.mode
        key: shiftKey2.mode ? upperKey : (upperKey + 32)
        text: shiftKey2.mode ? String.fromCharCode(upperKey) : String.fromCharCode(upperKey + 32)
        onClicked: {
            if (ctrlKey.mode || altKey.mode) {
                var mods = []
                if (ctrlKey.mode) mods.push("ctrl")
                if (altKey.mode) mods.push("alt")
                pcRoot.combo(upperKey, mods.join(","))
                ctrlKey.mode = false
                altKey.mode = false
            }
            shiftKey2.mode = false
        }
    }

    KeyboardRow {
        Key { key: Qt.Key_Escape; displayText: "Esc"; functionKey: true }
        Key { key: Qt.Key_F1; displayText: "F1"; functionKey: true }
        Key { key: Qt.Key_F2; displayText: "F2"; functionKey: true }
        Key { key: Qt.Key_F3; displayText: "F3"; functionKey: true }
        Key { key: Qt.Key_F4; displayText: "F4"; functionKey: true }
        Key { key: Qt.Key_F5; displayText: "F5"; functionKey: true }
        Key { key: Qt.Key_F6; displayText: "F6"; functionKey: true }
        Key { key: Qt.Key_F7; displayText: "F7"; functionKey: true }
        Key { key: Qt.Key_F8; displayText: "F8"; functionKey: true }
        Key { key: Qt.Key_F9; displayText: "F9"; functionKey: true }
        Key { key: Qt.Key_F10; displayText: "F10"; functionKey: true }
        Key { key: Qt.Key_F11; displayText: "F11"; functionKey: true }
        Key { key: Qt.Key_F12; displayText: "F12"; functionKey: true }
    }
    KeyboardRow {
        Key { key: Qt.Key_QuoteLeft; text: "`" }
        Key { key: Qt.Key_1; text: "1" }
        Key { key: Qt.Key_2; text: "2" }
        Key { key: Qt.Key_3; text: "3" }
        Key { key: Qt.Key_4; text: "4" }
        Key { key: Qt.Key_5; text: "5" }
        Key { key: Qt.Key_6; text: "6" }
        Key { key: Qt.Key_7; text: "7" }
        Key { key: Qt.Key_8; text: "8" }
        Key { key: Qt.Key_9; text: "9" }
        Key { key: Qt.Key_0; text: "0" }
        Key { key: Qt.Key_Minus; text: "-" }
        Key { key: Qt.Key_Equal; text: "=" }
        BackspaceKey { weight: 150 }
        Key { key: Qt.Key_Insert; displayText: "Ins"; functionKey: true }
        Key { key: Qt.Key_Delete; displayText: "Del"; functionKey: true }
    }
    KeyboardRow {
        Key { key: Qt.Key_Tab; displayText: "Tab"; functionKey: true; weight: 150 }
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
        Key { key: Qt.Key_BracketLeft; text: "[" }
        Key { key: Qt.Key_BracketRight; text: "]" }
        Key { key: Qt.Key_Backslash; text: "\\" }
        Key { key: Qt.Key_Home; displayText: "Home"; functionKey: true }
        Key { key: Qt.Key_PageUp; displayText: "PgUp"; functionKey: true }
    }
    KeyboardRow {
        ModeKey {
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
        Key { key: Qt.Key_Semicolon; text: ";" }
        Key { key: Qt.Key_Apostrophe; text: "'" }
        EnterKey { weight: 150 }
        Key { key: Qt.Key_End; displayText: "End"; functionKey: true }
        Key { key: Qt.Key_PageDown; displayText: "PgDn"; functionKey: true }
    }
    KeyboardRow {
        ModeKey {
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
        Key { key: Qt.Key_Comma; text: "," }
        Key { key: Qt.Key_Period; text: "." }
        Key { key: Qt.Key_Slash; text: "/" }
        Key { key: Qt.Key_Up; displayText: "\u2191"; functionKey: true }
    }
    KeyboardRow {
        ModeKey {
            id: altKey
            displayText: "Alt"
            weight: 125
        }
        Key { key: Qt.Key_F13; displayText: "PC"; functionKey: true; weight: 125 }
        SpaceKey { weight: 500 }
        Key { key: Qt.Key_Menu; displayText: "\u2630"; functionKey: true; weight: 125 }
        Key { key: Qt.Key_Left; displayText: "\u2190"; functionKey: true }
        Key { key: Qt.Key_Down; displayText: "\u2193"; functionKey: true }
        Key { key: Qt.Key_Right; displayText: "\u2192"; functionKey: true }
    }
}
