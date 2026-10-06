//! Installing and managing the Omarchy WSL distro: `omarchy install | uninstall | status`, and the
//! first-run setup that `omarchy` runs when a freshly imported distro has not been set up yet.
//!
//! What `install` changes on Windows (and `uninstall` undoes):
//!  * the WSL distro itself (`wsl --install --from-file`, removed with `wsl --unregister`);
//!  * %LOCALAPPDATA%\Programs\Omarchy\omarchy.exe (+ omarchy.ico), and that folder on the user PATH;
//!  * a Start menu shortcut per distro: "Omarchy" (or "Omarchy (<distro>)").
//!
//! The user PATH is only ever extended or reduced by our one entry, never rewritten from a value we
//! could not read exactly; every previous value is appended to path-backup.txt next to omarchy.exe.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use windows::core::{Interface, HSTRING, PWSTR};
use windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, LPARAM, WPARAM};
use windows::Win32::Security::Cryptography::{
    BCryptCloseAlgorithmProvider, BCryptCreateHash, BCryptDestroyHash, BCryptFinishHash, BCryptHashData, BCryptOpenAlgorithmProvider,
    BCRYPT_ALG_HANDLE, BCRYPT_HASH_HANDLE, BCRYPT_OPEN_ALGORITHM_PROVIDER_FLAGS, BCRYPT_SHA256_ALGORITHM,
};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, IPersistFile, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED};
use windows::Win32::System::Registry::{
    RegCloseKey, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_READ, KEY_WRITE, REG_EXPAND_SZ, REG_SZ, REG_VALUE_TYPE,
};
use windows::Win32::UI::Shell::{FOLDERID_LocalAppData, FOLDERID_Programs, IShellLinkW, SHGetKnownFolderPath, ShellLink, KF_FLAG_DEFAULT};
use windows::Win32::UI::WindowsAndMessaging::{SendMessageTimeoutW, HWND_BROADCAST, SMTO_ABORTIFHUNG, SW_SHOWMINNOACTIVE, WM_SETTINGCHANGE};

/// Oldest WSL we support: the one we develop and test on. (2.5 already has the features we use, such as
/// `wslinfo --vm-id` and `--install --from-file --name`, but its kernel and WSLg are untested.) install.ps1
/// updates WSL to at least this version.
const MIN_WSL: [u32; 3] = [3, 0, 1];
const OOBE: &str = "/usr/lib/womarchy/oobe.sh";
const OOBE_DONE: &str = "/var/lib/womarchy/oobe-done";
const DEFAULT_DISTRO: &str = "Omarchy";
pub(crate) const ICON: &[u8] = include_bytes!("../../../linux/overlay/omarchy.ico");

/// wsl.exe with UTF-8 output (it writes UTF-16 to pipes otherwise).
pub(crate) fn wsl() -> Command {
    let mut c = Command::new("wsl.exe");
    c.env("WSL_UTF8", "1");
    c
}

fn wsl_output(args: &[&str]) -> Option<String> {
    let out = wsl().args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    Some(String::from_utf8_lossy(&out.stdout).replace('\0', ""))
}

/// Distro names we accept (they become paths and command arguments).
pub fn valid_distro_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 64 && name.bytes().all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c)) && !name.starts_with('.')
}

/// Installed WSL version from `wsl --version` (first a.b.c on the first line; the label is localized).
pub fn wsl_version() -> Option<[u32; 3]> {
    let text = wsl_output(&["--version"])?;
    let line = text.lines().next()?;
    let ver = line.split(|c: char| !(c.is_ascii_digit() || c == '.')).find(|s| s.matches('.').count() >= 2)?;
    let mut parts = ver.split('.').filter_map(|p| p.parse().ok());
    Some([parts.next()?, parts.next()?, parts.next()?])
}

pub fn distro_exists(name: &str) -> bool {
    wsl_output(&["--list", "--quiet"])
        .map(|t| t.lines().any(|l| l.trim().eq_ignore_ascii_case(name)))
        .unwrap_or(false)
}

/// Has the first-run setup (user, password, keyboard) completed in this distro? (Distros without our
/// OOBE, like development ones, count as set up.) `omarchy` itself learns this from the session
/// (WOMARCHY_NEEDS_SETUP) instead, so that a cold distro boots behind the "starting" windows.
pub fn setup_done(name: &str) -> bool {
    wsl()
        .args(["-d", name, "-u", "root", "--exec", "sh", "-c", &format!("test -f {} || ! test -e {}", OOBE_DONE, OOBE)])
        .stdin(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Run the first-run setup interactively in this console. WSL itself only runs the image's OOBE when a
/// shell is opened, never for `wsl --exec` (what omarchy.exe uses), so we run it here, then restart the
/// distro so the default user it wrote to /etc/wsl.conf applies.
pub fn run_setup(name: &str) -> bool {
    println!("Setting up Omarchy (first run): you'll pick a user name and password.\n");
    let ok = wsl().args(["-d", name, "-u", "root", "--exec", OOBE]).status().map(|s| s.success()).unwrap_or(false);
    let _ = wsl().args(["--terminate", name]).stdout(Stdio::null()).status();
    if !ok {
        eprintln!("omarchy: setup did not finish; run `omarchy` again to retry (log in the distro: /var/log/womarchy-oobe.log)");
    }
    ok
}

fn check_wsl() -> Result<(), String> {
    match wsl_version() {
        None => Err("WSL is not installed. In an administrator prompt run:  wsl --install --no-distribution\nthen restart Windows and run `omarchy install` again (or use install.ps1, which does this for you).".into()),
        Some(v) if v < MIN_WSL => Err(format!(
            "WSL {}.{}.{} is too old (need {}.{}.{} or newer). Run:  wsl --update",
            v[0], v[1], v[2], MIN_WSL[0], MIN_WSL[1], MIN_WSL[2]
        )),
        Some(_) => Ok(()),
    }
}

fn exe_dir() -> PathBuf {
    std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)).unwrap_or_default()
}

/// SHA-256 of a file (Windows CNG), lowercase hex.
fn sha256_file(path: &Path) -> Result<String, String> {
    use std::io::Read;
    let mut f = std::fs::File::open(path).map_err(|e| e.to_string())?;
    unsafe {
        let mut alg = BCRYPT_ALG_HANDLE::default();
        BCryptOpenAlgorithmProvider(&mut alg, BCRYPT_SHA256_ALGORITHM, None, BCRYPT_OPEN_ALGORITHM_PROVIDER_FLAGS(0)).ok().map_err(|e| e.to_string())?;
        let mut hash = BCRYPT_HASH_HANDLE::default();
        let created = BCryptCreateHash(alg, &mut hash, None, None, 0).ok();
        let result = (|| {
            created.map_err(|e| e.to_string())?;
            let mut buf = vec![0u8; 1 << 20];
            loop {
                let n = f.read(&mut buf).map_err(|e| e.to_string())?;
                if n == 0 {
                    break;
                }
                BCryptHashData(hash, &buf[..n], 0).ok().map_err(|e| e.to_string())?;
            }
            let mut digest = [0u8; 32];
            BCryptFinishHash(hash, &mut digest, 0).ok().map_err(|e| e.to_string())?;
            Ok(digest.iter().map(|b| format!("{:02x}", b)).collect())
        })();
        let _ = BCryptDestroyHash(hash);
        let _ = BCryptCloseAlgorithmProvider(alg, 0);
        result
    }
}

fn download(url: &str, dest: &Path) -> bool {
    Command::new("curl.exe")
        .args(["-L", "--fail", "--proto", "=https", "--progress-bar", "-o"])
        .arg(dest)
        .arg(url)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// The image to install: the argument (file or https URL), else an Omarchy*.wsl next to omarchy.exe.
/// (Local builds: no download fallback; images are built locally, see LOCAL-BUILD.md.) Downloads
/// are checked against the published SHA-256.
fn resolve_image(arg: Option<&str>) -> Result<(PathBuf, bool), String> {
    let source = match arg {
        Some(a) => a.to_string(),
        None => {
            let local = std::fs::read_dir(exe_dir()).ok().and_then(|rd| {
                rd.filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| {
                        let n = p.file_name().and_then(|n| n.to_str()).unwrap_or("").to_ascii_lowercase();
                        n.starts_with("omarchy") && n.ends_with(".wsl")
                    })
                    .max()
            });
            return match local {
                Some(p) => Ok((p, false)),
                None => Err("no image given: build one (LOCAL-BUILD.md) and run:  omarchy install PATH\\TO\\Omarchy.wsl".into()),
            };
        }
    };
    if source.starts_with("http://") {
        return Err("refusing to download over plain http; use an https URL".into());
    }
    if !source.starts_with("https://") {
        let p = PathBuf::from(&source);
        return if p.is_file() { Ok((p, false)) } else { Err(format!("{} not found", source)) };
    }

    let dir = std::env::temp_dir();
    let dest = dir.join("Omarchy-download.wsl");
    let sum_file = dir.join("Omarchy-download.wsl.sha256");
    println!("Downloading {} (about 1.7 GB) ...", source);
    if !download(&source, &dest) {
        let _ = std::fs::remove_file(&dest);
        return Err(format!(
            "download failed: {}\nDownload an Omarchy .wsl image yourself and run:  omarchy install PATH\\TO\\Omarchy.wsl",
            source
        ));
    }
    print!("Checking the download ... ");
    let _ = std::io::stdout().flush();
    let expected = if download(&format!("{}.sha256", source), &sum_file) {
        std::fs::read_to_string(&sum_file).ok().and_then(|s| s.split_whitespace().next().map(|h| h.to_ascii_lowercase()))
    } else {
        None
    };
    let _ = std::fs::remove_file(&sum_file);
    match expected {
        Some(want) => {
            let got = sha256_file(&dest)?;
            if got != want {
                let _ = std::fs::remove_file(&dest);
                return Err(format!("the download is corrupt (SHA-256 {} instead of {}); try again", got, want));
            }
            println!("ok");
        }
        None => println!("no checksum published next to it; not verified"),
    }
    Ok((dest, true))
}

pub struct InstallOptions {
    pub image: Option<String>,
    pub location: Option<String>,
    pub launcher_only: bool,
    /// distro + setup only: no omarchy.exe copy, PATH entry or Start menu shortcut (tests)
    pub no_launcher: bool,
}

pub fn install(name: &str, o: &InstallOptions) -> i32 {
    if !o.launcher_only {
        if let Err(e) = check_wsl() {
            eprintln!("omarchy: {}", e);
            return 1;
        }
        if distro_exists(name) {
            println!("The {} distro is already installed.", name);
        } else {
            let (image, downloaded) = match resolve_image(o.image.as_deref()) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("omarchy: {}", e);
                    return 1;
                }
            };
            println!("Installing {} from {} ...", name, image.display());
            let mut cmd = wsl();
            cmd.arg("--install").arg("--from-file").arg(&image).args(["--name", name, "--no-launch"]);
            if let Some(loc) = &o.location {
                cmd.args(["--location", loc]);
            }
            let ok = cmd.status().map(|s| s.success()).unwrap_or(false);
            if downloaded {
                let _ = std::fs::remove_file(&image);
            }
            if !ok {
                eprintln!("omarchy: wsl --install failed");
                return 1;
            }
        }
        if !setup_done(name) && !run_setup(name) {
            return 1;
        }
    }
    if o.no_launcher {
        println!("\n{} is ready (launcher not installed). Start it with:  omarchy --distro {}", name, name);
        return 0;
    }
    match install_launcher(name) {
        Ok(dir) => {
            println!("\nOmarchy is ready. Start it from the Start menu ({}) or by typing:  omarchy{}", shortcut_title(name), distro_arg(name));
            println!("(omarchy.exe is in {}; open a new terminal for PATH to pick it up)", dir.display());
            0
        }
        Err(e) => {
            eprintln!("omarchy: the distro is installed, but setting up the launcher failed: {}", e);
            1
        }
    }
}

pub(crate) fn known_folder(id: &windows::core::GUID) -> Result<PathBuf, String> {
    unsafe {
        let p: PWSTR = SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None).map_err(|e| e.to_string())?;
        let path = p.to_string().map_err(|e| e.to_string());
        CoTaskMemFree(Some(p.0 as *const _));
        Ok(PathBuf::from(path?))
    }
}

fn launcher_dir() -> Result<PathBuf, String> {
    Ok(known_folder(&FOLDERID_LocalAppData)?.join("Programs").join("Omarchy"))
}

fn shortcut_title(name: &str) -> String {
    if name.eq_ignore_ascii_case(DEFAULT_DISTRO) {
        "Omarchy".into()
    } else {
        format!("Omarchy ({})", name)
    }
}

fn distro_arg(name: &str) -> String {
    if name.eq_ignore_ascii_case(DEFAULT_DISTRO) {
        String::new()
    } else {
        format!(" --distro {}", name)
    }
}

fn start_menu_link(name: &str) -> Result<PathBuf, String> {
    Ok(known_folder(&FOLDERID_Programs)?.join(format!("{}.lnk", shortcut_title(name))))
}

/// Copy omarchy.exe to %LOCALAPPDATA%\Programs\Omarchy, put that on the user PATH and add the distro's
/// Start menu shortcut.
fn install_launcher(name: &str) -> Result<PathBuf, String> {
    let dir = launcher_dir()?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let exe = dir.join("omarchy.exe");
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    if !same_file(&me, &exe) {
        std::fs::copy(&me, &exe).map_err(|e| format!("copy to {}: {}", exe.display(), e))?;
    }
    let icon = dir.join("omarchy.ico");
    std::fs::write(&icon, ICON).map_err(|e| e.to_string())?;
    create_shortcut(&start_menu_link(name)?, &exe, distro_arg(name).trim(), &icon, "Omarchy desktop (Hyprland on WSL)")?;
    add_to_user_path(&dir)?;
    Ok(dir)
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

fn create_shortcut(link: &Path, target: &Path, args: &str, icon: &Path, description: &str) -> Result<(), String> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let sl: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).map_err(|e| e.to_string())?;
        sl.SetPath(&HSTRING::from(target.as_os_str())).map_err(|e| e.to_string())?;
        sl.SetArguments(&HSTRING::from(args)).map_err(|e| e.to_string())?;
        sl.SetIconLocation(&HSTRING::from(icon.as_os_str()), 0).map_err(|e| e.to_string())?;
        sl.SetDescription(&HSTRING::from(description)).map_err(|e| e.to_string())?;
        // the console only matters if something goes wrong (then omarchy.exe shows it)
        let _ = sl.SetShowCmd(SW_SHOWMINNOACTIVE);
        if let Some(d) = target.parent() {
            let _ = sl.SetWorkingDirectory(&HSTRING::from(d.as_os_str()));
        }
        let pf: IPersistFile = sl.cast().map_err(|e| e.to_string())?;
        pf.Save(&HSTRING::from(link.as_os_str()), true).map_err(|e| e.to_string())
    }
}

/// The user PATH from HKCU\Environment, raw (unexpanded) and exactly as stored, with its registry type;
/// Ok(None) if unset. Any other failure, or a value that isn't valid UTF-16, is an error: we never
/// rewrite a PATH we could not read exactly.
fn read_user_path() -> Result<Option<(String, REG_VALUE_TYPE)>, String> {
    unsafe {
        let mut key = HKEY::default();
        RegOpenKeyExW(HKEY_CURRENT_USER, &HSTRING::from("Environment"), None, KEY_READ, &mut key)
            .ok()
            .map_err(|e| format!("open HKCU\\Environment: {}", e))?;
        let name = HSTRING::from("Path");
        let mut ty = REG_VALUE_TYPE::default();
        let mut size = 0u32;
        let rc = RegQueryValueExW(key, &name, None, Some(&mut ty), None, Some(&mut size));
        if rc == ERROR_FILE_NOT_FOUND {
            let _ = RegCloseKey(key);
            return Ok(None);
        }
        if rc.is_err() || (ty != REG_SZ && ty != REG_EXPAND_SZ) {
            let _ = RegCloseKey(key);
            return Err(format!("cannot read the user PATH ({:?}, type {:?})", rc, ty));
        }
        let mut buf = vec![0u16; (size as usize).div_ceil(2) + 1];
        let mut got = (buf.len() * 2) as u32;
        let rc = RegQueryValueExW(key, &name, None, Some(&mut ty), Some(buf.as_mut_ptr() as *mut u8), Some(&mut got));
        let _ = RegCloseKey(key);
        rc.ok().map_err(|e| format!("cannot read the user PATH: {}", e))?;
        let n = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        let value = String::from_utf16(&buf[..n]).map_err(|_| "the user PATH is not valid UTF-16; not editing it".to_string())?;
        Ok(Some((value, ty)))
    }
}

fn write_user_path(old: &str, value: &str, ty: REG_VALUE_TYPE) -> Result<(), String> {
    // keep what we replace, in case anything ever goes wrong (append; never truncate the history)
    let dir = launcher_dir()?;
    let _ = std::fs::create_dir_all(&dir);
    let mut backup = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("path-backup.txt"))
        .map_err(|e| format!("cannot back up the user PATH: {}", e))?;
    writeln!(backup, "{}", old).map_err(|e| format!("cannot back up the user PATH: {}", e))?;
    unsafe {
        let mut key = HKEY::default();
        RegOpenKeyExW(HKEY_CURRENT_USER, &HSTRING::from("Environment"), None, KEY_WRITE, &mut key)
            .ok()
            .map_err(|e| e.to_string())?;
        let wide: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
        let bytes = std::slice::from_raw_parts(wide.as_ptr() as *const u8, wide.len() * 2);
        let rc = RegSetValueExW(key, &HSTRING::from("Path"), None, ty, Some(bytes));
        let _ = RegCloseKey(key);
        rc.ok().map_err(|e| e.to_string())?;
        // tell Explorer (and new terminals) that the environment changed
        let env: Vec<u16> = "Environment\0".encode_utf16().collect();
        let _ = SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, WPARAM(0), LPARAM(env.as_ptr() as isize), SMTO_ABORTIFHUNG, 2000, None);
        Ok(())
    }
}

fn same_dir(a: &str, b: &str) -> bool {
    a.trim().trim_end_matches('\\').eq_ignore_ascii_case(b.trim().trim_end_matches('\\'))
}

fn add_to_user_path(dir: &Path) -> Result<(), String> {
    let d = dir.to_string_lossy().to_string();
    let (current, ty) = read_user_path()?.unwrap_or((String::new(), REG_EXPAND_SZ));
    if current.split(';').any(|p| same_dir(p, &d)) {
        return Ok(());
    }
    let value = if current.trim().is_empty() { d } else { format!("{};{}", current.trim_end_matches(';'), d) };
    write_user_path(&current, &value, ty)
}

fn remove_from_user_path(dir: &Path) {
    let d = dir.to_string_lossy().to_string();
    if let Ok(Some((current, ty))) = read_user_path() {
        if !current.split(';').any(|p| same_dir(p, &d)) {
            return;
        }
        let value = current.split(';').filter(|p| !same_dir(p, &d)).collect::<Vec<_>>().join(";");
        let _ = write_user_path(&current, &value, ty);
    }
}

pub fn uninstall(name: &str, yes: bool) -> i32 {
    if distro_exists(name) {
        if !yes {
            println!("This deletes the {} WSL distro and everything in it (your Linux home directory included).", name);
            print!("Type the distro name ({}) to confirm: ", name);
            let _ = std::io::stdout().flush();
            let mut answer = String::new();
            let _ = std::io::stdin().read_line(&mut answer);
            if answer.trim() != name {
                println!("Cancelled.");
                return 1;
            }
        }
        if !wsl().args(["--unregister", name]).status().map(|s| s.success()).unwrap_or(false) {
            eprintln!("omarchy: wsl --unregister {} failed", name);
            return 1;
        }
        println!("Removed the {} distro.", name);
    } else {
        println!("No {} distro is installed.", name);
    }

    let Ok(programs) = known_folder(&FOLDERID_Programs) else { return 0 };
    // WSL leaves the distro's (now empty) Start menu folder behind; remove_dir only removes empty ones
    let _ = std::fs::remove_dir(programs.join(name));
    if let Ok(link) = start_menu_link(name) {
        let _ = std::fs::remove_file(link);
    }

    // the launcher is shared: remove it only when no Omarchy shortcut (no other distro) remains
    let others = std::fs::read_dir(&programs).map(|rd| {
        rd.filter_map(|e| e.ok()).any(|e| {
            let n = e.file_name().to_string_lossy().to_string();
            n.starts_with("Omarchy") && n.ends_with(".lnk")
        })
    });
    if others.unwrap_or(true) {
        return 0;
    }
    let Ok(dir) = launcher_dir() else { return 0 };
    remove_from_user_path(&dir);
    let _ = std::fs::remove_file(dir.join("omarchy.ico"));
    // a running exe can't delete itself; leave it if that's us
    let exe = dir.join("omarchy.exe");
    if std::env::current_exe().map(|m| same_file(&m, &exe)).unwrap_or(false) {
        println!("Delete {} yourself to finish (it is running).", dir.display());
    } else {
        let _ = std::fs::remove_file(&exe);
        let _ = std::fs::remove_dir(&dir); // keeps path-backup.txt (and the folder) if present
    }
    0
}

pub fn status(name: &str) -> i32 {
    println!("omarchy.exe:  {}", env!("CARGO_PKG_VERSION"));
    match wsl_version() {
        Some(v) => println!("WSL:          {}.{}.{}{}", v[0], v[1], v[2], if v < MIN_WSL { "  (too old: wsl --update)" } else { "" }),
        None => println!("WSL:          not installed"),
    }
    let omarchy_main = crate::monitors::enumerate().first().map(|m| m.name.clone());
    for s in crate::monitors::survey() {
        let m = &s.monitor;
        println!(
            "Monitor:      {:<8} {}x{} at {},{}  {} Hz  scale {}%{}{}{}  {}",
            m.name,
            m.width,
            m.height,
            m.x,
            m.y,
            m.refresh_mhz / 1000,
            m.scale_1000 / 10,
            if m.primary { "  (primary)" } else { "" },
            if omarchy_main.as_ref() == Some(&m.name) { "  [Omarchy main]" } else { "" },
            if s.skipped { "  [Windows only: OMARCHY_SKIP_MONITORS]" } else { "" },
            s.device
        );
    }
    if !distro_exists(name) {
        println!("Distro:       {} is not installed (omarchy install)", name);
        return 1;
    }
    println!("Distro:       {}", name);
    println!("Setup:        {}", if setup_done(name) { "done" } else { "not yet (runs on the next `omarchy`)" });
    let probe = "u=$(id -un); gpu=$([ -e /dev/dxg ] && echo yes || echo 'no (software rendering)'); \
                 shm=$(mountpoint -q /mnt/wslgshm && echo mounted || echo 'not mounted (slower inline frames)'); \
                 pk=$(pacman -Q hyprland aquamarine mesa womarchy-session 2>/dev/null | tr '\\n' ' '); \
                 printf 'User:         %s\\nGPU (dxg):    %s\\nShared mem:   %s\\nPackages:     %s\\n' \"$u\" \"$gpu\" \"$shm\" \"$pk\"";
    let _ = wsl().args(["-d", name, "--exec", "bash", "-c", probe]).stdin(Stdio::null()).status();
    if let Ok(link) = start_menu_link(name) {
        println!("Start menu:   {}", if link.exists() { link.display().to_string() } else { "no shortcut (omarchy install)".into() });
    }
    println!("Backup:       {}", crate::maintain::backup_summary(name));
    0
}
