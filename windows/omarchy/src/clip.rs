//! Clipboard bridge: the Windows clipboard <-> womarchy-clipd (the session's Wayland clipboard), for
//! text and images.
//!
//! womarchy-clipd listens on the compositor's vsock port + 1 with its own session token. We prove the
//! token's first half (CLIP_HELLO), it proves the second (CLIP_WELCOME); only then does anything cross:
//! CLIP_TEXT (UTF-8, LF line endings), or CLIP_IMAGE (PNG) when the clipboard holds an image and no
//! text, whenever either side's clipboard changes. Both ends remember the last content they synced, so
//! a change never echoes back. Content a password manager marks as secret is never sent.
//!
//! Threads: the UI thread owns the clipboard window (change notifications, reading and writing the
//! clipboard); the connection thread does all socket I/O and the image conversions (PNG <-> CF_DIB,
//! see clipimage.rs), fed by a channel, so the UI thread never blocks on either.

use crate::clipimage::{dib_from_png, is_png, png_from_dib};
use crate::net::Conn;
use crate::wdp;
use std::hash::{DefaultHasher, Hash, Hasher};
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
use windows::Win32::System::Ole::{CF_DIB, CF_UNICODETEXT};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, PostMessageW, RegisterClassExW, HWND_MESSAGE, WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP,
    WM_CLIPBOARDUPDATE, WNDCLASSEXW,
};

const WM_CLIP_SET: u32 = WM_APP + 10;

/// What the Windows clipboard holds, as read on the UI thread (bitmaps are converted later).
enum Outgoing {
    Text(String),
    Png(Vec<u8>),
    Dib(Vec<u8>),
}

/// What arrived from Linux, ready to put on the clipboard (images already converted).
enum Incoming {
    Text(String),
    Image { png: Vec<u8>, dib: Option<Vec<u8>> },
}

/// The last content synced in either direction (images by hash), so nothing is sent twice or echoed.
#[derive(PartialEq)]
enum Synced {
    Text(String),
    Image(u64),
}

static HWND_CLIP: AtomicIsize = AtomicIsize::new(0);
static OUTBOX: Mutex<Option<mpsc::Sender<Outgoing>>> = Mutex::new(None); // Windows -> Linux, to the connection thread
static LAST: Mutex<Option<Synced>> = Mutex::new(None);
static PENDING: Mutex<Option<Incoming>> = Mutex::new(None); // Linux -> Windows, waiting for the UI thread

fn hash(bytes: &[u8]) -> u64 {
    let mut h = DefaultHasher::new();
    bytes.hash(&mut h);
    h.finish()
}

/// The registered clipboard format browsers, Office and the Snipping Tool use for PNG data.
fn png_format() -> u32 {
    unsafe { RegisterClipboardFormatW(&HSTRING::from("PNG")) }
}

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
            let (tx, rx) = mpsc::channel::<Outgoing>();
            *OUTBOX.lock().unwrap() = Some(tx);
            *LAST.lock().unwrap() = None;
            if let Some(clip) = read_clipboard() {
                offer(clip);
            }
            let sender = conn.clone();
            thread::spawn(move || {
                for clip in rx {
                    let msg = match clip {
                        Outgoing::Text(text) => wdp::clip_text(text.as_bytes()),
                        Outgoing::Png(png) => wdp::clip_image(&png),
                        Outgoing::Dib(dib) => match png_from_dib(&dib) {
                            Some(png) if png.len() <= wdp::MAX_CLIP_IMAGE => wdp::clip_image(&png),
                            _ => continue, // not an image we can convert, or too big
                        },
                    };
                    if sender.send_msg(&msg).is_err() {
                        break;
                    }
                }
            });

            let mut payload = Vec::new();
            loop {
                let incoming = match conn.recv_msg(&mut payload) {
                    Ok(wdp::CLIP_TEXT) if payload.len() <= wdp::MAX_CLIP_TEXT => Incoming::Text(String::from_utf8_lossy(&payload).into_owned()),
                    Ok(wdp::CLIP_IMAGE) if payload.len() <= wdp::MAX_CLIP_IMAGE && is_png(&payload) => {
                        Incoming::Image { dib: dib_from_png(&payload), png: std::mem::take(&mut payload) }
                    }
                    Ok(_) => continue,
                    Err(_) => break,
                };
                *PENDING.lock().unwrap() = Some(incoming);
                unsafe {
                    let _ = PostMessageW(Some(HWND(HWND_CLIP.load(Ordering::SeqCst) as *mut _)), WM_CLIP_SET, WPARAM(0), LPARAM(0));
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

/// Send Windows clipboard content to Linux unless it is what we last synced.
fn offer(clip: Outgoing) {
    let (clip, synced) = match clip {
        Outgoing::Text(text) => {
            let text = text.replace("\r\n", "\n");
            if text.len() > wdp::MAX_CLIP_TEXT {
                return;
            }
            (Outgoing::Text(text.clone()), Synced::Text(text))
        }
        Outgoing::Png(png) if png.len() <= wdp::MAX_CLIP_IMAGE => {
            let h = hash(&png);
            (Outgoing::Png(png), Synced::Image(h))
        }
        Outgoing::Dib(dib) => {
            let h = hash(&dib);
            (Outgoing::Dib(dib), Synced::Image(h))
        }
        Outgoing::Png(_) => return, // too big
    };
    {
        let mut last = LAST.lock().unwrap();
        if last.as_ref() == Some(&synced) {
            return;
        }
        *last = Some(synced);
    }
    if let Some(tx) = OUTBOX.lock().unwrap().as_ref() {
        let _ = tx.send(clip);
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

/// The bytes of one clipboard format (the clipboard must be open), bounded by its allocation.
unsafe fn clipboard_bytes(format: u32) -> Option<Vec<u8>> {
    let h = GetClipboardData(format).ok()?;
    let g = HGLOBAL(h.0);
    let size = GlobalSize(g);
    let p = GlobalLock(g) as *const u8;
    if p.is_null() {
        return None;
    }
    let bytes = std::slice::from_raw_parts(p, size).to_vec();
    let _ = GlobalUnlock(g);
    Some(bytes)
}

/// Text if there is any (as most programs expect), else a PNG, else a bitmap.
fn read_clipboard() -> Option<Outgoing> {
    unsafe {
        let text = IsClipboardFormatAvailable(CF_UNICODETEXT.0 as u32).is_ok();
        let png = IsClipboardFormatAvailable(png_format()).is_ok();
        let dib = IsClipboardFormatAvailable(CF_DIB.0 as u32).is_ok();
        if !(text || png || dib) || sensitive() || !open_clipboard(None) {
            return None;
        }
        let out = if text {
            clipboard_bytes(CF_UNICODETEXT.0 as u32).map(|b| {
                let units: Vec<u16> = b.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect();
                let n = units.iter().position(|&c| c == 0).unwrap_or(units.len());
                Outgoing::Text(String::from_utf16_lossy(&units[..n]))
            })
        } else if let Some(data) = png.then(|| clipboard_bytes(png_format())).flatten().filter(|d| is_png(d)) {
            Some(Outgoing::Png(data))
        } else {
            clipboard_bytes(CF_DIB.0 as u32).map(Outgoing::Dib)
        };
        let _ = CloseClipboard();
        out
    }
}

/// Put `bytes` on the (open) clipboard as `format`; on success the clipboard owns the memory.
unsafe fn set_clipboard_bytes(format: u32, bytes: &[u8]) -> bool {
    let Ok(g) = GlobalAlloc(GMEM_MOVEABLE, bytes.len()) else { return false };
    let p = GlobalLock(g) as *mut u8;
    if p.is_null() {
        let _ = GlobalFree(Some(g));
        return false;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), p, bytes.len());
    let _ = GlobalUnlock(g);
    let ok = SetClipboardData(format, Some(HANDLE(g.0))).is_ok();
    if !ok {
        let _ = GlobalFree(Some(g));
    }
    ok
}

fn write_clipboard(hwnd: HWND, clip: &Incoming) -> bool {
    if !open_clipboard(Some(hwnd)) {
        return false;
    }
    let ok;
    unsafe {
        let _ = EmptyClipboard();
        match clip {
            Incoming::Text(text) => {
                let wide: Vec<u8> = text.replace('\n', "\r\n").encode_utf16().chain(std::iter::once(0)).flat_map(u16::to_le_bytes).collect();
                ok = set_clipboard_bytes(CF_UNICODETEXT.0 as u32, &wide);
            }
            Incoming::Image { png, dib } => {
                // PNG keeps transparency for programs that read it; the bitmap is for everything else
                ok = set_clipboard_bytes(png_format(), png);
                if let Some(dib) = dib {
                    set_clipboard_bytes(CF_DIB.0 as u32, dib);
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
            // our own write_clipboard lands here too; LAST already holds that content
            if GetClipboardOwner().ok() != Some(hwnd) {
                if let Some(clip) = read_clipboard() {
                    offer(clip);
                }
            }
            LRESULT(0)
        }
        WM_CLIP_SET => {
            let clip = PENDING.lock().unwrap().take();
            if let Some(clip) = clip {
                if write_clipboard(hwnd, &clip) {
                    *LAST.lock().unwrap() = Some(match clip {
                        Incoming::Text(text) => Synced::Text(text),
                        Incoming::Image { png, .. } => Synced::Image(hash(&png)),
                    });
                }
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
