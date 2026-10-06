//! Enumerate Windows monitors in physical pixels (the process is per-monitor DPI aware v2).

use crate::wdp::Monitor;
use windows::core::BOOL;
use windows::Win32::Foundation::{LPARAM, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};

/// A Windows monitor as found, before OMARCHY_SKIP_MONITORS is applied.
pub struct Seen {
    pub monitor: Monitor,
    /// The monitor's device interface path (e.g. `\\?\DISPLAY#ABC1234#5&1a2b3c4&0&UID4100#{...}`):
    /// stable across reboots for the same monitor on the same port, unlike DISPLAYn.
    pub device: String,
    pub skipped: bool,
}

/// The monitors Omarchy gets: every Windows monitor except those OMARCHY_SKIP_MONITORS leaves to
/// Windows. Ids are 1..n over the monitors kept, Omarchy's main monitor first (see `omarchy_order`).
pub fn enumerate() -> Vec<Monitor> {
    omarchy_order(survey(), &rules("OMARCHY_MAIN_MONITOR"))
}

/// The kept monitors in Omarchy's order, numbered 1..n: the first becomes WSL-1, the main Hyprland
/// output (workspace 1). That is the monitor OMARCHY_MAIN_MONITOR names, or else Windows' primary
/// (which `survey` already sorts first); `primary` is set on it alone.
fn omarchy_order(seen: Vec<Seen>, main: &[String]) -> Vec<Monitor> {
    let mut kept: Vec<Seen> = seen.into_iter().filter(|s| !s.skipped).collect();
    if let Some(i) = kept.iter().position(|s| matches(main, &s.monitor.name, &s.device)) {
        let chosen = kept.remove(i);
        kept.insert(0, chosen);
        for (j, s) in kept.iter_mut().enumerate() {
            s.monitor.primary = j == 0;
        }
    }
    let mut out: Vec<Monitor> = kept.into_iter().map(|s| s.monitor).collect();
    for (i, m) in out.iter_mut().enumerate() {
        m.id = (i + 1) as u32;
    }
    out
}

/// A monitor list from the environment: OMARCHY_SKIP_MONITORS (monitors left to Windows) or
/// OMARCHY_MAIN_MONITOR (Omarchy's main monitor), separated by commas, semicolons or spaces. Each
/// entry is a Windows display name (`DISPLAY4`, exact) or part of a monitor's device path (`UID4100`,
/// or a model code such as `ABC1234`), case-insensitive. `omarchy status` lists both for every monitor.
fn rules(var: &str) -> Vec<String> {
    std::env::var(var)
        .unwrap_or_default()
        .split([',', ';', ' '])
        .map(|r| r.trim().trim_start_matches("\\\\.\\").to_ascii_uppercase())
        .filter(|r| !r.is_empty())
        .collect()
}

fn matches(rules: &[String], name: &str, device: &str) -> bool {
    let (name, device) = (name.to_ascii_uppercase(), device.to_ascii_uppercase());
    rules.iter().any(|r| *r == name || (!device.is_empty() && device.contains(r.as_str())))
}

/// Every Windows monitor, marked with whether OMARCHY_SKIP_MONITORS leaves it to Windows. If the rules
/// would leave Omarchy no monitor at all, they are ignored (with a warning).
pub fn survey() -> Vec<Seen> {
    let rules = rules("OMARCHY_SKIP_MONITORS");
    let mut seen: Vec<Seen> = enumerate_all()
        .into_iter()
        .map(|(monitor, device)| {
            let skipped = matches(&rules, &monitor.name, &device);
            Seen { monitor, device, skipped }
        })
        .collect();
    if !seen.is_empty() && seen.iter().all(|s| s.skipped) {
        eprintln!("[omarchy] OMARCHY_SKIP_MONITORS matches every monitor; ignoring it");
        for s in seen.iter_mut() {
            s.skipped = false;
        }
    }
    seen
}

/// The monitor's device interface path, or "" when Windows doesn't report one.
fn device_path(gdi_name: &[u16]) -> String {
    let mut dd = DISPLAY_DEVICEW { cb: std::mem::size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
    // flag 1 = EDD_GET_DEVICE_INTERFACE_NAME: DeviceID becomes the monitor's interface path
    if unsafe { EnumDisplayDevicesW(windows::core::PCWSTR(gdi_name.as_ptr()), 0, &mut dd, 1) }.as_bool() {
        String::from_utf16_lossy(&dd.DeviceID).trim_end_matches('\0').to_string()
    } else {
        String::new()
    }
}

fn enumerate_all() -> Vec<(Monitor, String)> {
    // testing: a layout read from a file (re-read on every call), so full-screen mode and display
    // changes can be exercised with small fake "monitors" without touching the real display settings
    if let Some(path) = std::env::var_os("OMARCHY_FAKE_MONITORS_FILE") {
        let mons = std::fs::read_to_string(path).map(|s| parse_env(s.trim())).unwrap_or_default();
        return mons.into_iter().map(|m| (m, String::new())).collect();
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
            let device = device_path(&info.szDevice);
            out.push((
                Monitor {
                    id: (i + 1) as u32,
                    x: r.left,
                    y: r.top,
                    width: (r.right - r.left) as u32,
                    height: (r.bottom - r.top) as u32,
                    refresh_mhz: hz * 1000,
                    scale_1000: dx * 1000 / 96,
                    primary: info.monitorInfo.dwFlags & 1 != 0, // MONITORINFOF_PRIMARY
                    name,
                },
                device,
            ));
        }
    }
    // primary first, so it becomes WSL-1 / the main Hyprland output (ids are stable after this: keep_ids)
    out.sort_by_key(|(m, _)| (!m.primary, m.x, m.y));
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

#[cfg(test)]
mod tests {
    use super::*;

    fn mon(id: u32, name: &str, x: i32) -> Monitor {
        Monitor { id, x, y: 0, width: 3840, height: 2160, refresh_mhz: 60000, scale_1000: 1500, primary: x == 0, name: name.into() }
    }

    #[test]
    fn ids_follow_monitors_by_name() {
        let before = vec![mon(1, "DISPLAY1", 0), mon(2, "DISPLAY2", 3840), mon(3, "DISPLAY3", 7680)];
        // DISPLAY2 unplugged, a new one plugged in, the order changed
        let now = keep_ids(&before, vec![mon(0, "DISPLAY3", 0), mon(0, "DISPLAY4", 3840), mon(0, "DISPLAY1", 7680)]);
        let ids: Vec<(String, u32)> = now.iter().map(|m| (m.name.clone(), m.id)).collect();
        assert_eq!(ids[0], ("DISPLAY3".into(), 3));
        assert_eq!(ids[2], ("DISPLAY1".into(), 1));
        // the new monitor gets an id nobody had: not DISPLAY2's 2, which may still be on its way out
        assert_eq!(ids[1].1, 4);
    }

    #[test]
    fn skip_rules_match_display_names_exactly_and_device_paths_in_part() {
        let rules = vec!["DISPLAY4".to_string(), "XYZ0001".to_string()];
        let side_panel = r"\\?\DISPLAY#XYZ0001#5&2b3c4d5&0&UID512#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}";
        let wide = r"\\?\display#abc1234#5&1a2b3c4&0&uid4100#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}";
        assert!(matches(&rules, "DISPLAY4", wide));
        assert!(matches(&rules, "display4", ""));
        assert!(!matches(&rules, "DISPLAY40", ""));
        assert!(matches(&rules, "DISPLAY5", side_panel));
        assert!(!matches(&rules, "DISPLAY3", wide));
        assert!(matches(&["UID4100".to_string()], "DISPLAY9", wide));
        assert!(!matches(&[], "DISPLAY4", wide));
    }

    #[test]
    fn main_monitor_goes_first_and_alone_is_primary() {
        // Windows keeps its primary (DISPLAY3) and a small side panel (DISPLAY5); Omarchy's main is DISPLAY4
        let seen = |name: &str, uid: &str, x: i32, primary: bool, skipped: bool| Seen {
            monitor: Monitor { primary, ..mon(0, name, x) },
            device: format!(r"\\?\DISPLAY#ABC1234#5&1a2b3c4&0&{uid}#{{e6f07b5f}}"),
            skipped,
        };
        let layout = || {
            vec![
                seen("DISPLAY3", "UID4100", 0, true, true),
                seen("DISPLAY2", "UID4101", -1440, false, false),
                seen("DISPLAY4", "UID4102", 0, false, false),
                seen("DISPLAY5", "UID512", 2560, false, true),
                seen("DISPLAY1", "UID4103", 3840, false, false),
            ]
        };
        let order = |mons: Vec<Monitor>| mons.iter().map(|m| (m.id, m.name.clone(), m.primary)).collect::<Vec<_>>();
        assert_eq!(
            order(omarchy_order(layout(), &["UID4102".to_string()])),
            vec![(1, "DISPLAY4".into(), true), (2, "DISPLAY2".into(), false), (3, "DISPLAY1".into(), false)]
        );
        // no (or no matching) OMARCHY_MAIN_MONITOR: the survey's order stands
        assert_eq!(
            order(omarchy_order(layout(), &[])),
            vec![(1, "DISPLAY2".into(), false), (2, "DISPLAY4".into(), false), (3, "DISPLAY1".into(), false)]
        );
    }

    #[test]
    fn env_round_trip() {
        let mons = vec![mon(1, "DISPLAY1", 0), mon(2, "", -1920)];
        assert_eq!(parse_env(&to_env(&mons)), mons);
        assert!(parse_env("garbage;1:2").is_empty());
    }
}
