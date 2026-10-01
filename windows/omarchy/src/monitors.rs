//! Enumerate Windows monitors in physical pixels (the process is per-monitor DPI aware v2).

use crate::wdp::Monitor;
use windows::core::BOOL;
use windows::Win32::Foundation::{LPARAM, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};

pub fn enumerate() -> Vec<Monitor> {
    // testing: a layout read from a file (re-read on every call), so full-screen mode and display
    // changes can be exercised with small fake "monitors" without touching the real display settings
    if let Some(path) = std::env::var_os("OMARCHY_FAKE_MONITORS_FILE") {
        return std::fs::read_to_string(path).map(|s| parse_env(s.trim())).unwrap_or_default();
    }
    let mut handles: Vec<HMONITOR> = Vec::new();
    unsafe extern "system" fn cb(h: HMONITOR, _: HDC, _: *mut RECT, lp: LPARAM) -> BOOL {
        let v = &mut *(lp.0 as *mut Vec<HMONITOR>);
        v.push(h);
        BOOL(1)
    }
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(cb), LPARAM(&mut handles as *mut _ as isize));
    }

    let mut out = Vec::new();
    for (i, h) in handles.iter().enumerate() {
        unsafe {
            let mut info = MONITORINFOEXW::default();
            info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
            if !GetMonitorInfoW(*h, &mut info as *mut _ as *mut MONITORINFO).as_bool() {
                continue;
            }
            let r = info.monitorInfo.rcMonitor;
            let (mut dx, mut dy) = (96u32, 96u32);
            let _ = GetDpiForMonitor(*h, MDT_EFFECTIVE_DPI, &mut dx, &mut dy);

            let mut dm = DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() };
            let dev = windows::core::PCWSTR(info.szDevice.as_ptr());
            let hz = if EnumDisplaySettingsW(dev, ENUM_CURRENT_SETTINGS, &mut dm).as_bool() && dm.dmDisplayFrequency > 1 {
                dm.dmDisplayFrequency
            } else {
                60
            };
            let name = String::from_utf16_lossy(&info.szDevice).trim_end_matches('\0').trim_start_matches("\\\\.\\").to_string();
            out.push(Monitor {
                id: (i + 1) as u32,
                x: r.left,
                y: r.top,
                width: (r.right - r.left) as u32,
                height: (r.bottom - r.top) as u32,
                refresh_mhz: hz * 1000,
                scale_1000: dx * 1000 / 96,
                primary: info.monitorInfo.dwFlags & 1 != 0, // MONITORINFOF_PRIMARY
                name,
            });
        }
    }
    // primary first, so it becomes WSL-1 / the main Hyprland output (ids are stable after this: keep_ids)
    out.sort_by_key(|m| (!m.primary, m.x, m.y));
    for (i, m) in out.iter_mut().enumerate() {
        m.id = (i + 1) as u32;
    }
    out
}

/// After a display change: give monitors that are still there (same Windows device name) their old id,
/// so their outputs (and workspaces) stay put; new ones get ids no monitor of this session had.
pub fn keep_ids(previous: &[Monitor], mut now: Vec<Monitor>) -> Vec<Monitor> {
    for m in now.iter_mut() {
        m.id = previous.iter().find(|p| !p.name.is_empty() && p.name == m.name).map(|p| p.id).unwrap_or(0);
    }
    let mut next = 1;
    for i in 0..now.len() {
        if now[i].id != 0 {
            continue;
        }
        while previous.iter().chain(now.iter()).any(|m| m.id == next) {
            next += 1;
        }
        now[i].id = next;
    }
    now
}

/// "id:x:y:w:h:refresh_mhz:scale1000:primary:name;..." for WOMARCHY_MONITORS.
pub fn to_env(mons: &[Monitor]) -> String {
    mons.iter()
        .map(|m| format!("{}:{}:{}:{}:{}:{}:{}:{}:{}", m.id, m.x, m.y, m.width, m.height, m.refresh_mhz, m.scale_1000, m.primary as u8, m.name))
        .collect::<Vec<_>>()
        .join(";")
}

/// Inverse of `to_env`.
pub fn parse_env(spec: &str) -> Vec<Monitor> {
    spec.split(';')
        .filter_map(|m| {
            let f: Vec<&str> = m.split(':').collect();
            if f.len() < 8 {
                return None;
            }
            Some(Monitor {
                id: f[0].parse().ok()?,
                x: f[1].parse().ok()?,
                y: f[2].parse().ok()?,
                width: f[3].parse().ok()?,
                height: f[4].parse().ok()?,
                refresh_mhz: f[5].parse().ok()?,
                scale_1000: f[6].parse().ok()?,
                primary: f[7] == "1",
                name: f.get(8).unwrap_or(&"").to_string(),
            })
        })
        .collect()
}
