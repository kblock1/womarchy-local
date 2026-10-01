//! Hyper-V socket (AF_HYPERV) client: connects to an AF_VSOCK listener inside the WSL2 VM.
//! Any process of the interactive user may connect to the WSL VM; no admin rights needed.

use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use windows::core::GUID;
use windows::Win32::Networking::WinSock::*;

const AF_HYPERV: u16 = 34;
const HV_PROTOCOL_RAW: i32 = 1;
const HVSOCKET_CONNECT_TIMEOUT: i32 = 1;

#[repr(C)]
struct SockAddrHv {
    family: u16,
    reserved: u16,
    vm_id: GUID,
    service_id: GUID,
}

pub fn init() {
    let mut data = WSADATA::default();
    unsafe {
        WSAStartup(0x0202, &mut data);
    }
}

/// The WSL convention for mapping a vsock port to an hvsocket service id.
pub fn vsock_service_id(port: u32) -> GUID {
    GUID::from_values(port, 0xFACB, 0x11E6, [0xBD, 0x58, 0x64, 0x00, 0x6A, 0x79, 0x86, 0xD3])
}

pub fn parse_guid(s: &str) -> Option<GUID> {
    let h: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if h.len() != 32 {
        return None;
    }
    let v = u128::from_str_radix(&h, 16).ok()?;
    Some(GUID::from_u128(v))
}

struct Inner {
    sock: SOCKET,
    send_lock: Mutex<()>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        unsafe {
            closesocket(self.sock);
        }
    }
}

/// A connected stream; clones share the socket, which closes when the last clone is dropped.
#[derive(Clone)]
pub struct Conn(Arc<Inner>);

// SOCKET is a plain handle; sends are serialized by send_lock and only one thread receives.
unsafe impl Send for Inner {}
unsafe impl Sync for Inner {}

impl Conn {
    pub fn connect(vm_id: GUID, port: u32) -> io::Result<Conn> {
        unsafe {
            let sock = socket(AF_HYPERV as i32, SOCK_STREAM, HV_PROTOCOL_RAW).map_err(|e| io::Error::other(e.to_string()))?;
            let conn = Conn(Arc::new(Inner { sock, send_lock: Mutex::new(()) }));
            // Without this, connecting before the listener exists blocks for the long default timeout
            // instead of failing fast, which defeats the caller's retry loop.
            let timeout_ms: u32 = 1000;
            let _ = setsockopt(sock, HV_PROTOCOL_RAW, HVSOCKET_CONNECT_TIMEOUT, Some(&timeout_ms.to_ne_bytes()));
            let addr = SockAddrHv { family: AF_HYPERV, reserved: 0, vm_id, service_id: vsock_service_id(port) };
            if connect(sock, &addr as *const _ as *const SOCKADDR, std::mem::size_of::<SockAddrHv>() as i32) != 0 {
                return Err(io::Error::new(io::ErrorKind::ConnectionRefused, format!("hvsocket connect failed: {:?}", WSAGetLastError())));
            }
            let big: i32 = 8 << 20;
            let _ = setsockopt(sock, SOL_SOCKET, SO_RCVBUF, Some(&big.to_ne_bytes()));
            let _ = setsockopt(sock, SOL_SOCKET, SO_SNDBUF, Some(&big.to_ne_bytes()));
            Ok(conn)
        }
    }

    /// Thread-safe: each call's bytes are written contiguously.
    pub fn send_msg(&self, data: &[u8]) -> io::Result<()> {
        let _g = self.0.send_lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut off = 0;
        while off < data.len() {
            let n = unsafe { send(self.0.sock, &data[off..], SEND_RECV_FLAGS(0)) };
            if n <= 0 {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "send failed"));
            }
            off += n as usize;
        }
        Ok(())
    }

    /// Receives time out after `t` (None: wait forever), e.g. while waiting for the peer's handshake.
    pub fn set_recv_timeout(&self, t: Option<Duration>) {
        let ms: u32 = t.map(|t| t.as_millis().clamp(1, u32::MAX as u128) as u32).unwrap_or(0);
        unsafe {
            let _ = setsockopt(self.0.sock, SOL_SOCKET, SO_RCVTIMEO, Some(&ms.to_ne_bytes()));
        }
    }

    fn recv_exact(&self, buf: &mut [u8]) -> io::Result<()> {
        let mut off = 0;
        while off < buf.len() {
            let n = unsafe { recv(self.0.sock, &mut buf[off..], SEND_RECV_FLAGS(0)) };
            if n == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "connection closed"));
            }
            if n < 0 {
                return Err(match unsafe { WSAGetLastError() } {
                    WSAETIMEDOUT => io::Error::new(io::ErrorKind::TimedOut, "timed out"),
                    e => io::Error::other(format!("receive failed: {:?}", e)),
                });
            }
            off += n as usize;
        }
        Ok(())
    }

    /// Reads one message into `payload` (reused between calls) and returns its type.
    pub fn recv_msg(&self, payload: &mut Vec<u8>) -> io::Result<u32> {
        let mut hdr = [0u8; 8];
        self.recv_exact(&mut hdr)?;
        let ty = u32::from_le_bytes(hdr[0..4].try_into().unwrap());
        let size = u32::from_le_bytes(hdr[4..8].try_into().unwrap()) as usize;
        if size > crate::wdp::MAX_MESSAGE {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "oversized message"));
        }
        payload.resize(size, 0);
        self.recv_exact(payload)?;
        Ok(ty)
    }

    /// Unblocks a receiver on another thread (the connection is finished).
    pub fn shutdown(&self) {
        unsafe {
            let _ = shutdown(self.0.sock, SD_BOTH);
        }
    }
}
