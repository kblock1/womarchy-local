//! Keeping an installed Omarchy distro healthy: `omarchy update | rollback | backup | restore`.
//!
//! Three levels of "undo", from cheap to complete:
//!  * rollback: the distro records its installed package list before every update (a pacman hook, a
//!    few kilobytes). `womarchy-rollback` puts those package versions back, from pacman's cache, the
//!    local [womarchy] repository or the online archives. Seconds, almost no disk. Always available.
//!  * backup / restore: the whole distro as one file (`wsl --export` / `wsl --import`). Takes a few
//!    minutes and about as much disk as the distro uses; only the newest backup per distro is kept.
//!    Covers everything, including the home directory.
//!  * starting over: `omarchy uninstall`, then `omarchy install`.
//!
//! `update` runs Omarchy's own updater inside the distro (the same as "Update System" in the desktop).
//! Whether it makes a full backup first is asked once and remembered in %LOCALAPPDATA%\Omarchy\settings.txt;
//! `--backup` / `--no-backup` decide for one run, `--ask` asks again.

use crate::install::{distro_exists, known_folder, wsl};
use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Instant;
use windows::core::{HSTRING, PWSTR};
use windows::Win32::Foundation::{CloseHandle, ERROR_SUCCESS};
use windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
use windows::Win32::System::Registry::{RegCloseKey, RegEnumKeyExW, RegGetValueW, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, KEY_READ, RRF_RT_REG_SZ};
use windows::Win32::System::SystemInformation::GetLocalTime;
use windows::Win32::System::Threading::{OpenMutexW, SYNCHRONIZATION_SYNCHRONIZE};
use windows::Win32::UI::Shell::FOLDERID_LocalAppData;

const SETTING_BACKUP: &str = "backup-before-update";
const ROLLBACK: &str = "/usr/bin/womarchy-rollback";

/// %LOCALAPPDATA%\Omarchy: settings and the default backup folder (not the launcher's Programs folder).
fn data_dir() -> PathBuf {
    known_folder(&FOLDERID_LocalAppData).map(|p| p.join("Omarchy")).unwrap_or_else(|_| PathBuf::from("."))
}

fn backup_dir() -> PathBuf {
    data_dir().join("backups")
}

fn setting(key: &str) -> Option<String> {
    let text = std::fs::read_to_string(data_dir().join("settings.txt")).ok()?;
    text.lines().find_map(|l| l.strip_prefix(key)?.strip_prefix('=').map(|v| v.trim().to_string()))
}

fn set_setting(key: &str, value: &str) {
    let path = data_dir().join("settings.txt");
    let old = std::fs::read_to_string(&path).unwrap_or_default();
    let mut lines: Vec<String> = old.lines().filter(|l| !l.starts_with(&format!("{}=", key))).map(String::from).collect();
    lines.push(format!("{}={}", key, value));
    let _ = std::fs::create_dir_all(data_dir());
    if std::fs::write(&path, lines.join("\n") + "\n").is_err() {
        eprintln!("omarchy: could not save the setting in {}", path.display());
    }
}

/// Is a desktop session of this distro running (omarchy.exe holds a named mutex per distro)?
fn desktop_running(distro: &str) -> bool {
    let name = HSTRING::from(format!("Local\\omarchy-viewer-{}", distro.to_ascii_lowercase()));
    match unsafe { OpenMutexW(SYNCHRONIZATION_SYNCHRONIZE, false, &name) } {
        Ok(h) => {
            let _ = unsafe { CloseHandle(h) };
            true
        }
        Err(_) => false,
    }
}

/// " --distro NAME" unless it's the default distro (for commands we suggest).
fn distro_arg(distro: &str) -> String {
    if distro.eq_ignore_ascii_case(&crate::default_distro()) { String::new() } else { format!(" --distro {}", distro) }
}

fn gb(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1e9)
}

/// Bytes in use on the distro's root filesystem: about the size of a backup (starts the distro).
fn used_bytes(distro: &str) -> Option<u64> {
    let out = wsl().args(["-d", distro, "--exec", "df", "-B1", "--output=used", "/"]).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    String::from_utf8_lossy(&out.stdout).lines().nth(1)?.trim().parse().ok()
}

fn free_bytes(dir: &Path) -> Option<u64> {
    let mut free = 0u64;
    unsafe { GetDiskFreeSpaceExW(&HSTRING::from(dir.as_os_str()), Some(&mut free), None, None).ok()? };
    Some(free)
}

fn timestamp() -> String {
    let t = unsafe { GetLocalTime() };
    format!("{:04}{:02}{:02}-{:02}{:02}{:02}", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond)
}

/// This distro's backups in a folder, oldest first ("<distro>-<yyyymmdd-hhmmss>.tar" sorts by time).
fn backups(dir: &Path, distro: &str) -> Vec<PathBuf> {
    let prefix = format!("{}-", distro.to_ascii_lowercase());
    let mut found: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| {
                    let n = p.file_name().and_then(|n| n.to_str()).unwrap_or("").to_ascii_lowercase();
                    n.starts_with(&prefix) && n.ends_with(".tar")
                })
                .collect()
        })
        .unwrap_or_default();
    found.sort();
    found
}

fn ask(question: &str) -> String {
    print!("{}", question);
    let _ = std::io::stdout().flush();
    let mut answer = String::new();
    let _ = std::io::stdin().read_line(&mut answer);
    answer.trim().to_string()
}

/// Where WSL keeps this distro's virtual disk (HKCU\...\Lxss\{guid}\BasePath), to restore into.
fn distro_location(distro: &str) -> Option<PathBuf> {
    unsafe {
        let mut lxss = HKEY::default();
        RegOpenKeyExW(HKEY_CURRENT_USER, &HSTRING::from("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss"), None, KEY_READ, &mut lxss).ok().ok()?;
        let read = |sub: &str, value: &str| -> Option<String> {
            let mut buf = vec![0u16; 1024];
            let mut size = (buf.len() * 2) as u32;
            let rc = RegGetValueW(lxss, &HSTRING::from(sub), &HSTRING::from(value), RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut _), Some(&mut size));
            (rc == ERROR_SUCCESS).then(|| String::from_utf16_lossy(&buf[..(size as usize / 2).saturating_sub(1)]))
        };
        let mut found = None;
        for i in 0.. {
            let mut name = [0u16; 128];
            let mut len = name.len() as u32;
            if RegEnumKeyExW(lxss, i, Some(PWSTR(name.as_mut_ptr())), &mut len, None, None, None, None) != ERROR_SUCCESS {
                break;
            }
            let sub = String::from_utf16_lossy(&name[..len as usize]);
            if read(&sub, "DistributionName").is_some_and(|n| n.eq_ignore_ascii_case(distro)) {
                found = read(&sub, "BasePath").map(|p| PathBuf::from(p.trim_start_matches("\\\\?\\")));
                break;
            }
        }
        let _ = RegCloseKey(lxss);
        found
    }
}

/// `omarchy backup [--to DIR]`: export the distro to one file and keep only the newest.
pub fn backup(distro: &str, to: Option<&str>) -> i32 {
    if !distro_exists(distro) {
        eprintln!("omarchy: the {} distro is not installed", distro);
        return 1;
    }
    if desktop_running(distro) {
        eprintln!("omarchy: the desktop is running; log out of it first (a backup needs the distro stopped)");
        return 1;
    }
    let dir = to.map(PathBuf::from).unwrap_or_else(backup_dir);
    if let Err(e) = std::fs::create_dir_all(&dir) {
        eprintln!("omarchy: cannot create {}: {}", dir.display(), e);
        return 1;
    }
    let used = used_bytes(distro);
    if let (Some(used), Some(free)) = (used, free_bytes(&dir)) {
        if free < used + used / 10 {
            eprintln!("omarchy: not enough free space in {} ({} free, the backup needs about {})", dir.display(), gb(free), gb(used));
            return 1;
        }
    }
    let file = dir.join(format!("{}-{}.tar", distro, timestamp()));
    println!("Backing up {} ({}) to {} ...", distro, used.map(gb).unwrap_or_else(|| "size unknown".into()), file.display());
    println!("(This stops the {} distro: close any of its terminals first. A note that sockets can't be archived is harmless.)", distro);
    let start = Instant::now();
    let _ = wsl().args(["--terminate", distro]).stdout(Stdio::null()).status();
    if !wsl().arg("--export").arg(distro).arg(&file).status().is_ok_and(|s| s.success()) {
        let _ = std::fs::remove_file(&file);
        eprintln!("omarchy: wsl --export failed; no backup was made");
        return 1;
    }
    for old in backups(&dir, distro).into_iter().filter(|p| *p != file) {
        let _ = std::fs::remove_file(old);
    }
    let size = std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
    println!("Backup done in {} s ({}): {}", start.elapsed().as_secs(), gb(size), file.display());
    println!("Restore it with:  omarchy restore{}", distro_arg(distro));
    0
}

/// `omarchy restore [FILE] [--yes]`: replace the distro with a backup (the newest one by default).
pub fn restore(distro: &str, file: Option<&str>, yes: bool) -> i32 {
    let file = match file {
        Some(f) => PathBuf::from(f),
        None => match backups(&backup_dir(), distro).pop() {
            Some(f) => f,
            None => {
                eprintln!("omarchy: no backup of {} in {} (make one with: omarchy backup)", distro, backup_dir().display());
                return 1;
            }
        },
    };
    if !file.is_file() {
        eprintln!("omarchy: {} not found", file.display());
        return 1;
    }
    if desktop_running(distro) {
        eprintln!("omarchy: the desktop is running; log out of it first");
        return 1;
    }
    let size = std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
    let exists = distro_exists(distro);
    if exists && !yes {
        println!("This replaces the {} distro with the backup {} ({}).", distro, file.display(), gb(size));
        println!("Everything changed in {} since that backup is lost.", distro);
        if ask(&format!("Type the distro name ({}) to confirm: ", distro)) != distro {
            println!("Cancelled.");
            return 1;
        }
    }
    let location = distro_location(distro).unwrap_or_else(|| data_dir().join("distros").join(distro));
    if exists {
        let _ = wsl().args(["--terminate", distro]).stdout(Stdio::null()).status();
        if !wsl().args(["--unregister", distro]).stdout(Stdio::null()).status().is_ok_and(|s| s.success()) {
            eprintln!("omarchy: wsl --unregister {} failed; nothing was changed", distro);
            return 1;
        }
    }
    println!("Restoring {} from {} into {} ...", distro, file.display(), location.display());
    let _ = std::fs::create_dir_all(&location);
    let start = Instant::now();
    if !wsl().arg("--import").arg(distro).arg(&location).arg(&file).status().is_ok_and(|s| s.success()) {
        eprintln!("omarchy: wsl --import failed. The backup file is untouched; run `omarchy restore` again.");
        return 1;
    }
    println!("Restored in {} s. Start it with:  omarchy{}", start.elapsed().as_secs(), distro_arg(distro));
    0
}

/// `omarchy rollback [ARGS]`: undo the package changes of the last update (womarchy-rollback in the distro).
pub fn rollback(distro: &str, args: &[String]) -> i32 {
    if !distro_exists(distro) {
        eprintln!("omarchy: the {} distro is not installed", distro);
        return 1;
    }
    let present = wsl().args(["-d", distro, "-u", "root", "--exec", "test", "-x", ROLLBACK]).stdin(Stdio::null()).status().is_ok_and(|s| s.success());
    if !present {
        eprintln!("omarchy: this Omarchy install has no rollback support yet; it arrives with the next `omarchy update`");
        return 1;
    }
    wsl().args(["-d", distro, "-u", "root", "--exec", ROLLBACK]).args(args).status().ok().and_then(|s| s.code()).unwrap_or(1)
}

/// `omarchy update [--backup | --no-backup | --ask]`: optional full backup, then Omarchy's updater.
pub fn update(distro: &str, backup_choice: Option<bool>, ask_again: bool) -> i32 {
    if !distro_exists(distro) {
        eprintln!("omarchy: the {} distro is not installed (omarchy install)", distro);
        return 1;
    }
    // Omarchy's updater asks questions (confirm, sudo password, conflicts); without a terminal its
    // prompts spin instead of failing
    if !std::io::stdin().is_terminal() {
        eprintln!("omarchy: run `omarchy update` in a terminal window: the updater asks questions");
        return 2;
    }
    let remembered = if ask_again { None } else { setting(SETTING_BACKUP).map(|v| v == "yes") };
    let backup_first = match backup_choice.or(remembered) {
        Some(b) => b,
        None => {
            let size = used_bytes(distro).map(gb).unwrap_or_else(|| "several GB".into());
            println!("Updates can be undone in two ways:");
            println!("  * `omarchy rollback` puts back the package versions from before the update.");
            println!("    It's always available and costs almost nothing.");
            println!("  * A full backup before each update (`omarchy restore` brings back everything, your files");
            println!("    included). It takes a few minutes and about {} of disk; only the newest is kept.", size);
            let yes = ask("Make a full backup before each update? [y/N] ").to_ascii_lowercase().starts_with('y');
            set_setting(SETTING_BACKUP, if yes { "yes" } else { "no" });
            println!("Remembered. (`omarchy update --ask` asks again; --backup / --no-backup decide for one update.)\n");
            yes
        }
    };
    if backup_first {
        if desktop_running(distro) {
            eprintln!("omarchy: the desktop is running and a backup needs the distro stopped.");
            eprintln!("Log out of the desktop first, or update without a backup:  omarchy update --no-backup");
            return 1;
        }
        let rc = backup(distro, None);
        if rc != 0 {
            eprintln!("omarchy: the backup failed, so nothing was updated");
            return rc;
        }
    }
    println!("Updating {} with Omarchy's updater (it may ask for your Linux password) ...\n", distro);
    let rc = wsl().args(["-d", distro, "--cd", "~", "--exec", "bash", "-lc", "omarchy-update"]).status().ok().and_then(|s| s.code()).unwrap_or(1);
    if rc != 0 {
        eprintln!("\nomarchy: the update did not finish (exit code {}).", rc);
        eprintln!("If it broke something: `omarchy rollback` restores the previous packages{}.", if backup_first { ", `omarchy restore` the whole distro" } else { "" });
    }
    rc
}

/// One line for `omarchy status`: the newest full backup, if any.
pub fn backup_summary(distro: &str) -> String {
    match backups(&backup_dir(), distro).pop() {
        Some(f) => format!("{} ({})", f.display(), gb(std::fs::metadata(&f).map(|m| m.len()).unwrap_or(0))),
        None => format!("none (full backups: omarchy backup; before each update: {})", if setting(SETTING_BACKUP).as_deref() == Some("yes") { "on" } else { "off" }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backups_are_found_per_distro_and_sorted_by_time() {
        let dir = std::env::temp_dir().join(format!("omarchy-backup-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for n in ["Omarchy-20261001-120000.tar", "Omarchy-20260930-090000.tar", "Other-20261002-000000.tar", "Omarchy-notes.txt"] {
            std::fs::write(dir.join(n), b"x").unwrap();
        }
        let names: Vec<String> = backups(&dir, "Omarchy").iter().map(|p| p.file_name().unwrap().to_string_lossy().into_owned()).collect();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(names, ["Omarchy-20260930-090000.tar", "Omarchy-20261001-120000.tar"]);
    }

    #[test]
    fn timestamps_sort_as_text() {
        let t = timestamp();
        assert_eq!(t.len(), 15);
        assert_eq!(&t[8..9], "-");
    }
}
