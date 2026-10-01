//! Windows keyboard events (set-1 scancode + extended flag + virtual key) -> Linux evdev keycodes.
//! For the base keyboard (scancodes 0x01..0x58) evdev codes equal XT set-1 scancodes.

const VK_PAUSE: u32 = 0x13;
const VK_NUMLOCK: u32 = 0x90;
const VK_SNAPSHOT: u32 = 0x2C;

pub fn to_evdev(scancode: u32, extended: bool, vk: u32) -> Option<u32> {
    match vk {
        VK_PAUSE => return Some(119),    // KEY_PAUSE (arrives as E1 1D 45)
        VK_NUMLOCK => return Some(69),   // KEY_NUMLOCK (reported with the extended flag)
        VK_SNAPSHOT => return Some(99),  // KEY_SYSRQ / Print
        _ => {}
    }

    if extended {
        return Some(match scancode {
            0x1C => 96,  // KEY_KPENTER
            0x1D => 97,  // KEY_RIGHTCTRL
            0x35 => 98,  // KEY_KPSLASH
            0x37 => 99,  // KEY_SYSRQ
            0x38 => 100, // KEY_RIGHTALT
            0x47 => 102, // KEY_HOME
            0x48 => 103, // KEY_UP
            0x49 => 104, // KEY_PAGEUP
            0x4B => 105, // KEY_LEFT
            0x4D => 106, // KEY_RIGHT
            0x4F => 107, // KEY_END
            0x50 => 108, // KEY_DOWN
            0x51 => 109, // KEY_PAGEDOWN
            0x52 => 110, // KEY_INSERT
            0x53 => 111, // KEY_DELETE
            0x5B => 125, // KEY_LEFTMETA (Win)
            0x5C => 126, // KEY_RIGHTMETA
            0x5D => 127, // KEY_COMPOSE (Menu)
            0x5E => 116, // KEY_POWER
            0x5F => 142, // KEY_SLEEP
            0x63 => 143, // KEY_WAKEUP
            0x10 => 165, // KEY_PREVIOUSSONG
            0x19 => 163, // KEY_NEXTSONG
            0x20 => 113, // KEY_MUTE
            0x21 => 140, // KEY_CALC
            0x22 => 164, // KEY_PLAYPAUSE
            0x24 => 166, // KEY_STOPCD
            0x2E => 114, // KEY_VOLUMEDOWN
            0x30 => 115, // KEY_VOLUMEUP
            0x32 => 172, // KEY_HOMEPAGE
            0x65 => 217, // KEY_SEARCH
            0x66 => 156, // KEY_BOOKMARKS
            0x67 => 173, // KEY_REFRESH
            0x68 => 128, // KEY_STOP
            0x69 => 159, // KEY_FORWARD
            0x6A => 158, // KEY_BACK
            0x6B => 144, // KEY_FILE (My Computer)
            0x6C => 155, // KEY_MAIL
            0x6D => 226, // KEY_MEDIA
            _ => return None,
        });
    }

    Some(match scancode {
        0x01..=0x58 => scancode, // identical block (Esc .. F12)
        0x64 => 183,             // KEY_F13
        0x65 => 184,             // KEY_F14
        0x66 => 185,             // KEY_F15
        0x67 => 186,             // KEY_F16
        0x68 => 187,             // KEY_F17
        0x69 => 188,             // KEY_F18
        0x6A => 189,             // KEY_F19
        0x6B => 190,             // KEY_F20
        0x6C => 191,             // KEY_F21
        0x6D => 192,             // KEY_F22
        0x6E => 193,             // KEY_F23 (Copilot key sends Shift+Win+F23)
        0x76 => 194,             // KEY_F24
        0x70 => 93,              // KEY_KATAKANAHIRAGANA
        0x73 => 89,              // KEY_RO
        0x79 => 92,              // KEY_HENKAN
        0x7B => 94,              // KEY_MUHENKAN
        0x7D => 124,             // KEY_YEN
        0x71 => 122,             // KEY_HANGEUL (Korean)
        0x72 => 123,             // KEY_HANJA
        0x59 => 117,             // KEY_KPEQUAL
        0x7E => 121,             // KEY_KPCOMMA
        _ => return None,
    })
}

// evdev pointer buttons
pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;
pub const BTN_SIDE: u32 = 0x113;
pub const BTN_EXTRA: u32 = 0x114;
