//! WDP (womarchy display protocol) v2: the Rust side of protocol/wdp.h (read that for the semantics).
//! Little-endian, packed; every message is an 8-byte header (type, size) plus the payload.

pub const VERSION: u32 = 2;
pub const TOKEN_BYTES: usize = 32;
pub const PROOF_BYTES: usize = 16;
pub const NAME_BYTES: usize = 96;
pub const CLIP_PORT_OFFSET: u32 = 1;

pub const MAX_MONITORS: usize = 16;
pub const MAX_DIMENSION: u32 = 16384;
pub const MAX_RECTS: usize = 64;
pub const MAX_CURSOR: u32 = 256;
pub const MAX_MESSAGE: usize = 64 << 20;

// viewer -> compositor
pub const HELLO: u32 = 1;
pub const MONITORS: u32 = 2;
pub const FRAME_DONE: u32 = 3;
pub const OUTPUT_VISIBLE: u32 = 4;
pub const REFRESH: u32 = 5;
pub const KEY: u32 = 10;
pub const POINTER_ABS: u32 = 11;
pub const POINTER_BUTTON: u32 = 13;
pub const POINTER_AXIS: u32 = 14;
pub const POINTER_FRAME: u32 = 15;
pub const FOCUS: u32 = 16;
pub const QUIT: u32 = 20;

// compositor -> viewer
pub const WELCOME: u32 = 100;
pub const OUTPUT: u32 = 101;
pub const OUTPUT_REMOVED: u32 = 102;
pub const FRAME: u32 = 103;
pub const CURSOR: u32 = 104;
pub const BYE: u32 = 110;

// clipboard channel (to womarchy-clipd on port + CLIP_PORT_OFFSET)
pub const CLIP_HELLO: u32 = 200;
pub const CLIP_TEXT: u32 = 201;
pub const CLIP_WELCOME: u32 = 202;

pub const TRANSPORT_INLINE: u32 = 1;
pub const TRANSPORT_SECTION: u32 = 2;

/// A monitor the viewer shows (`wdp_monitor`, 96 bytes on the wire).
#[derive(Clone, Debug, PartialEq)]
pub struct Monitor {
    pub id: u32,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub refresh_mhz: u32,
    pub scale_1000: u32,
    pub primary: bool,
    pub name: String,
}

/// Little-endian message writer.
pub struct Msg {
    buf: Vec<u8>,
}

impl Msg {
    pub fn new(ty: u32) -> Self {
        let mut m = Msg { buf: Vec::with_capacity(64) };
        m.u32(ty).u32(0); // size, patched in finish()
        m
    }
    pub fn u32(&mut self, v: u32) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn i32(&mut self, v: i32) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn u64(&mut self, v: u64) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn f64(&mut self, v: f64) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn bytes(&mut self, b: &[u8]) -> &mut Self {
        self.buf.extend_from_slice(b);
        self
    }
    pub fn fixed_str(&mut self, s: &str, len: usize) -> &mut Self {
        let mut b = s.as_bytes().to_vec();
        b.truncate(len - 1);
        b.resize(len, 0);
        self.buf.extend_from_slice(&b);
        self
    }
    pub fn finish(mut self) -> Vec<u8> {
        let size = (self.buf.len() - 8) as u32;
        self.buf[4..8].copy_from_slice(&size.to_le_bytes());
        self.buf
    }
}

/// The viewer's half of the session token goes in HELLO; the compositor must answer with the other half.
pub fn hello(token: &[u8; TOKEN_BYTES], transports: u32) -> Vec<u8> {
    let mut m = Msg::new(HELLO);
    m.u32(VERSION).bytes(&token[..PROOF_BYTES]).u32(transports);
    m.finish()
}

pub fn monitors(mons: &[Monitor]) -> Vec<u8> {
    let mut m = Msg::new(MONITORS);
    m.u32(mons.len().min(MAX_MONITORS) as u32);
    for mon in mons.iter().take(MAX_MONITORS) {
        m.u32(mon.id).i32(mon.x).i32(mon.y).u32(mon.width).u32(mon.height).u32(mon.refresh_mhz).u32(mon.scale_1000).u32(mon.primary as u32);
        m.fixed_str(&mon.name, 64);
    }
    m.finish()
}

pub fn frame_done(output: u32, seq: u64, present_ns: u64) -> Vec<u8> {
    let mut m = Msg::new(FRAME_DONE);
    m.u32(output).u32(0).u64(seq).u64(present_ns);
    m.finish()
}

pub fn output_visible(output: u32, visible: bool) -> Vec<u8> {
    let mut m = Msg::new(OUTPUT_VISIBLE);
    m.u32(output).u32(visible as u32);
    m.finish()
}

pub fn refresh(output: u32) -> Vec<u8> {
    let mut m = Msg::new(REFRESH);
    m.u32(output);
    m.finish()
}

pub fn key(time_ms: u32, key: u32, pressed: bool) -> Vec<u8> {
    let mut m = Msg::new(KEY);
    m.u32(time_ms).u32(key).u32(pressed as u32);
    m.finish()
}

/// Pointer motion and the frame that ends it, as one buffer (one send).
pub fn pointer_abs_frame(time_ms: u32, output: u32, x: f64, y: f64) -> Vec<u8> {
    let mut m = Msg::new(POINTER_ABS);
    m.u32(time_ms).u32(output).f64(x).f64(y);
    let mut out = m.finish();
    out.extend_from_slice(&pointer_frame());
    out
}

pub fn pointer_button(time_ms: u32, button: u32, pressed: bool) -> Vec<u8> {
    let mut m = Msg::new(POINTER_BUTTON);
    m.u32(time_ms).u32(button).u32(pressed as u32);
    let mut out = m.finish();
    out.extend_from_slice(&pointer_frame());
    out
}

pub fn pointer_axis(time_ms: u32, axis: u32, delta: f64, discrete120: i32) -> Vec<u8> {
    let mut m = Msg::new(POINTER_AXIS);
    m.u32(time_ms).u32(axis).f64(delta).i32(discrete120);
    let mut out = m.finish();
    out.extend_from_slice(&pointer_frame());
    out
}

pub fn pointer_frame() -> Vec<u8> {
    Msg::new(POINTER_FRAME).finish()
}

pub fn focus(focused: bool) -> Vec<u8> {
    let mut m = Msg::new(FOCUS);
    m.u32(focused as u32);
    m.finish()
}

pub fn quit() -> Vec<u8> {
    let mut m = Msg::new(QUIT);
    m.u32(0);
    m.finish()
}

pub fn clip_hello(token: &[u8; TOKEN_BYTES]) -> Vec<u8> {
    let mut m = Msg::new(CLIP_HELLO);
    m.u32(VERSION).bytes(&token[..PROOF_BYTES]);
    m.finish()
}

pub fn clip_text(text: &[u8]) -> Vec<u8> {
    let mut m = Msg::new(CLIP_TEXT);
    m.bytes(text);
    m.finish()
}

/// Does a WELCOME/CLIP_WELCOME's proof match the second half of our token? (constant time)
pub fn proves(token: &[u8; TOKEN_BYTES], proof: &[u8]) -> bool {
    proof.len() == PROOF_BYTES && proof.iter().zip(&token[PROOF_BYTES..]).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

/// Little-endian reader over a message payload.
pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Reader { data, pos: 0 }
    }
    pub fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let s = self.data.get(self.pos..self.pos.checked_add(n)?)?;
        self.pos += n;
        Some(s)
    }
    pub fn u32(&mut self) -> Option<u32> {
        self.take(4).map(|b| u32::from_le_bytes(b.try_into().unwrap()))
    }
    pub fn i32(&mut self) -> Option<i32> {
        self.take(4).map(|b| i32::from_le_bytes(b.try_into().unwrap()))
    }
    pub fn u64(&mut self) -> Option<u64> {
        self.take(8).map(|b| u64::from_le_bytes(b.try_into().unwrap()))
    }
    pub fn str_fixed(&mut self, len: usize) -> Option<String> {
        self.take(len).map(|b| {
            let end = b.iter().position(|&c| c == 0).unwrap_or(b.len());
            String::from_utf8_lossy(&b[..end]).into_owned()
        })
    }
    pub fn rest(&self) -> &'a [u8] {
        &self.data[self.pos..]
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

#[derive(Debug)]
pub struct Frame {
    pub output: u32,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub seq: u64,
    /// SECTION: the buffer file's leaf name (validated: [A-Za-z0-9._-]+)
    pub buffer: String,
    /// validated to lie inside width x height
    pub rects: Vec<Rect>,
}

/// The output a FRAME is for, without parsing the rest (for routing).
pub fn frame_output(payload: &[u8]) -> Option<u32> {
    Reader::new(payload).u32()
}

/// Parse and validate a FRAME: sizes within limits, stride covering a row, every rectangle inside the
/// buffer, a plain file name. Anything else is rejected rather than trusted.
pub fn parse_frame(r: &mut Reader) -> Option<Frame> {
    let output = r.u32()?;
    let width = r.u32()?;
    let height = r.u32()?;
    let stride = r.u32()?;
    let _format = r.u32()?;
    let seq = r.u64()?;
    let buffer = r.str_fixed(NAME_BYTES)?;
    let n = r.u32()? as usize;
    if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION || (stride as u64) < width as u64 * 4 {
        return None;
    }
    if n > MAX_RECTS || n * 16 > r.rest().len() {
        return None;
    }
    if !buffer.is_empty() && !buffer.bytes().all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c)) {
        return None;
    }
    let mut rects = Vec::with_capacity(n);
    for _ in 0..n {
        let (x, y, w, h) = (r.i32()?, r.i32()?, r.i32()?, r.i32()?);
        if x < 0 || y < 0 || w <= 0 || h <= 0 || x as u64 + w as u64 > width as u64 || y as u64 + h as u64 > height as u64 {
            return None;
        }
        rects.push(Rect { x: x as u32, y: y as u32, w: w as u32, h: h as u32 });
    }
    Some(Frame { output, width, height, stride, seq, buffer, rects })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token() -> [u8; TOKEN_BYTES] {
        std::array::from_fn(|i| i as u8 + 1)
    }

    /// A FRAME payload as the compositor sends it (header fields, buffer name, rectangles).
    fn frame(width: u32, height: u32, stride: u32, name: &str, rects: &[(i32, i32, i32, i32)]) -> Vec<u8> {
        let mut m = Msg::new(FRAME);
        m.u32(1).u32(width).u32(height).u32(stride).u32(0).u64(7).fixed_str(name, NAME_BYTES).u32(rects.len() as u32);
        for &(x, y, w, h) in rects {
            m.i32(x).i32(y).i32(w).i32(h);
        }
        m.finish()[8..].to_vec() // payload only (without the 8-byte header)
    }

    fn parse(payload: &[u8]) -> Option<Frame> {
        parse_frame(&mut Reader::new(payload))
    }

    #[test]
    fn handshake_proofs() {
        let t = token();
        let h = hello(&t, 1 << TRANSPORT_SECTION);
        // HELLO payload: version, our half of the token, transports
        assert_eq!(&h[12..12 + PROOF_BYTES], &t[..PROOF_BYTES]);
        assert!(proves(&t, &t[PROOF_BYTES..]));
        assert!(!proves(&t, &t[..PROOF_BYTES]), "our own half must not count as the compositor's proof");
        assert!(!proves(&t, &t[PROOF_BYTES..TOKEN_BYTES - 1]), "short proof");
        assert!(!proves(&t, &[]));
    }

    #[test]
    fn valid_frames_parse() {
        let f = parse(&frame(3840, 2160, 3840 * 4, "womarchy-1-2-3840x2160", &[(0, 0, 3840, 2160), (10, 20, 30, 40)])).unwrap();
        assert_eq!((f.output, f.width, f.height, f.seq), (1, 3840, 2160, 7));
        assert_eq!(f.buffer, "womarchy-1-2-3840x2160");
        assert_eq!(f.rects.len(), 2);
        assert_eq!((f.rects[1].x, f.rects[1].y, f.rects[1].w, f.rects[1].h), (10, 20, 30, 40));
        // "nothing changed" frames have no rectangles
        assert!(parse(&frame(800, 600, 3200, "", &[])).unwrap().rects.is_empty());
    }

    #[test]
    fn invalid_frames_are_rejected() {
        let ok = |w, h, s| frame(w, h, s, "buf", &[(0, 0, 1, 1)]);
        assert!(parse(&ok(0, 600, 3200)).is_none(), "zero width");
        assert!(parse(&ok(MAX_DIMENSION + 1, 600, (MAX_DIMENSION + 1) * 4)).is_none(), "too wide");
        assert!(parse(&ok(800, 600, 800 * 4 - 1)).is_none(), "stride shorter than a row");
        for r in [(-1, 0, 1, 1), (0, 0, 0, 1), (0, 0, 801, 1), (799, 0, 2, 1), (0, 599, 1, 2), (i32::MAX, 0, i32::MAX, 1)] {
            assert!(parse(&frame(800, 600, 3200, "buf", &[r])).is_none(), "rectangle {:?} outside 800x600", r);
        }
        for name in ["../etc", "a/b", r"a\b", "x y", "x:y"] {
            assert!(parse(&frame(800, 600, 3200, name, &[])).is_none(), "buffer name {:?}", name);
        }
        let many = vec![(0, 0, 1, 1); MAX_RECTS + 1];
        assert!(parse(&frame(800, 600, 3200, "buf", &many)).is_none(), "too many rectangles");
    }

    #[test]
    fn truncated_frames_are_rejected() {
        let full = frame(800, 600, 3200, "buf", &[(0, 0, 10, 10), (5, 5, 10, 10)]);
        for len in 0..full.len() {
            assert!(parse(&full[..len]).is_none(), "accepted a frame cut at {} of {} bytes", len, full.len());
        }
        assert!(parse(&full).is_some());
    }
}
