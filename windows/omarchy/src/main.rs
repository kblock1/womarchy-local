//! omarchy.exe: start the Omarchy desktop (Hyprland in WSL2) full-screen on Windows, and return to the
//! prompt when the session ends. Also installs, removes and checks the Omarchy WSL distro.
//!
//!   omarchy [--distro NAME] [--user USER]                     start the desktop
//!   omarchy install [IMAGE.wsl|URL] [--distro NAME] [--location DIR] [--launcher-only | --no-launcher]
//!   omarchy uninstall [--distro NAME] [--yes]
//!   omarchy status [--distro NAME]
//!   omarchy update [--backup | --no-backup | --ask]           Omarchy's updater, after an optional full backup
//!   omarchy rollback [--list] [--to POINT] [--yes]            undo the package changes of an update
//!   omarchy backup [--to DIR] / omarchy restore [FILE]        the whole distro as one file
//! Development: --windowed WxH [--monitors N] [--scale S], --session PATH, --port N, --stats,
//! --dump-frame FILE [--dump-after FRAMES], --input-script FILE [--shot-dir DIR]
//!
//! How a session starts: we create one window per monitor, run `wsl.exe -d <distro> --exec
//! womarchy-session` with the session's secrets in the environment (WSLENV), read the VM id it prints,
//! connect to the compositor over hvsocket, check that it knows the token, and from then on show its
//! outputs and forward input until it says goodbye. See protocol/wdp.h and docs/ARCHITECTURE.md.

mod clip;
mod clipimage;
mod install;
mod keymap;
mod maintain;
mod monitors;
mod net;
mod script;
mod viewer;
mod wdp;

use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use windows::core::{HSTRING, BOOL};
use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, HANDLE, HWND, LPARAM};
use windows::Win32::Security::Cryptography::{BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG};
use windows::Win32::System::Console::{GetConsoleProcessList, GetConsoleWindow};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows::Win32::System::Threading::{CreateMutexW, GetCurrentProcessId};
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetWindowThreadProcessId, SetForegroundWindow, ShowWindow, SW_HIDE, SW_RESTORE, SW_SHOW,
};

/// womarchy-session's exit status when the distro's first-run setup has not run yet.
const SESSION_NEEDS_SETUP: i32 = 75;
/// How long to wait for the session to report its VM id, and for its compositor to accept us.
const STARTUP_TIMEOUT: Duration = Duration::from_secs(60);

struct Args {
    distro: String,
    user: Option<String>,
    windowed: Option<(u32, u32)>,
    max_monitors: Option<usize>,
    /// windowed mode only: the scale (e.g. 1.5) reported for the window outputs, to test HiDPI
    window_scale: f64,
    session: String,
    port: Option<u32>,
    stats: bool,
    dump_frame: Option<String>,
    dump_after: u64,
    input_script: Option<String>,
    shot_dir: Option<String>,
}

fn usage() -> ! {
    println!("usage: omarchy [--distro NAME] [--user USER]       start the Omarchy desktop (log out to come back here)");
    println!("       omarchy install [IMAGE.wsl|URL] [--distro NAME] [--location DIR] [--launcher-only | --no-launcher]");
    println!("       omarchy uninstall [--distro NAME] [--yes]");
    println!("       omarchy status [--distro NAME]                   what's installed and how it's doing (for bug reports)");
    println!("       omarchy update [--backup | --no-backup | --ask]   update Omarchy (asks once whether to back up first)");
    println!("       omarchy rollback [--list] [--to POINT] [--yes]   undo the package changes of the last update");
    println!("       omarchy backup [--to DIR]                        save the whole distro to one file (newest kept)");
    println!("       omarchy restore [FILE] [--yes]                   replace the distro with a backup");
    println!("development: --windowed WxH [--monitors N] [--scale S], --session PATH, --port N, --stats,");
    println!("             --dump-frame FILE [--dump-after FRAMES], --input-script FILE [--shot-dir DIR]");
    println!("Ctrl+Alt+End minimises the desktop. OMARCHY_DISTRO sets the default distro name (Omarchy).");
    println!("OMARCHY_SKIP_MONITORS leaves monitors to Windows: DISPLAYn names or parts of their device paths");
    println!("(e.g. DISPLAY4,UID4100), separated by commas; `omarchy status` lists both for each monitor.");
    println!("OMARCHY_MAIN_MONITOR picks Omarchy's main monitor (workspace 1) the same way; default: Windows' primary.");
    println!("omarchy --version prints this program's version.");
    std::process::exit(0)
}

fn bad_arg(what: &str) -> ! {
    eprintln!("omarchy: {} (see omarchy --help)", what);
    std::process::exit(2)
}

fn parse_args() -> Args {
    let mut a = Args {
        distro: default_distro(),
        user: None,
        windowed: None,
        max_monitors: None,
        window_scale: 1.0,
        session: "/usr/bin/womarchy-session".into(),
        port: None,
        stats: false,
        dump_frame: None,
        dump_after: 60,
        input_script: None,
        shot_dir: None,
    };
    let mut it = std::env::args_os().skip(1).map(|a| a.to_string_lossy().into_owned());
    while let Some(arg) = it.next() {
        let mut value = |name: &str| it.next().unwrap_or_else(|| bad_arg(&format!("{} needs a value", name)));
        match arg.as_str() {
            "--distro" | "-d" => a.distro = value("--distro"),
            "--user" | "-u" => a.user = Some(value("--user")),
            "--windowed" => {
                let v = value("--windowed");
                a.windowed = v
                    .split_once('x')
                    .and_then(|(w, h)| Some((w.parse().ok()?, h.parse().ok()?)))
                    .filter(|&(w, h): &(u32, u32)| (64..=wdp::MAX_DIMENSION).contains(&w) && (64..=wdp::MAX_DIMENSION).contains(&h));
                if a.windowed.is_none() {
                    bad_arg("--windowed takes WIDTHxHEIGHT, e.g. 1600x900");
                }
            }
            "--monitors" => a.max_monitors = Some(value("--monitors").parse().unwrap_or_else(|_| bad_arg("--monitors takes a number"))),
            "--scale" => a.window_scale = value("--scale").parse().unwrap_or_else(|_| bad_arg("--scale takes a number, e.g. 1.5")),
            "--session" => a.session = value("--session"),
            "--port" => a.port = Some(value("--port").parse().unwrap_or_else(|_| bad_arg("--port takes a number"))),
            "--stats" => a.stats = true,
            "--input-script" => a.input_script = Some(value("--input-script")),
            "--shot-dir" => a.shot_dir = Some(value("--shot-dir")),
            "--dump-frame" => a.dump_frame = Some(value("--dump-frame")),
            "--dump-after" => a.dump_after = value("--dump-after").parse().unwrap_or_else(|_| bad_arg("--dump-after takes a number of frames")),
            "-h" | "--help" => usage(),
            "-V" | "--version" => {
                println!("omarchy {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0)
            }
            other => bad_arg(&format!("unknown argument: {}", other)),
        }
    }
    a
}

fn random_bytes<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    unsafe {
        let _ = BCryptGenRandom(None, &mut b, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    }
    b
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}

fn default_distro() -> String {
    std::env::var("OMARCHY_DISTRO").unwrap_or_else(|_| "Omarchy".into())
}

/// `omarchy install|uninstall|status|update|rollback|backup|restore ...`; returns None when the first
/// argument is not a subcommand.
fn subcommand() -> Option<i32> {
    let argv: Vec<String> = std::env::args_os().skip(1).map(|a| a.to_string_lossy().into_owned()).collect();
    let cmd = argv.first()?.clone();
    if !["install", "uninstall", "status", "update", "rollback", "backup", "restore"].contains(&cmd.as_str()) {
        return None;
    }
    let mut distro = default_distro();
    let mut opts = install::InstallOptions { image: None, location: None, launcher_only: false, no_launcher: false };
    let mut yes = false;
    let mut backup_choice = None;
    let mut ask_again = false;
    let mut file: Option<String> = None; // install: image; restore: backup file
    let mut to: Option<String> = None;
    let mut passthrough = Vec::new(); // rollback: handed to womarchy-rollback
    let mut it = argv.into_iter().skip(1);
    while let Some(a) = it.next() {
        match (cmd.as_str(), a.as_str()) {
            (_, "--distro" | "-d") => distro = it.next().unwrap_or(distro),
            ("rollback", _) => passthrough.push(a),
            ("install", "--location") => opts.location = it.next(),
            ("install", "--launcher-only") => opts.launcher_only = true,
            ("install", "--no-launcher") => opts.no_launcher = true,
            ("uninstall" | "restore", "--yes" | "-y") => yes = true,
            ("update", "--backup") => backup_choice = Some(true),
            ("update", "--no-backup") => backup_choice = Some(false),
            ("update", "--ask") => ask_again = true,
            ("backup", "--to") => to = it.next(),
            ("install" | "restore", other) if !other.starts_with('-') && file.is_none() => file = Some(other.to_string()),
            (_, other) => {
                eprintln!("omarchy {}: unknown argument: {} (omarchy --help)", cmd, other);
                return Some(2);
            }
        }
    }
    if !install::valid_distro_name(&distro) {
        eprintln!("omarchy: '{}' is not a valid distro name (letters, digits, '.', '_', '-')", distro);
        return Some(2);
    }
    opts.image = file.clone();
    Some(match cmd.as_str() {
        "install" => install::install(&distro, &opts),
        "uninstall" => install::uninstall(&distro, yes),
        "update" => maintain::update(&distro, backup_choice, ask_again),
        "rollback" => maintain::rollback(&distro, &passthrough),
        "backup" => maintain::backup(&distro, to.as_deref()),
        "restore" => maintain::restore(&distro, file.as_deref(), yes),
        _ => install::status(&distro),
    })
}

/// Started from Explorer or the Start menu, we own a fresh console window nobody needs to look at.
/// (A relaunch after first-run setup inherits that fact through OMARCHY_OWN_CONSOLE.)
fn own_console() -> bool {
    let mut pids = [0u32; 4];
    std::env::var("OMARCHY_OWN_CONSOLE").is_ok_and(|v| v == "1") || unsafe { GetConsoleProcessList(&mut pids) == 1 }
}

fn set_console_visible(visible: bool) {
    unsafe {
        let h = GetConsoleWindow();
        if !h.is_invalid() {
            let _ = ShowWindow(h, if visible { SW_SHOW } else { SW_HIDE });
        }
    }
}

/// Report a fatal error (and keep a console we own open long enough to read it).
fn fail(hidden_console: bool, msg: &str) -> ! {
    eprintln!("omarchy: {}", msg);
    if hidden_console {
        set_console_visible(true);
        pause();
    }
    std::process::exit(1)
}

fn pause() {
    eprintln!("\nPress Enter to close.");
    let mut s = String::new();
    let _ = std::io::stdin().read_line(&mut s);
}

/// Keep wsl.exe (and so the session's Windows side) from outliving us, however we exit.
fn kill_with_us(child: &std::process::Child) {
    use std::os::windows::io::AsRawHandle;
    unsafe {
        let Ok(job) = CreateJobObjectW(None, None) else { return };
        let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let _ = SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &info as *const _ as *const _,
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        );
        let _ = AssignProcessToJobObject(job, HANDLE(child.as_raw_handle()));
        // the job handle stays open until this process exits
    }
}

/// One desktop per distro: if it is already running (e.g. minimised with Ctrl+Alt+End), bring its
/// windows back instead of starting a second session, which would replace the first.
fn already_running(distro: &str) -> bool {
    unsafe {
        let name = HSTRING::from(format!("Local\\omarchy-viewer-{}", distro.to_ascii_lowercase()));
        let mutex = CreateMutexW(None, true, &name);
        if mutex.is_err() || GetLastError() != ERROR_ALREADY_EXISTS {
            std::mem::forget(mutex); // held until we exit
            return false;
        }
        unsafe extern "system" fn restore(h: HWND, _: LPARAM) -> BOOL {
            let mut class = [0u16; 32];
            let n = GetClassNameW(h, &mut class) as usize;
            let mut pid = 0u32;
            GetWindowThreadProcessId(h, Some(&mut pid));
            if String::from_utf16_lossy(&class[..n]) == "OmarchyViewer" && pid != GetCurrentProcessId() {
                let _ = ShowWindow(h, SW_RESTORE);
                let _ = SetForegroundWindow(h);
            }
            BOOL(1)
        }
        let _ = EnumWindows(Some(restore), LPARAM(0));
        true
    }
}

/// The monitors to show: the real ones, or (development) N windows side by side.
fn initial_monitors(args: &Args) -> Vec<wdp::Monitor> {
    let mut mons = if let Some((w, h)) = args.windowed {
        let primary = monitors::enumerate().into_iter().find(|m| m.primary);
        (0..args.max_monitors.unwrap_or(1).clamp(1, wdp::MAX_MONITORS))
            .map(|i| wdp::Monitor {
                id: i as u32 + 1,
                x: (i as u32 * w) as i32,
                y: 0,
                width: w,
                height: h,
                refresh_mhz: primary.as_ref().map(|m| m.refresh_mhz).unwrap_or(60000),
                scale_1000: (args.window_scale * 1000.0).round().clamp(250.0, 8000.0) as u32,
                primary: i == 0,
                name: format!("window{}", i + 1),
            })
            .collect()
    } else {
        monitors::enumerate()
    };
    mons.truncate(args.max_monitors.unwrap_or(wdp::MAX_MONITORS).clamp(1, wdp::MAX_MONITORS));
    mons
}

/// Windows display settings changed mid-session (resolution, scale, monitors added/removed): move the
/// windows, tell the compositor, and have the session regenerate its monitor rules. The rules are
/// rewritten by one worker in order, newest layout last.
fn watch_display_changes(args: &Args, current: Arc<Mutex<Vec<wdp::Monitor>>>) {
    let (tx, rx) = mpsc::channel::<String>();
    let (distro, user, session) = (args.distro.clone(), args.user.clone(), args.session.clone());
    thread::spawn(move || {
        while let Ok(mut env) = rx.recv() {
            while let Ok(newer) = rx.try_recv() {
                env = newer; // only the latest layout matters
            }
            let wslenv = std::env::var("WSLENV").unwrap_or_default();
            let mut cmd = Command::new("wsl.exe");
            cmd.arg("-d").arg(&distro);
            if let Some(u) = &user {
                cmd.arg("-u").arg(u);
            }
            let _ = cmd
                .args(["--exec", &session, "--update-monitors"])
                .env("WOMARCHY_MONITORS", env)
                .env("WSLENV", format!("{}{}WOMARCHY_MONITORS/u", wslenv, if wslenv.is_empty() { "" } else { ":" }))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .status();
        }
    });

    let max = args.max_monitors;
    viewer::on_display_change(Box::new(move || {
        let mut cur = current.lock().unwrap();
        let mut now = monitors::keep_ids(&cur, monitors::enumerate());
        now.truncate(max.unwrap_or(wdp::MAX_MONITORS).clamp(1, wdp::MAX_MONITORS));
        if now.is_empty() || *cur == now {
            return;
        }
        eprintln!("[omarchy] display layout changed: {}", monitors::to_env(&now));
        viewer::reconcile_windows(&now);
        viewer::send(wdp::monitors(&now)); // dropped if not connected yet; the connect step sends `current`
        let _ = tx.send(monitors::to_env(&now));
        *cur = now;
    }));
}

/// Connect to the compositor, check it knows the token, then run the display side of the session.
fn run_display(vm: String, port: u32, token: [u8; wdp::TOKEN_BYTES], clip_token: [u8; wdp::TOKEN_BYTES], current: Arc<Mutex<Vec<wdp::Monitor>>>, opts: viewer::RenderOptions) -> Result<(), String> {
    let vm_guid = net::parse_guid(&vm).ok_or_else(|| format!("the session reported a bad VM id: {}", vm))?;
    eprintln!("[omarchy] session VM {}, connecting to port {}", vm, port);
    let start = Instant::now();
    let conn = loop {
        match net::Conn::connect(vm_guid, port) {
            Ok(c) => break c,
            Err(_) if start.elapsed() < STARTUP_TIMEOUT => thread::sleep(Duration::from_millis(100)),
            Err(e) => return Err(format!("could not connect to the desktop: {}", e)),
        }
    };

    // Handshake: our half of the token in HELLO; the compositor must answer with the other half. It
    // answers once its event loop runs, which on a cold start (3 4K outputs, nothing cached) can be
    // well after it started listening: allow the rest of the startup time.
    conn.set_recv_timeout(Some(STARTUP_TIMEOUT.saturating_sub(start.elapsed()).max(Duration::from_secs(10))));
    conn.send_msg(&wdp::hello(&token, (1 << wdp::TRANSPORT_INLINE) | (1 << wdp::TRANSPORT_SECTION))).map_err(|e| e.to_string())?;
    let mut payload = Vec::new();
    let ty = conn.recv_msg(&mut payload).map_err(|e| format!("the desktop did not answer: {}", e))?;
    let mut r = wdp::Reader::new(&payload);
    let (version, transport, vm_id, proof) = (r.u32(), r.u32(), r.str_fixed(40), r.take(wdp::PROOF_BYTES));
    if ty != wdp::WELCOME || version != Some(wdp::VERSION) || !wdp::proves(&token, proof.unwrap_or(&[])) {
        return Err("the program on the desktop's port did not prove it is our session; not sending it any input".into());
    }
    conn.set_recv_timeout(None);
    let transport = transport.unwrap_or(wdp::TRANSPORT_INLINE);
    let vm_id = vm_id.unwrap_or_default();
    if net::parse_guid(&vm_id).is_none() && transport == wdp::TRANSPORT_SECTION {
        return Err("the desktop sent an invalid VM id".into());
    }
    eprintln!(
        "[omarchy] connected after {:.1} s; transport = {}",
        start.elapsed().as_secs_f64(),
        if transport == wdp::TRANSPORT_SECTION { "shared memory" } else { "inline" }
    );

    {
        // the layout may have changed while we connected: send what is current, then go live
        let cur = current.lock().unwrap();
        conn.send_msg(&wdp::monitors(&cur)).map_err(|e| e.to_string())?;
        viewer::start_input(conn.clone());
    }
    clip::start(vm_guid, port + wdp::CLIP_PORT_OFFSET, clip_token);
    viewer::run_session(conn, transport, vm_id, opts)
}

fn main() {
    // first thing: monitor geometry and DPI are only reported in physical pixels to DPI-aware processes
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    if let Some(rc) = subcommand() {
        std::process::exit(rc);
    }
    let args = parse_args();
    let hidden_console = own_console();

    // installed? (cheap; whether first-run setup is done is answered by the session itself, so a cold
    // distro boots behind our "starting" windows instead of before them)
    if !install::valid_distro_name(&args.distro) {
        fail(hidden_console, &format!("'{}' is not a valid distro name", args.distro));
    }
    if !install::distro_exists(&args.distro) {
        fail(hidden_console, &format!("the {} WSL distro is not installed. Run:  omarchy install", args.distro));
    }
    if already_running(&args.distro) {
        eprintln!("omarchy: the desktop is already running; switched to it");
        std::process::exit(0);
    }
    if hidden_console {
        set_console_visible(false);
    }
    net::init();

    let mons = initial_monitors(&args);
    if mons.is_empty() {
        fail(hidden_console, "no monitors found");
    }
    let current = Arc::new(Mutex::new(mons.clone()));
    let token: [u8; wdp::TOKEN_BYTES] = random_bytes();
    let clip_token: [u8; wdp::TOKEN_BYTES] = random_bytes();
    let port = args.port.unwrap_or_else(|| 50000 + (u32::from_le_bytes(random_bytes::<4>()) % 10000));

    viewer::create_windows(&mons, args.windowed.is_some());
    viewer::start_keyboard_hook();
    clip::init();
    if args.windowed.is_none() {
        watch_display_changes(&args, current.clone());
    }

    // --- start the session inside WSL; its secrets travel via WSLENV, never on a command line
    let wslenv = std::env::var("WSLENV").unwrap_or_default();
    let mut cmd = Command::new("wsl.exe");
    cmd.arg("-d").arg(&args.distro);
    if let Some(u) = &args.user {
        cmd.arg("-u").arg(u);
    }
    cmd.arg("--exec").arg(&args.session);
    cmd.env("WOMARCHY_TOKEN", hex(&token))
        .env("WOMARCHY_CLIP_TOKEN", hex(&clip_token))
        .env("WOMARCHY_VSOCK_PORT", port.to_string())
        .env("WOMARCHY_MONITORS", monitors::to_env(&mons))
        .env(
            "WSLENV",
            format!(
                "{}{}WOMARCHY_TOKEN/u:WOMARCHY_CLIP_TOKEN/u:WOMARCHY_VSOCK_PORT/u:WOMARCHY_MONITORS/u",
                wslenv,
                if wslenv.is_empty() { "" } else { ":" }
            ),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => fail(hidden_console, &format!("failed to start wsl.exe: {}", e)),
    };
    kill_with_us(&child);

    // session stdout: the handshake line "WOMARCHY_VMID=<guid>" (or WOMARCHY_NEEDS_SETUP); the rest is log
    let (vm_tx, vm_rx) = mpsc::channel::<String>();
    let needs_setup = Arc::new(AtomicBool::new(false));
    let stdout = child.stdout.take().unwrap();
    let reader = {
        let needs_setup = needs_setup.clone();
        thread::spawn(move || {
            let mut r = BufReader::new(stdout);
            let mut line = Vec::new();
            while r.read_until(b'\n', &mut line).is_ok_and(|n| n > 0) {
                let text = String::from_utf8_lossy(&line);
                let text = text.trim();
                if let Some(v) = text.strip_prefix("WOMARCHY_VMID=") {
                    let _ = vm_tx.send(v.trim().to_string());
                } else if text == "WOMARCHY_NEEDS_SETUP" {
                    needs_setup.store(true, Ordering::SeqCst);
                } else if !text.is_empty() {
                    eprintln!("{}", text);
                }
                line.clear();
            }
        })
    };

    // the session's lifetime is ours: when wsl.exe exits, so do we (after its output is read)
    let exit_code = Arc::new(AtomicI32::new(0));
    {
        let exit_code = exit_code.clone();
        thread::spawn(move || {
            let status = child.wait().ok().and_then(|s| s.code()).unwrap_or(1);
            let _ = reader.join();
            exit_code.store(status, Ordering::SeqCst);
            viewer::post_quit();
        });
    }

    // connect once the VM id is known and the compositor listens
    let error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    {
        let error = error.clone();
        let opts = viewer::RenderOptions {
            dump_frame: args.dump_frame.clone(),
            dump_after: args.dump_after,
            stats: args.stats,
            script: args.input_script.clone().map(|file| script::Options {
                file,
                distro: args.distro.clone(),
                user: args.user.clone(),
                shot_dir: args.shot_dir.clone(),
            }),
        };
        thread::spawn(move || {
            // (no VM id also when the session exits early, e.g. for first-run setup: then the
            // child-wait thread ends the message loop)
            let Ok(vm) = vm_rx.recv_timeout(STARTUP_TIMEOUT) else { return };
            if let Err(e) = run_display(vm, port, token, clip_token, current, opts) {
                *error.lock().unwrap() = Some(e);
                viewer::post_quit();
            }
        });
    }

    viewer::run_message_loop();
    viewer::stop_keyboard_hook();

    let rc = exit_code.load(Ordering::SeqCst);
    if rc == SESSION_NEEDS_SETUP && needs_setup.load(Ordering::SeqCst) {
        // freshly installed distro: run its first-run setup here in the console, then start over
        viewer::hide_windows();
        set_console_visible(true);
        if !install::run_setup(&args.distro) {
            pause();
            std::process::exit(1);
        }
        let me = std::env::current_exe().expect("current_exe");
        let mut again = Command::new(me);
        again.args(std::env::args_os().skip(1));
        if hidden_console {
            again.env("OMARCHY_OWN_CONSOLE", "1");
        }
        let status = again.status();
        std::process::exit(status.ok().and_then(|s| s.code()).unwrap_or(1));
    }
    if let Some(e) = error.lock().unwrap().take() {
        fail(hidden_console, &e); // the session (wsl.exe) is killed with us (job object)
    }
    if rc != 0 && hidden_console {
        // nobody would see why otherwise
        set_console_visible(true);
        pause();
    }
    std::process::exit(rc);
}
