//! Viewer windows (one per compositor output), D3D11 presentation and input capture.
//!
//! Threads:
//!  * UI thread: owns the windows and the message loop: mouse input, cursor shapes, display changes.
//!  * keyboard-hook thread: the low-level keyboard hook with its own message loop. A hook that doesn't
//!    answer within about a second is silently removed by Windows, so it shares a thread with nothing.
//!  * input sender: writes input messages to the socket, so neither of the above ever blocks on it.
//!  * reader: reads the compositor's messages and routes each frame to its output's presenter.
//!  * one presenter per output: its own D3D11 device and flip-model swapchain; it copies the damaged
//!    rectangles (from the shared-memory section, or inline pixels) into a texture, presents and then
//!    acknowledges. Outputs present independently, so one monitor's refresh never holds back another.

use crate::keymap;
use crate::net::Conn;
use crate::wdp::{self, Reader};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use windows::core::{w, Interface, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::*;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

/// Thread messages to the UI thread (posted with PostThreadMessageW, handled in run_message_loop).
const WM_APP_CURSOR: u32 = WM_APP + 1; // a new cursor image arrived
const WM_APP_MINIMIZE: u32 = WM_APP + 2; // Ctrl+Alt+End: minimise the desktop

/// One viewer window.
#[derive(Clone, Copy, Debug)]
pub struct Surface {
    pub output_id: u32,
    pub hwnd: isize,
    pub width: u32,
    pub height: u32,
}

fn hwnd(h: isize) -> HWND {
    HWND(h as *mut _)
}

static SURFACES: Mutex<Vec<Surface>> = Mutex::new(Vec::new());
/// Input goes to the session only while this is set (authenticated, compositor alive); otherwise keys
/// are left to Windows, so a starting or dead desktop never swallows them.
static LIVE: AtomicBool = AtomicBool::new(false);
static INPUT: Mutex<Option<mpsc::Sender<Vec<u8>>>> = Mutex::new(None);
static PRESSED: Mutex<BTreeSet<u32>> = Mutex::new(BTreeSet::new()); // evdev keys held down
static BUTTONS: AtomicU32 = AtomicU32::new(0); // mouse buttons held down (bit per button)
static MAIN_THREAD: AtomicU32 = AtomicU32::new(0);
static HOOK_THREAD: AtomicU32 = AtomicU32::new(0);
static EPOCH: OnceLock<Instant> = OnceLock::new();
static QUIT_SENT: AtomicBool = AtomicBool::new(false);
/// Windows still showing "Starting Omarchy…" (no swapchain yet).
static SPLASH_DONE: Mutex<BTreeSet<isize>> = Mutex::new(BTreeSet::new());
static MINIMIZED: Mutex<BTreeSet<isize>> = Mutex::new(BTreeSet::new());
/// Called (on the UI thread, debounced) after Windows' display configuration changed.
static ON_DISPLAY_CHANGE: OnceLock<Box<dyn Fn() + Send + Sync>> = OnceLock::new();
static DISPLAY_TIMER: AtomicUsize = AtomicUsize::new(0);

struct CursorImage {
    width: u32,
    height: u32,
    hot_x: i32,
    hot_y: i32,
    argb: Vec<u8>,
}

struct CursorState {
    current: isize, // HCURSOR, 0 = the default arrow; created and destroyed on the UI thread only
    hidden: bool,
    pending: Option<CursorImage>,
}

static CURSOR: Mutex<CursorState> = Mutex::new(CursorState { current: 0, hidden: false, pending: None });

// stats (--stats)
static STAT_FRAMES: AtomicU64 = AtomicU64::new(0);
static STAT_PIXELS: AtomicU64 = AtomicU64::new(0);

pub fn on_display_change(f: Box<dyn Fn() + Send + Sync>) {
    let _ = ON_DISPLAY_CHANGE.set(f);
}

/// Route input to the session from now on (after the compositor proved itself).
pub fn start_input(conn: Conn) {
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    *INPUT.lock().unwrap() = Some(tx);
    thread::spawn(move || {
        for msg in rx {
            if conn.send_msg(&msg).is_err() {
                break;
            }
        }
    });
    LIVE.store(true, Ordering::SeqCst);
}

fn stop_input() {
    LIVE.store(false, Ordering::SeqCst);
    PRESSED.lock().unwrap().clear();
    *INPUT.lock().unwrap() = None;
}

/// Queue a message for the compositor (dropped when no session is live).
pub fn send(msg: Vec<u8>) {
    if let Some(tx) = INPUT.lock().unwrap().as_ref() {
        let _ = tx.send(msg);
    }
}

pub fn now_ms() -> u32 {
    EPOCH.get_or_init(Instant::now).elapsed().as_millis() as u32
}

pub fn surfaces() -> Vec<Surface> {
    SURFACES.lock().unwrap().clone()
}

fn surface_for(h: HWND) -> Option<Surface> {
    SURFACES.lock().unwrap().iter().copied().find(|s| s.hwnd == h.0 as isize)
}

fn surface_by_id(id: u32) -> Option<Surface> {
    SURFACES.lock().unwrap().iter().copied().find(|s| s.output_id == id)
}

fn is_ours(h: HWND) -> bool {
    !h.is_invalid() && surface_for(h).is_some()
}

fn release_all_keys() {
    let keys = std::mem::take(&mut *PRESSED.lock().unwrap());
    for k in keys {
        send(wdp::key(now_ms(), k, false));
    }
}

// ------------------------------------------------------------------ windows

pub fn create_windows(monitors: &[wdp::Monitor], windowed: bool) {
    unsafe {
        MAIN_THREAD.store(GetCurrentThreadId(), Ordering::SeqCst);
        let hinst = GetModuleHandleW(None).unwrap();
        let class = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(wndproc),
            hInstance: hinst.into(),
            hIcon: app_icon(GetSystemMetrics(SM_CXICON)),
            hIconSm: app_icon(GetSystemMetrics(SM_CXSMICON)),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(GetStockObject(BLACK_BRUSH).0),
            lpszClassName: w!("OmarchyViewer"),
            ..Default::default()
        };
        RegisterClassExW(&class);

        for (i, m) in monitors.iter().enumerate() {
            if let Some(s) = create_window(i, m, windowed) {
                SURFACES.lock().unwrap().push(s);
            }
        }
        if let Some(first) = surfaces().first() {
            let _ = SetForegroundWindow(hwnd(first.hwnd));
        }
    }
}

/// The Omarchy icon (taskbar, Alt+Tab) from the embedded .ico: the entry closest to `size` pixels.
fn app_icon(size: i32) -> HICON {
    let ico = crate::install::ICON;
    let u16_at = |o: usize| ico.get(o..o + 2).map(|b| u16::from_le_bytes([b[0], b[1]]) as usize);
    let u32_at = |o: usize| ico.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize);
    let count = u16_at(4).unwrap_or(0);
    let mut best: Option<(usize, usize, i32)> = None; // (offset, len, width)
    for i in 0..count {
        let e = 6 + i * 16;
        let Some(&w) = ico.get(e) else { break };
        let w = if w == 0 { 256 } else { w as i32 };
        let (Some(len), Some(off)) = (u32_at(e + 8), u32_at(e + 12)) else { break };
        let better = match best {
            None => true,
            Some((_, _, bw)) => (w >= size && (bw < size || w < bw)) || (bw < size && w > bw),
        };
        if better && off + len <= ico.len() {
            best = Some((off, len, w));
        }
    }
    let Some((off, len, _)) = best else { return HICON::default() };
    unsafe { CreateIconFromResourceEx(&ico[off..off + len], true, 0x00030000, size, size, LR_DEFAULTCOLOR).unwrap_or_default() }
}

fn create_window(i: usize, m: &wdp::Monitor, windowed: bool) -> Option<Surface> {
    let (style, ex, rect) = if windowed {
        let mut r = RECT { left: 0, top: 0, right: m.width as i32, bottom: m.height as i32 };
        let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_VISIBLE;
        unsafe {
            let _ = AdjustWindowRectEx(&mut r, style, false, WINDOW_EX_STYLE(0));
        }
        let (ow, oh) = (r.right - r.left, r.bottom - r.top);
        let left = 100 + i as i32 * (ow + 8);
        (style, WINDOW_EX_STYLE(0), RECT { left, top: 100, right: left + ow, bottom: 100 + oh })
    } else {
        let r = RECT { left: m.x, top: m.y, right: m.x + m.width as i32, bottom: m.y + m.height as i32 };
        (WS_POPUP | WS_VISIBLE, WS_EX_APPWINDOW, r)
    };
    let title: Vec<u16> = format!("Omarchy \u{2014} WSL-{}\0", m.id).encode_utf16().collect();
    let h = unsafe {
        CreateWindowExW(
            ex,
            w!("OmarchyViewer"),
            PCWSTR(title.as_ptr()),
            style,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            None,
            None,
            Some(GetModuleHandleW(None).ok()?.into()),
            None,
        )
    };
    match h {
        Ok(h) => Some(Surface { output_id: m.id, hwnd: h.0 as isize, width: m.width, height: m.height }),
        Err(e) => {
            eprintln!("[omarchy] cannot create the window for monitor {}: {}", m.id, e);
            None
        }
    }
}

/// Make the (full-screen) windows match a new monitor layout: move/resize the ones whose output
/// survives, close the others, open windows for new outputs. Presenters follow SURFACES.
pub fn reconcile_windows(monitors: &[wdp::Monitor]) {
    // window calls re-enter wndproc (which reads SURFACES), so never hold the lock across them
    let current = surfaces();
    for s in current.iter().filter(|s| !monitors.iter().any(|m| m.id == s.output_id)) {
        unsafe {
            let _ = DestroyWindow(hwnd(s.hwnd));
        }
    }
    let mut next = Vec::new();
    for (i, m) in monitors.iter().enumerate() {
        if let Some(s) = current.iter().find(|s| s.output_id == m.id) {
            unsafe {
                let _ = SetWindowPos(hwnd(s.hwnd), None, m.x, m.y, m.width as i32, m.height as i32, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            next.push(Surface { width: m.width, height: m.height, ..*s });
        } else if let Some(s) = create_window(i, m, false) {
            next.push(s);
        }
    }
    *SURFACES.lock().unwrap() = next;
}

unsafe extern "system" fn display_settled(_: HWND, _: u32, id: usize, _: u32) {
    let _ = KillTimer(None, id);
    DISPLAY_TIMER.store(0, Ordering::SeqCst);
    if let Some(f) = ON_DISPLAY_CHANGE.get() {
        f();
    }
}

/// Display changes arrive as bursts (every window, every monitor): act once things settle.
fn display_changed() {
    unsafe {
        let old = DISPLAY_TIMER.swap(0, Ordering::SeqCst);
        if old != 0 {
            let _ = KillTimer(None, old);
        }
        let id = SetTimer(None, 0, 1500, Some(display_settled));
        DISPLAY_TIMER.store(id, Ordering::SeqCst);
    }
}

pub fn run_message_loop() {
    unsafe {
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            if msg.hwnd.is_invalid() {
                match msg.message {
                    WM_APP_CURSOR => apply_pending_cursor(),
                    WM_APP_MINIMIZE => show_all(SW_MINIMIZE),
                    _ => {}
                }
            }
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

pub fn post_quit() {
    unsafe {
        let _ = PostThreadMessageW(MAIN_THREAD.load(Ordering::SeqCst), WM_QUIT, WPARAM(0), LPARAM(0));
    }
}

fn show_all(cmd: SHOW_WINDOW_CMD) {
    for s in surfaces() {
        unsafe {
            let _ = ShowWindow(hwnd(s.hwnd), cmd);
        }
    }
}

pub fn hide_windows() {
    show_all(SW_HIDE);
}

// ------------------------------------------------------------------ keyboard

/// Install the low-level keyboard hook on its own thread (see the module comment).
pub fn start_keyboard_hook() {
    thread::spawn(|| unsafe {
        HOOK_THREAD.store(GetCurrentThreadId(), Ordering::SeqCst);
        let Ok(hook) = SetWindowsHookExW(WH_KEYBOARD_LL, Some(ll_keyboard), Some(GetModuleHandleW(None).unwrap().into()), 0) else {
            eprintln!("[omarchy] cannot install the keyboard hook; the Windows key will go to Windows");
            return;
        };
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {}
        let _ = UnhookWindowsHookEx(hook);
    });
}

/// Remove the hook (e.g. before the console asks the user something).
pub fn stop_keyboard_hook() {
    LIVE.store(false, Ordering::SeqCst);
    unsafe {
        let _ = PostThreadMessageW(HOOK_THREAD.load(Ordering::SeqCst), WM_QUIT, WPARAM(0), LPARAM(0));
    }
}

unsafe extern "system" fn ll_keyboard(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 && LIVE.load(Ordering::SeqCst) && is_ours(GetForegroundWindow()) {
        let kb = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        let down = wparam.0 as u32 == WM_KEYDOWN || wparam.0 as u32 == WM_SYSKEYDOWN;
        // AltGr on some layouts fires a synthetic LCtrl with scancode 0x21D; leave it to Windows
        if kb.scanCode != 0x21D {
            let extended = kb.flags.0 & LLKHF_EXTENDED.0 != 0;

            // Escape hatch that never reaches Linux: Ctrl+Alt+End minimises the desktop.
            let ctrl = GetAsyncKeyState(VK_CONTROL.0 as i32) < 0;
            let alt = GetAsyncKeyState(VK_MENU.0 as i32) < 0;
            if down && ctrl && alt && kb.vkCode == VK_END.0 as u32 {
                release_all_keys();
                let _ = PostThreadMessageW(MAIN_THREAD.load(Ordering::SeqCst), WM_APP_MINIMIZE, WPARAM(0), LPARAM(0));
                return LRESULT(1);
            }

            // (injected keys, e.g. a password manager typing, are forwarded too)
            if let Some(key) = keymap::to_evdev(kb.scanCode & 0xFF, extended, kb.vkCode) {
                let changed = {
                    let mut pressed = PRESSED.lock().unwrap();
                    // Windows auto-repeat: Hyprland does its own repeat, only forward the first press
                    if down {
                        pressed.insert(key)
                    } else {
                        pressed.remove(&key)
                    }
                };
                if changed {
                    send(wdp::key(now_ms(), key, down));
                }
                // swallow: Win, Alt+Tab, Win+… belong to Omarchy while it has focus
                return LRESULT(1);
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

// ------------------------------------------------------------------ mouse, focus, window events

fn lparam_xy(lparam: LPARAM) -> (i32, i32) {
    ((lparam.0 & 0xFFFF) as i16 as i32, ((lparam.0 >> 16) & 0xFFFF) as i16 as i32)
}

/// While a button is held the window that got the click receives all moves (capture), even over
/// another monitor: send them for the output actually under the pointer.
unsafe fn pointer_moved(h: HWND, lparam: LPARAM) {
    let (x, y) = lparam_xy(lparam);
    let mut pt = POINT { x, y };
    let _ = ClientToScreen(h, &mut pt);
    let target = WindowFromPoint(pt);
    let (surface, origin_window) = match surface_for(target) {
        Some(s) => (s, target),
        None => match surface_for(h) {
            Some(s) => (s, h),
            None => return,
        },
    };
    let _ = ScreenToClient(origin_window, &mut pt);
    let lx = (pt.x as f64).clamp(0.0, surface.width.saturating_sub(1) as f64);
    let ly = (pt.y as f64).clamp(0.0, surface.height.saturating_sub(1) as f64);
    send(wdp::pointer_abs_frame(now_ms(), surface.output_id, lx, ly));
}

fn button(h: HWND, btn: u32, pressed: bool) {
    let bit = 1u32 << (btn - keymap::BTN_LEFT).min(31);
    unsafe {
        if pressed {
            BUTTONS.fetch_or(bit, Ordering::SeqCst);
            SetCapture(h);
        } else if BUTTONS.fetch_and(!bit, Ordering::SeqCst) & !bit == 0 {
            let _ = ReleaseCapture(); // only once no button is held any more
        }
    }
    send(wdp::pointer_button(now_ms(), btn, pressed));
}

fn set_visible(h: HWND, visible: bool) {
    let Some(s) = surface_for(h) else { return };
    let changed = {
        let mut min = MINIMIZED.lock().unwrap();
        if visible {
            min.remove(&s.hwnd)
        } else {
            min.insert(s.hwnd)
        }
    };
    if changed {
        send(wdp::output_visible(s.output_id, visible));
        if visible {
            send(wdp::refresh(s.output_id));
        }
    }
}

unsafe extern "system" fn wndproc(h: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_MOUSEMOVE => {
            pointer_moved(h, lparam);
            LRESULT(0)
        }
        WM_LBUTTONDOWN | WM_LBUTTONUP => {
            button(h, keymap::BTN_LEFT, msg == WM_LBUTTONDOWN);
            LRESULT(0)
        }
        WM_RBUTTONDOWN | WM_RBUTTONUP => {
            button(h, keymap::BTN_RIGHT, msg == WM_RBUTTONDOWN);
            LRESULT(0)
        }
        WM_MBUTTONDOWN | WM_MBUTTONUP => {
            button(h, keymap::BTN_MIDDLE, msg == WM_MBUTTONDOWN);
            LRESULT(0)
        }
        WM_XBUTTONDOWN | WM_XBUTTONUP => {
            let which = ((wparam.0 >> 16) & 0xFFFF) as u16;
            button(h, if which == 1 { keymap::BTN_SIDE } else { keymap::BTN_EXTRA }, msg == WM_XBUTTONDOWN);
            LRESULT(1)
        }
        WM_MOUSEWHEEL | WM_MOUSEHWHEEL => {
            let delta = ((wparam.0 >> 16) & 0xFFFF) as i16 as i32;
            let (axis, d120) = if msg == WM_MOUSEWHEEL { (0, -delta) } else { (1, delta) };
            send(wdp::pointer_axis(now_ms(), axis, d120 as f64 / 120.0 * 15.0, d120));
            LRESULT(0)
        }
        WM_SETCURSOR => {
            if (lparam.0 & 0xFFFF) as u32 == HTCLIENT {
                let (current, hidden) = {
                    let c = CURSOR.lock().unwrap();
                    (c.current, c.hidden)
                };
                if hidden {
                    SetCursor(None);
                } else if current != 0 {
                    SetCursor(Some(HCURSOR(current as *mut _)));
                } else {
                    SetCursor(LoadCursorW(None, IDC_ARROW).ok());
                }
                return LRESULT(1);
            }
            DefWindowProcW(h, msg, wparam, lparam)
        }
        WM_ACTIVATE => {
            let active = (wparam.0 & 0xFFFF) != 0;
            // focus moving between our own windows (one per monitor) is not a focus change for Linux
            if !is_ours(HWND(lparam.0 as *mut _)) {
                if !active {
                    release_all_keys();
                }
                send(wdp::focus(active));
            }
            DefWindowProcW(h, msg, wparam, lparam)
        }
        WM_SIZE => {
            match wparam.0 as u32 {
                SIZE_MINIMIZED => set_visible(h, false),
                SIZE_RESTORED | SIZE_MAXIMIZED => set_visible(h, true),
                _ => {}
            }
            DefWindowProcW(h, msg, wparam, lparam)
        }
        WM_ERASEBKGND => LRESULT(1),
        WM_DISPLAYCHANGE => {
            display_changed();
            DefWindowProcW(h, msg, wparam, lparam)
        }
        // our windows follow the monitor layout, not Windows' suggested DPI-scaled rectangle
        WM_DPICHANGED => {
            display_changed();
            LRESULT(0)
        }
        WM_PAINT if !SPLASH_DONE.lock().unwrap().contains(&(h.0 as isize)) => {
            paint_splash(h);
            LRESULT(0)
        }
        WM_CLOSE => {
            // closing the viewer ends the Omarchy session (logout); we exit when the session does
            if LIVE.load(Ordering::SeqCst) && !QUIT_SENT.swap(true, Ordering::SeqCst) {
                send(wdp::quit());
            } else {
                post_quit();
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(h, msg, wparam, lparam),
    }
}

fn paint_splash(h: HWND) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(h, &mut ps);
        let mut rc = RECT::default();
        let _ = GetClientRect(h, &mut rc);
        FillRect(hdc, &rc, HBRUSH(GetStockObject(BLACK_BRUSH).0));
        let dpi = windows::Win32::UI::HiDpi::GetDpiForWindow(h).max(96) as i32;
        let font = CreateFontW(
            -(22 * dpi / 96), 0, 0, 0, FW_NORMAL.0 as i32, 0, 0, 0,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
            0, w!("Segoe UI"),
        );
        let old = SelectObject(hdc, font.into());
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, COLORREF(0x00B0B0B0));
        let mut text: Vec<u16> = "Starting Omarchy\u{2026}".encode_utf16().collect();
        DrawTextW(hdc, &mut text, &mut rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        SelectObject(hdc, old);
        let _ = DeleteObject(font.into());
        let _ = EndPaint(h, &ps);
    }
}

// ------------------------------------------------------------------ cursor (UI thread)

/// Turn the newest cursor image into an HCURSOR (UI thread: it owns cursor handles), swap it in and
/// re-apply it to the window under the pointer.
fn apply_pending_cursor() {
    let (image, hidden) = {
        let mut c = CURSOR.lock().unwrap();
        (c.pending.take(), c.hidden)
    };
    if let Some(img) = image {
        if let Some(cur) = make_cursor(&img) {
            let old = std::mem::replace(&mut CURSOR.lock().unwrap().current, cur.0 as isize);
            reapply_cursor();
            if old != 0 {
                unsafe {
                    let _ = DestroyCursor(HCURSOR(old as *mut _));
                }
            }
            return;
        }
    }
    let _ = hidden;
    reapply_cursor();
}

fn reapply_cursor() {
    unsafe {
        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        let under = WindowFromPoint(pt);
        if is_ours(under) {
            SendMessageW(under, WM_SETCURSOR, Some(WPARAM(under.0 as usize)), Some(LPARAM(HTCLIENT as isize)));
        }
    }
}

/// Premultiplied ARGB8888 (cairo) -> a Windows alpha cursor.
fn make_cursor(img: &CursorImage) -> Option<HCURSOR> {
    let (w, h) = (img.width, img.height);
    let bytes = (w as usize).checked_mul(h as usize)?.checked_mul(4)?;
    if w == 0 || h == 0 || w > wdp::MAX_CURSOR || h > wdp::MAX_CURSOR || img.argb.len() < bytes {
        return None;
    }
    unsafe {
        let bmi = BITMAPV5HEADER {
            bV5Size: std::mem::size_of::<BITMAPV5HEADER>() as u32,
            bV5Width: w as i32,
            bV5Height: -(h as i32),
            bV5Planes: 1,
            bV5BitCount: 32,
            bV5Compression: BI_BITFIELDS,
            bV5RedMask: 0x00FF0000,
            bV5GreenMask: 0x0000FF00,
            bV5BlueMask: 0x000000FF,
            bV5AlphaMask: 0xFF000000,
            ..Default::default()
        };
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let color = CreateDIBSection(None, &bmi as *const _ as *const BITMAPINFO, DIB_RGB_COLORS, &mut bits, None, 0).ok()?;
        // un-premultiply for Windows' straight-alpha cursors
        let dst = std::slice::from_raw_parts_mut(bits as *mut u8, bytes);
        for (i, px) in img.argb[..bytes].chunks_exact(4).enumerate() {
            let a = px[3] as u32;
            let un = |c: u8| (c as u32 * 255 + a / 2).checked_div(a).map_or(0, |v| v.min(255) as u8);
            dst[i * 4] = un(px[0]);
            dst[i * 4 + 1] = un(px[1]);
            dst[i * 4 + 2] = un(px[2]);
            dst[i * 4 + 3] = px[3];
        }
        let mask = CreateBitmap(w as i32, h as i32, 1, 1, None);
        let info = ICONINFO {
            fIcon: FALSE,
            xHotspot: img.hot_x.clamp(0, w as i32 - 1) as u32,
            yHotspot: img.hot_y.clamp(0, h as i32 - 1) as u32,
            hbmMask: mask,
            hbmColor: color,
        };
        let icon = CreateIconIndirect(&info).ok();
        let _ = DeleteObject(color.into());
        let _ = DeleteObject(mask.into());
        icon.map(|i| HCURSOR(i.0))
    }
}

// ------------------------------------------------------------------ session: reader and presenters

pub struct RenderOptions {
    pub dump_frame: Option<String>,
    pub dump_after: u64,
    pub stats: bool,
    /// `--input-script FILE` and where it runs (see script.rs)
    pub script: Option<crate::script::Options>,
}

struct Session {
    conn: Conn,
    transport: u32,
    vm_id: String,
    first_output: u32,
    opts: RenderOptions,
    script_started: AtomicBool,
    buffers_tx: mpsc::Sender<Vec<u8>>, // presenters return frame buffers for reuse
}

enum Job {
    Frame(Vec<u8>),
    /// the output's buffers were reallocated (new size): drop cached mappings
    Reset,
}

/// Run the session's display side until the compositor says goodbye or the connection ends.
pub fn run_session(conn: Conn, transport: u32, vm_id: String, opts: RenderOptions) -> Result<(), String> {
    let (buffers_tx, buffers_rx) = mpsc::channel::<Vec<u8>>();
    let first_output = surfaces().first().map(|s| s.output_id).unwrap_or(1);
    let stats = opts.stats;
    let session: &'static Session = Box::leak(Box::new(Session {
        conn: conn.clone(),
        transport,
        vm_id,
        first_output,
        opts,
        script_started: AtomicBool::new(false),
        buffers_tx,
    }));
    if stats {
        thread::spawn(|| loop {
            thread::sleep(Duration::from_secs(2));
            let (f, p) = (STAT_FRAMES.swap(0, Ordering::Relaxed), STAT_PIXELS.swap(0, Ordering::Relaxed));
            eprintln!("[omarchy] {:.1} frames/s, {:.1} Mpx/s uploaded", f as f64 / 2.0, p as f64 / 2.0 / 1e6);
        });
    }

    let mut presenters: HashMap<u32, (mpsc::Sender<Job>, thread::JoinHandle<()>)> = HashMap::new();
    let result = loop {
        let mut payload = buffers_rx.try_recv().unwrap_or_default();
        let ty = match conn.recv_msg(&mut payload) {
            Ok(t) => t,
            Err(e) => break Err(format!("the display connection ended: {}", e)),
        };
        let mut r = Reader::new(&payload);
        match ty {
            wdp::FRAME => {
                let Some(id) = wdp::frame_output(&payload) else { continue };
                let (tx, _) = presenters.entry(id).or_insert_with(|| {
                    let (tx, rx) = mpsc::channel();
                    (tx, thread::spawn(move || presenter(session, id, rx)))
                });
                let _ = tx.send(Job::Frame(payload));
            }
            wdp::OUTPUT => {
                let (id, w, h) = (r.u32().unwrap_or(0), r.u32().unwrap_or(0), r.u32().unwrap_or(0));
                eprintln!("[omarchy] output {} is {}x{}", id, w, h);
                if let Some((tx, _)) = presenters.get(&id) {
                    let _ = tx.send(Job::Reset);
                }
            }
            wdp::OUTPUT_REMOVED => {
                presenters.remove(&r.u32().unwrap_or(0)); // its presenter finishes and exits
            }
            wdp::CURSOR => {
                let visible = r.u32().unwrap_or(1) != 0;
                let has_image = r.u32().unwrap_or(0) != 0;
                let mut c = CURSOR.lock().unwrap();
                c.hidden = !visible;
                if has_image {
                    let (w, h) = (r.u32().unwrap_or(0), r.u32().unwrap_or(0));
                    let (hot_x, hot_y) = (r.i32().unwrap_or(0), r.i32().unwrap_or(0));
                    let bytes = w as usize * h as usize * 4;
                    if w <= wdp::MAX_CURSOR && h <= wdp::MAX_CURSOR && r.rest().len() >= bytes {
                        c.pending = Some(CursorImage { width: w, height: h, hot_x, hot_y, argb: r.rest()[..bytes].to_vec() });
                    }
                }
                drop(c);
                unsafe {
                    let _ = PostThreadMessageW(MAIN_THREAD.load(Ordering::SeqCst), WM_APP_CURSOR, WPARAM(0), LPARAM(0));
                }
            }
            wdp::BYE => {
                eprintln!("[omarchy] compositor said goodbye");
                break Ok(());
            }
            _ => {}
        }
    };
    stop_input();
    // Closing the channels ends the presenters. Wait for them only when one may still write a frame dump
    // (a debug option): a presenter stuck in the driver must never keep the viewer from exiting.
    let handles: Vec<_> = presenters.into_values().map(|(_, h)| h).collect();
    if session.opts.dump_frame.is_some() {
        handles.into_iter().for_each(|h| drop(h.join()));
    }
    conn.shutdown();
    result
}

struct Mapping {
    handle: HANDLE,
    view: MEMORY_MAPPED_VIEW_ADDRESS,
    size: usize,
}

impl Drop for Mapping {
    fn drop(&mut self) {
        unsafe {
            let _ = UnmapViewOfFile(self.view);
            let _ = CloseHandle(self.handle);
        }
    }
}

/// One output's GPU objects (rebuilt after a device loss).
struct Gfx {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    factory: IDXGIFactory2,
    swapchain: Option<(isize, u32, u32, IDXGISwapChain1)>, // (hwnd, width, height, swapchain)
    content: Option<(u32, u32, ID3D11Texture2D)>,
}

fn create_gfx() -> windows::core::Result<Gfx> {
    unsafe {
        let mut device: Option<ID3D11Device> = None;
        let mut context: Option<ID3D11DeviceContext> = None;
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )?;
        let device = device.ok_or_else(windows::core::Error::empty)?;
        let context = context.ok_or_else(windows::core::Error::empty)?;
        let dxgi: IDXGIDevice1 = device.cast()?;
        // present one frame ahead at most: the compositor renders the next frame only after our ack
        let _ = dxgi.SetMaximumFrameLatency(1);
        let factory: IDXGIFactory2 = dxgi.GetAdapter()?.GetParent()?;
        Ok(Gfx { device, context, factory, swapchain: None, content: None })
    }
}

/// Swapchain for the output's current window (new window: new swapchain; new size: resize).
fn ensure_swapchain(g: &mut Gfx, s: &Surface) -> windows::core::Result<IDXGISwapChain1> {
    if let Some((h, w, ht, sc)) = &g.swapchain {
        if *h == s.hwnd {
            if (*w, *ht) != (s.width, s.height) {
                unsafe { sc.ResizeBuffers(2, s.width, s.height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SWAP_CHAIN_FLAG(0))? };
                g.swapchain = Some((s.hwnd, s.width, s.height, sc.clone()));
            }
            return Ok(g.swapchain.as_ref().unwrap().3.clone());
        }
    }
    g.swapchain = None;
    let desc = DXGI_SWAP_CHAIN_DESC1 {
        Width: s.width,
        Height: s.height,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
        BufferCount: 2,
        SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
        AlphaMode: DXGI_ALPHA_MODE_IGNORE,
        ..Default::default()
    };
    let sc = unsafe { g.factory.CreateSwapChainForHwnd(&g.device, hwnd(s.hwnd), &desc, None, None)? };
    unsafe {
        let _ = g.factory.MakeWindowAssociation(hwnd(s.hwnd), DXGI_MWA_NO_ALT_ENTER);
    }
    SPLASH_DONE.lock().unwrap().insert(s.hwnd);
    g.swapchain = Some((s.hwnd, s.width, s.height, sc.clone()));
    Ok(sc)
}

fn ensure_content(g: &mut Gfx, w: u32, h: u32) -> windows::core::Result<ID3D11Texture2D> {
    if let Some((cw, ch, tex)) = &g.content {
        if (*cw, *ch) == (w, h) {
            return Ok(tex.clone());
        }
    }
    let desc = D3D11_TEXTURE2D_DESC {
        Width: w,
        Height: h,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_DEFAULT,
        ..Default::default()
    };
    let mut tex = None;
    unsafe { g.device.CreateTexture2D(&desc, None, Some(&mut tex))? };
    let tex = tex.ok_or_else(windows::core::Error::empty)?;
    g.content = Some((w, h, tex.clone()));
    Ok(tex)
}

/// One output: upload, present, acknowledge; every frame is acknowledged, even one that failed, so the
/// compositor never waits forever.
fn presenter(session: &'static Session, id: u32, rx: mpsc::Receiver<Job>) {
    let mut gfx: Option<Gfx> = None;
    let mut sections: HashMap<String, Mapping> = HashMap::new();
    let mut reported: HashSet<String> = HashSet::new(); // problems already logged (log once)
    let mut frames = 0u64;
    let trace = std::env::var_os("OMARCHY_FRAME_TRACE").is_some();

    for job in rx {
        let payload = match job {
            Job::Reset => {
                sections.clear();
                continue;
            }
            Job::Frame(p) => p,
        };
        let t_recv = Instant::now();
        let mut r = Reader::new(&payload);
        let Some(f) = wdp::parse_frame(&mut r).filter(|f| f.output == id) else {
            if reported.insert("bad frame".into()) {
                eprintln!("[omarchy] output {}: invalid frame ignored", id);
            }
            // seq sits at a fixed offset; ack it so the output keeps going
            if let Some(seq) = payload.get(20..28).map(|b| u64::from_le_bytes(b.try_into().unwrap())) {
                let _ = session.conn.send_msg(&wdp::frame_done(id, seq, 0));
            }
            let _ = session.buffers_tx.send(payload);
            continue;
        };

        if let Err(e) = present_frame(session, &mut gfx, &mut sections, &mut reported, &f, r.rest(), id, &mut frames) {
            if reported.insert(format!("{:?}", e.code())) {
                eprintln!("[omarchy] output {}: {}", id, e.message());
            }
            if e.code() == DXGI_ERROR_DEVICE_REMOVED || e.code() == DXGI_ERROR_DEVICE_RESET {
                // the GPU was reset (driver update/crash): start over with new objects and a full frame
                gfx = None;
                sections.clear();
                send(wdp::refresh(id));
            }
        }
        let _ = session.conn.send_msg(&wdp::frame_done(id, f.seq, 0));
        if trace {
            eprintln!("[trace] output {} seq {} done in {:.2} ms", id, f.seq, t_recv.elapsed().as_secs_f64() * 1e3);
        }
        let _ = session.buffers_tx.send(payload);
    }

    // the session ended before frame --dump-after arrived: dump what the output showed last
    if let (Some(path), Some(g)) = (&session.opts.dump_frame, &gfx) {
        if id == session.first_output && frames < session.opts.dump_after {
            if let Some((w, h, tex)) = &g.content {
                dump_texture(&g.device, &g.context, tex, *w, *h, path);
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn present_frame(
    session: &'static Session,
    gfx: &mut Option<Gfx>,
    sections: &mut HashMap<String, Mapping>,
    reported: &mut HashSet<String>,
    f: &wdp::Frame,
    inline: &[u8],
    id: u32,
    frames: &mut u64,
) -> windows::core::Result<()> {
    // the window may have changed since the last frame (monitor layout change) or be gone
    let Some(surface) = surface_by_id(id) else { return Ok(()) };
    if gfx.is_none() {
        *gfx = Some(create_gfx()?);
    }
    let g = gfx.as_mut().unwrap();
    let swapchain = ensure_swapchain(g, &surface)?;
    let content = ensure_content(g, f.width, f.height)?;

    if !f.rects.is_empty() {
        if session.transport == wdp::TRANSPORT_SECTION {
            let need = f.stride as usize * f.height as usize;
            if sections.get(&f.buffer).is_some_and(|m| m.size < need) {
                sections.remove(&f.buffer); // reused name, bigger buffer
            }
            if !sections.contains_key(&f.buffer) {
                if sections.len() >= 8 {
                    sections.clear(); // buffers rotate among a few; old names are gone
                }
                match open_section(&session.vm_id, &f.buffer, need) {
                    Ok(m) => {
                        sections.insert(f.buffer.clone(), m);
                    }
                    Err(e) => {
                        if reported.insert(f.buffer.clone()) {
                            eprintln!("[omarchy] output {}: cannot map {}: {}", id, f.buffer, e);
                        }
                        return Ok(());
                    }
                }
            }
            let m = &sections[&f.buffer];
            let base = m.view.Value as *const u8;
            for rc in &f.rects {
                let offset = rc.y as usize * f.stride as usize + rc.x as usize * 4;
                let span = (rc.h as usize - 1) * f.stride as usize + rc.w as usize * 4;
                if offset + span > m.size {
                    continue;
                }
                let b = D3D11_BOX { left: rc.x, top: rc.y, front: 0, right: rc.x + rc.w, bottom: rc.y + rc.h, back: 1 };
                unsafe { g.context.UpdateSubresource(&content, 0, Some(&b), base.add(offset) as *const _, f.stride, 0) };
                STAT_PIXELS.fetch_add(rc.w as u64 * rc.h as u64, Ordering::Relaxed);
            }
        } else {
            let mut px = inline;
            for rc in &f.rects {
                let bytes = rc.w as usize * rc.h as usize * 4;
                if px.len() < bytes {
                    break;
                }
                let b = D3D11_BOX { left: rc.x, top: rc.y, front: 0, right: rc.x + rc.w, bottom: rc.y + rc.h, back: 1 };
                unsafe { g.context.UpdateSubresource(&content, 0, Some(&b), px.as_ptr() as *const _, rc.w * 4, 0) };
                px = &px[bytes..];
                STAT_PIXELS.fetch_add(rc.w as u64 * rc.h as u64, Ordering::Relaxed);
            }
        }

        unsafe {
            let back: ID3D11Texture2D = swapchain.GetBuffer(0)?;
            if (surface.width, surface.height) == (f.width, f.height) {
                g.context.CopyResource(&back, &content);
            } else {
                let b = D3D11_BOX { left: 0, top: 0, front: 0, right: surface.width.min(f.width), bottom: surface.height.min(f.height), back: 1 };
                g.context.CopySubresourceRegion(&back, 0, 0, 0, 0, &content, 0, Some(&b));
            }
            // A minimised window isn't shown: don't wait for its vblank (the compositor throttles it).
            let shown = !IsIconic(hwnd(surface.hwnd)).as_bool();
            swapchain.Present(if shown { 1 } else { 0 }, DXGI_PRESENT(0)).ok()?;
        }
        STAT_FRAMES.fetch_add(1, Ordering::Relaxed);
    }

    *frames += 1;
    if id == session.first_output {
        if let Some(script) = &session.opts.script {
            if !session.script_started.swap(true, Ordering::SeqCst) {
                let script = script.clone();
                thread::spawn(move || crate::script::run(script, id));
            }
        }
        if let Some(path) = &session.opts.dump_frame {
            if *frames == session.opts.dump_after {
                dump_texture(&g.device, &g.context, &content, f.width, f.height, path);
            }
        }
    }
    Ok(())
}

fn open_section(vm_id: &str, name: &str, size: usize) -> windows::core::Result<Mapping> {
    let path: Vec<u16> = format!("WSL\\{}\\wslg\\{}\0", vm_id, name).encode_utf16().collect();
    unsafe {
        let handle = OpenFileMappingW(FILE_MAP_READ.0, false, PCWSTR(path.as_ptr()))?;
        let view = MapViewOfFile(handle, FILE_MAP_READ, 0, 0, size);
        if view.Value.is_null() {
            let e = windows::core::Error::from_win32();
            let _ = CloseHandle(handle);
            return Err(e);
        }
        Ok(Mapping { handle, view, size })
    }
}

/// Debug helper (--dump-frame): write the output's current content as a 32-bit BMP.
fn dump_texture(device: &ID3D11Device, context: &ID3D11DeviceContext, tex: &ID3D11Texture2D, w: u32, h: u32, path: &str) {
    unsafe {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: w,
            Height: h,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_STAGING,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            ..Default::default()
        };
        let mut staging = None;
        if device.CreateTexture2D(&desc, None, Some(&mut staging)).is_err() {
            return;
        }
        let Some(staging) = staging else { return };
        context.CopyResource(&staging, tex);
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        if context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).is_err() {
            return;
        }
        let mut data = Vec::with_capacity((w * h * 4) as usize + 54);
        let file_size = 54 + w * h * 4;
        data.extend_from_slice(b"BM");
        data.extend_from_slice(&file_size.to_le_bytes());
        data.extend_from_slice(&0u32.to_le_bytes());
        data.extend_from_slice(&54u32.to_le_bytes());
        data.extend_from_slice(&40u32.to_le_bytes());
        data.extend_from_slice(&(w as i32).to_le_bytes());
        data.extend_from_slice(&(-(h as i32)).to_le_bytes());
        data.extend_from_slice(&1u16.to_le_bytes());
        data.extend_from_slice(&32u16.to_le_bytes());
        data.extend_from_slice(&[0u8; 24]);
        for y in 0..h as usize {
            let row = std::slice::from_raw_parts((mapped.pData as *const u8).add(y * mapped.RowPitch as usize), (w * 4) as usize);
            data.extend_from_slice(row);
        }
        context.Unmap(&staging, 0);
        let _ = std::fs::write(path, data);
        eprintln!("[omarchy] dumped frame to {}", path);
    }
}
