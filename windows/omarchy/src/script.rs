//! `--input-script FILE`: drive the session for tests. One command per line, `#` comments:
//!
//!   sleep MS                 wait
//!   key COMBO                press and release a chord, e.g. `super+Return`, `ctrl+shift+t`, `F11`
//!   type TEXT                type text (US layout: letters, digits, space, ASCII punctuation)
//!   move X Y [OUTPUT]        pointer to pixel coordinates (or percentages, e.g. `50% 50%`) on an
//!                            output (default: the first), moving the Windows cursor there too;
//!                            Hyprland focuses the monitor under it
//!   click [left|right|middle]
//!   scroll N                 wheel N notches (positive = down)
//!   shot PATH                screenshot inside the session (grim): a Linux path (/...), or a path
//!                            relative to `--shot-dir` (default: the current directory) on Windows
//!   quit                     end the session like closing the window
//!
//! Screenshots come from the compositor itself, so they show exactly what Hyprland composited.

use crate::keymap;
use crate::viewer::{now_ms, send};
use crate::wdp;
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::Duration;
use windows::Win32::Foundation::{HWND, POINT};
use windows::Win32::Graphics::Gdi::ClientToScreen;
use windows::Win32::UI::WindowsAndMessaging::SetCursorPos;

/// What `--input-script` runs and where.
#[derive(Clone)]
pub struct Options {
    pub file: String,
    pub distro: String,
    pub user: Option<String>,
    /// Windows directory for relative `shot` paths (default: the current directory)
    pub shot_dir: Option<String>,
}

struct Target {
    opts: Options,
    output_id: u32,
}

/// `C:\a\b` -> `/mnt/c/a/b` (WSL's default automount); None for paths without a drive letter.
fn wsl_path(p: &std::path::Path) -> Option<String> {
    let s = p.to_str()?.trim_start_matches(r"\\?\");
    let mut chars = s.chars();
    let (drive, colon) = (chars.next()?, chars.next()?);
    if !drive.is_ascii_alphabetic() || colon != ':' {
        return None;
    }
    Some(format!("/mnt/{}{}", drive.to_ascii_lowercase(), s[2..].replace('\\', "/")))
}

fn key(code: u32, down: bool) {
    send(wdp::key(now_ms(), code, down));
}

fn tap(code: u32) {
    key(code, true);
    sleep(Duration::from_millis(20));
    key(code, false);
    sleep(Duration::from_millis(20));
}

/// evdev code for a key name (case-insensitive for named keys).
/// evdev codes of a..z (US layout positions)
const LETTERS: [u32; 26] = [30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44];

fn key_code(name: &str) -> Option<u32> {
    let lower = name.to_ascii_lowercase();
    if lower.len() == 1 {
        let c = lower.chars().next()?;
        return match c {
            'a'..='z' => Some(LETTERS[(c as u8 - b'a') as usize]),
            '1'..='9' => Some(2 + (c as u8 - b'1') as u32),
            '0' => Some(11),
            _ => char_code(c).map(|(k, _)| k),
        };
    }
    if let Some(n) = lower.strip_prefix('f').and_then(|n| n.parse::<u32>().ok()) {
        return match n {
            1..=10 => Some(58 + n),
            11 => Some(87),
            12 => Some(88),
            _ => None,
        };
    }
    Some(match lower.as_str() {
        "super" | "win" | "meta" => 125,
        "ctrl" | "control" => 29,
        "alt" => 56,
        "shift" => 42,
        "return" | "enter" => 28,
        "space" => 57,
        "escape" | "esc" => 1,
        "tab" => 15,
        "backspace" => 14,
        "delete" => 111,
        "up" => 103,
        "down" => 108,
        "left" => 105,
        "right" => 106,
        "home" => 102,
        "end" => 107,
        "pageup" => 104,
        "pagedown" => 109,
        "print" => 99,
        "minus" => 12,
        "equal" => 13,
        "comma" => 51,
        "period" => 52,
        "slash" => 53,
        _ => return None,
    })
}

/// (evdev code, needs shift) for a printable ASCII character on a US layout.
fn char_code(c: char) -> Option<(u32, bool)> {
    Some(match c {
        'a'..='z' => (LETTERS[(c as u8 - b'a') as usize], false),
        'A'..='Z' => (LETTERS[(c as u8 - b'A') as usize], true),
        '1'..='9' => (2 + (c as u8 - b'1') as u32, false),
        '0' => (11, false),
        ' ' => (57, false),
        '-' => (12, false),
        '_' => (12, true),
        '=' => (13, false),
        '+' => (13, true),
        '[' => (26, false),
        '{' => (26, true),
        ']' => (27, false),
        '}' => (27, true),
        ';' => (39, false),
        ':' => (39, true),
        '\'' => (40, false),
        '"' => (40, true),
        '`' => (41, false),
        '~' => (41, true),
        '\\' => (43, false),
        '|' => (43, true),
        ',' => (51, false),
        '<' => (51, true),
        '.' => (52, false),
        '>' => (52, true),
        '/' => (53, false),
        '?' => (53, true),
        '!' => (2, true),
        '@' => (3, true),
        '#' => (4, true),
        '$' => (5, true),
        '%' => (6, true),
        '^' => (7, true),
        '&' => (8, true),
        '*' => (9, true),
        '(' => (10, true),
        ')' => (11, true),
        _ => return None,
    })
}

fn chord(combo: &str) -> bool {
    let codes: Option<Vec<u32>> = combo.split('+').map(|k| key_code(k.trim())).collect();
    let Some(codes) = codes else {
        eprintln!("[omarchy] script: unknown key in {}", combo);
        return false;
    };
    for &c in &codes {
        key(c, true);
        sleep(Duration::from_millis(20));
    }
    for &c in codes.iter().rev() {
        key(c, false);
        sleep(Duration::from_millis(20));
    }
    true
}

fn type_text(text: &str) {
    for c in text.chars() {
        match char_code(c) {
            Some((code, shift)) => {
                if shift {
                    key(42, true);
                }
                tap(code);
                if shift {
                    key(42, false);
                }
            }
            None => eprintln!("[omarchy] script: can't type {:?}", c),
        }
    }
}

fn screenshot(t: &Target, path: &str) {
    let linux_path = if path.starts_with('/') {
        path.to_string()
    } else {
        let dir = t.opts.shot_dir.clone().map(std::path::PathBuf::from).unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
        let dir = if dir.is_absolute() { dir } else { std::env::current_dir().unwrap_or_default().join(dir) };
        let file = dir.join(path);
        if let Some(parent) = file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match wsl_path(&file) {
            Some(p) => p,
            None => {
                eprintln!("[omarchy] script: shot {}: not on a drive WSL mounts", file.display());
                return;
            }
        }
    };
    let path = linux_path.as_str();
    let sh = format!(
        "d=$(systemctl --user show-environment | sed -n 's/^WAYLAND_DISPLAY=//p'); [ -n \"$d\" ] && WAYLAND_DISPLAY=$d grim '{}'",
        path.replace('\'', "")
    );
    let mut cmd = Command::new("wsl.exe");
    cmd.arg("-d").arg(&t.opts.distro);
    if let Some(u) = &t.opts.user {
        cmd.arg("-u").arg(u);
    }
    let ok = cmd.args(["--exec", "sh", "-c", &sh]).stdin(Stdio::null()).status().map(|s| s.success()).unwrap_or(false);
    eprintln!("[omarchy] script: shot {} {}", path, if ok { "ok" } else { "FAILED" });
}

pub fn run(opts: Options, output_id: u32) {
    let Ok(text) = std::fs::read_to_string(&opts.file) else {
        eprintln!("[omarchy] script: cannot read {}", opts.file);
        return;
    };
    let t = Target { opts, output_id };
    for (n, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (cmd, arg) = line.split_once(' ').map(|(c, a)| (c, a.trim())).unwrap_or((line, ""));
        eprintln!("[omarchy] script: {}", line);
        match cmd {
            "sleep" => sleep(Duration::from_millis(arg.parse().unwrap_or(0))),
            "key" => {
                chord(arg);
            }
            "type" => type_text(arg),
            "move" => {
                let parts: Vec<&str> = arg.split_whitespace().collect();
                let output = parts.get(2).and_then(|v| v.parse().ok()).unwrap_or(t.output_id);
                let surface = crate::viewer::surfaces().into_iter().find(|s| s.output_id == output);
                let size = surface.map(|s| (s.width, s.height));
                let coord = |v: Option<&&str>, extent: Option<u32>| -> Option<f64> {
                    let v = v?;
                    match v.strip_suffix('%') {
                        Some(pct) => Some(pct.parse::<f64>().ok()? / 100.0 * extent? as f64),
                        None => v.parse().ok(),
                    }
                };
                match (coord(parts.first(), size.map(|s| s.0)), coord(parts.get(1), size.map(|s| s.1))) {
                    (Some(x), Some(y)) => {
                        // Move the Windows cursor there too, as a real mouse would: otherwise the next
                        // mouse move Windows synthesises (e.g. when a window changes) puts the pointer
                        // back where the Windows cursor is.
                        if let Some(s) = surface {
                            let mut pt = POINT { x: x as i32, y: y as i32 };
                            unsafe {
                                let _ = ClientToScreen(HWND(s.hwnd as *mut _), &mut pt);
                                let _ = SetCursorPos(pt.x, pt.y);
                            }
                        }
                        send(wdp::pointer_abs_frame(now_ms(), output, x, y));
                    }
                    _ => eprintln!("[omarchy] script: line {}: bad move (output {} known: {})", n + 1, output, size.is_some()),
                }
            }
            "click" => {
                let b = match arg {
                    "right" => keymap::BTN_RIGHT,
                    "middle" => keymap::BTN_MIDDLE,
                    _ => keymap::BTN_LEFT,
                };
                send(wdp::pointer_button(now_ms(), b, true));
                sleep(Duration::from_millis(40));
                send(wdp::pointer_button(now_ms(), b, false));
            }
            "scroll" => {
                let n: i32 = arg.parse().unwrap_or(1);
                send(wdp::pointer_axis(now_ms(), 0, 15.0 * n as f64, 120 * n));
            }
            "shot" => screenshot(&t, arg),
            "quit" => {
                send(wdp::quit());
                return;
            }
            _ => eprintln!("[omarchy] script: line {}: unknown command {}", n + 1, cmd),
        }
    }
    eprintln!("[omarchy] script: done");
}
