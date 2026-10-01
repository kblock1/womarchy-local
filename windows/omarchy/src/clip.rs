//! Clipboard bridge: the Windows clipboard <-> womarchy-clipd (the session's Wayland clipboard), text only.
//!
//! womarchy-clipd listens on the compositor's vsock port + 1 with its own session token. We prove the
//! token's first half (CLIP_HELLO), it proves the second (CLIP_WELCOME); only then does any clipboard
//! text cross, as CLIP_TEXT (UTF-8, LF line endings) whenever either side's clipboard changes. Both ends
//! remember the last text they synced, so a change never echoes back.
//!
//! Threads: the UI thread owns the clipboard window (change notifications, writing the clipboard); the
//! connection thread does all socket I/O, fed by a channel, so the UI thread never blocks on it.

use crate::net::Conn;
use crate::wdp;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::{mpsc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use windows::core::{w, HSTRING};
use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::DataExchange::{
    AddClipboardFormatListener, CloseClipboard, EmptyClipboard, GetClipboardData, GetClipboardOwner, IsClipboardFormatAvailable,
    OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, PostMessageW, RegisterClassExW, HWND_MESSAGE, WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP,
    WM_CLIPBOARDUPDATE, WNDCLASSEXW,
};

const WM_CLIP_SET: u32 = WM_APP + 10;
const MAX_TEXT: usize = 16 << 20;

static HWND_CLIP: AtomicIsize = AtomicIsize::new(0);
static OUTBOX: Mutex<Option<mpsc::Sender<String>>> = Mutex::new(None); // Windows -> Linux, to the connection thread
static LAST: Mutex<String> = Mutex::new(String::new()); // last text synced in either direction
static PENDING: Mutex<Option<String>> = Mutex::new(None); // Linux -> Windows, waiting for the UI thread

/// Create the hidden clipboard window; call on the UI (message loop) thread.
pub fn init() {
    unsafe {
        let hinst = GetModuleHandleW(None).unwrap();
        let class = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: hinst.into(),
            lpszClassName: w!("OmarchyClipboard"),
            ..Default::default()
        };
        RegisterClassExW(&class);
        let Ok(hwnd) = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("OmarchyClipboard"),
            w!(""),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            Some(HWND_MESSAGE),
            None,
            Some(hinst.into()),
            None,
        ) else {
            eprintln!("[omarchy] clipboard: no message window; clipboard sharing is off");
            return;
        };
        HWND_CLIP.store(hwnd.0 as isize, Ordering::SeqCst);
        if AddClipboardFormatListener(hwnd).is_err() {
            eprintln!("[omarchy] clipboard: cannot listen for clipboard changes");
        }
    }
}

/// Connect to womarchy-clipd and keep the connection for the session (clipd starts a little after the
/// compositor and may restart).
pub fn start(vm: windows::core::GUID, port: u32, token: [u8; wdp::TOKEN_BYTES]) {
    thread::spawn(move || {
        let mut announced = false;
        loop {
            let Some(conn) = connect(vm, port, &token) else {
                if !announced {
                    eprintln!("[omarchy] clipboard: womarchy-clipd did not answer; clipboard sharing is off");
                }
                return;
            };
            if !announced {
                eprintln!("[omarchy] clipboard: connected");
                announced = true;
            }

            // Windows' clipboard wins at connect: the session starts with an empty one (and a restarted
            // clipd has forgotten what it had)
            let (tx, rx) = mpsc::channel::<String>();
            *OUTBOX.lock().unwrap() = Some(tx);
            LAST.lock().unwrap().clear();
            if let Some(text) = read_clipboard() {
                offer(text);
            }
            let sender = conn.clone();
            thread::spawn(move || {
                for text in rx {
                    if sender.send_msg(&wdp::clip_text(text.as_bytes())).is_err() {
                        break;
                    }
                }
            });

            let mut payload = Vec::new();
            loop {
                match conn.recv_msg(&mut payload) {
                    Ok(wdp::CLIP_TEXT) if payload.len() <= MAX_TEXT => {
                        *PENDING.lock().unwrap() = Some(String::from_utf8_lossy(&payload).into_owned());
                        unsafe {
                            let _ = PostMessageW(Some(HWND(HWND_CLIP.load(Ordering::SeqCst) as *mut _)), WM_CLIP_SET, WPARAM(0), LPARAM(0));
                        }
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
            *OUTBOX.lock().unwrap() = None; // ends the sender thread
            thread::sleep(Duration::from_millis(500));
        }
    });
}

/// Connect, prove our half of the token and check clipd's (up to two minutes of retries).
fn connect(vm: windows::core::GUID, port: u32, token: &[u8; wdp::TOKEN_BYTES]) -> Option<Conn> {
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(120) {
        if let Ok(conn) = Conn::connect(vm, port) {
            conn.set_recv_timeout(Some(Duration::from_secs(5)));
            let mut payload = Vec::new();
            let ok = conn.send_msg(&wdp::clip_hello(token)).is_ok()
                && matches!(conn.recv_msg(&mut payload), Ok(wdp::CLIP_WELCOME))
                && wdp::proves(token, payload.get(4..4 + wdp::PROOF_BYTES).unwrap_or(&[]));
            conn.set_recv_timeout(None);
            if ok {
                return Some(conn);
            }
            eprintln!("[omarchy] clipboard: the clipboard daemon failed to authenticate; not sharing the clipboard with it");
            return None;
        }
        thread::sleep(Duration::from_millis(500));
    }
    None
}

/// Send Windows clipboard text to Linux unless it is what we last synced.
fn offer(text: String) {
    let text = text.replace("\r\n", "\n");
    if text.len() > MAX_TEXT {
        return;
    }
    {
        let mut last = LAST.lock().unwrap();
        if *last == text {
            return;
        }
        *last = text.clone();
    }
    if let Some(tx) = OUTBOX.lock().unwrap().as_ref() {
        let _ = tx.send(text);
    }
}

/// Windows password managers mark secrets with this format ("don't let clipboard monitors see this");
/// such content is not forwarded.
fn sensitive() -> bool {
    unsafe { IsClipboardFormatAvailable(RegisterClipboardFormatW(&HSTRING::from("ExcludeClipboardContentFromMonitorProcessing"))).is_ok() }
}

fn open_clipboard(owner: Option<HWND>) -> bool {
    // another process may hold it for a moment
    for _ in 0..10 {
        if unsafe { OpenClipboard(owner) }.is_ok() {
            return true;
        }
        thread::sleep(Duration::from_millis(10));
    }
    false
}

fn read_clipboard() -> Option<String> {
    unsafe {
        IsClipboardFormatAvailable(CF_UNICODETEXT.0 as u32).ok()?;
        if sensitive() || !open_clipboard(None) {
            return None;
        }
        let mut out = None;
        if let Ok(h) = GetClipboardData(CF_UNICODETEXT.0 as u32) {
            let g = HGLOBAL(h.0);
            let units = GlobalSize(g) / 2; // never read past the allocation, terminated or not
            let p = GlobalLock(g) as *const u16;
            if !p.is_null() {
                let all = std::slice::from_raw_parts(p, units);
                let n = all.iter().position(|&c| c == 0).unwrap_or(units);
                out = Some(String::from_utf16_lossy(&all[..n]));
                let _ = GlobalUnlock(g);
            }
        }
        let _ = CloseClipboard();
        out
    }
}

fn write_clipboard(hwnd: HWND, text: &str) -> bool {
    let wide: Vec<u16> = text.replace('\n', "\r\n").encode_utf16().chain(std::iter::once(0)).collect();
    if !open_clipboard(Some(hwnd)) {
        return false;
    }
    let mut ok = false;
    unsafe {
        let _ = EmptyClipboard();
        if let Ok(g) = GlobalAlloc(GMEM_MOVEABLE, wide.len() * 2) {
            let p = GlobalLock(g) as *mut u16;
            if !p.is_null() {
                std::ptr::copy_nonoverlapping(wide.as_ptr(), p, wide.len());
                let _ = GlobalUnlock(g);
                // on success the clipboard owns the memory
                ok = SetClipboardData(CF_UNICODETEXT.0 as u32, Some(HANDLE(g.0))).is_ok();
                if !ok {
                    let _ = GlobalFree(Some(g));
                }
            }
        }
        let _ = CloseClipboard();
    }
    ok
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_CLIPBOARDUPDATE => {
            // our own write_clipboard lands here too; LAST already holds that text
            if GetClipboardOwner().ok() != Some(hwnd) {
                if let Some(text) = read_clipboard() {
                    offer(text);
                }
            }
            LRESULT(0)
        }
        WM_CLIP_SET => {
            let text = PENDING.lock().unwrap().take();
            if let Some(text) = text {
                if write_clipboard(hwnd, &text) {
                    *LAST.lock().unwrap() = text;
                }
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
