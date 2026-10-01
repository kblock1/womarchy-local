//! Clipboard images: PNG (what crosses to Linux) <-> the Windows clipboard's device-independent
//! bitmaps (CF_DIB), using the Windows Imaging Component, so every BMP/PNG variant Windows itself
//! understands works and no image library is bundled.

use windows::core::{Interface, GUID};
use windows::Win32::Graphics::Imaging::{
    CLSID_WICImagingFactory, GUID_ContainerFormatPng, GUID_WICPixelFormat32bppBGRA, IWICBitmapFrameEncode, IWICImagingFactory, WICBitmapEncoderNoCache,
    WICConvertBitmapSource, WICDecodeMetadataCacheOnDemand,
};
use windows::Win32::System::Com::StructuredStorage::IPropertyBag2;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, IStream, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, STATSTG, STATFLAG_NONAME, STREAM_SEEK_SET};
use windows::Win32::UI::Shell::SHCreateMemStream;

const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";
const BMP_FILE_HEADER: usize = 14;
const BITMAPINFOHEADER: usize = 40;

pub fn is_png(data: &[u8]) -> bool {
    data.starts_with(PNG_SIGNATURE)
}

fn factory() -> windows::core::Result<IWICImagingFactory> {
    unsafe {
        // COM may already be initialised on this thread (in either model): fine either way
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)
    }
}

/// Decode any image WIC understands into top-down 32-bit BGRA (straight alpha): (width, height, pixels).
fn decode(data: &[u8]) -> windows::core::Result<(u32, u32, Vec<u8>)> {
    unsafe {
        let wic = factory()?;
        let stream = wic.CreateStream()?;
        stream.InitializeFromMemory(data)?;
        let decoder = wic.CreateDecoderFromStream(&stream, std::ptr::null(), WICDecodeMetadataCacheOnDemand)?;
        let frame = decoder.GetFrame(0)?;
        let bgra = WICConvertBitmapSource(&GUID_WICPixelFormat32bppBGRA, &frame)?;
        let (mut w, mut h) = (0u32, 0u32);
        bgra.GetSize(&mut w, &mut h)?;
        let mut pixels = vec![0u8; w as usize * h as usize * 4];
        bgra.CopyPixels(std::ptr::null(), w * 4, &mut pixels)?;
        Ok((w, h, pixels))
    }
}

/// Encode top-down 32-bit BGRA pixels as PNG.
fn encode_png(w: u32, h: u32, pixels: &[u8]) -> windows::core::Result<Vec<u8>> {
    unsafe {
        let wic = factory()?;
        let out: IStream = SHCreateMemStream(None).ok_or_else(windows::core::Error::empty)?;
        let encoder = wic.CreateEncoder(&GUID_ContainerFormatPng, std::ptr::null())?;
        encoder.Initialize(&out, WICBitmapEncoderNoCache)?;
        let mut frame: Option<IWICBitmapFrameEncode> = None;
        let mut options: Option<IPropertyBag2> = None;
        encoder.CreateNewFrame(&mut frame, &mut options)?;
        let frame = frame.ok_or_else(windows::core::Error::empty)?;
        frame.Initialize(options.as_ref())?;
        frame.SetSize(w, h)?;
        let mut format: GUID = GUID_WICPixelFormat32bppBGRA;
        frame.SetPixelFormat(&mut format)?;
        frame.WritePixels(h, w * 4, pixels)?;
        frame.Commit()?;
        encoder.Commit()?;

        let mut stat = STATSTG::default();
        out.Stat(&mut stat, STATFLAG_NONAME)?;
        out.Seek(0, STREAM_SEEK_SET, None)?;
        let mut png = vec![0u8; stat.cbSize as usize];
        let mut read = 0u32;
        out.Read(png.as_mut_ptr() as *mut _, png.len() as u32, Some(&mut read)).ok()?;
        png.truncate(read as usize);
        let _ = out.cast::<windows::core::IUnknown>(); // keep the stream alive until here
        Ok(png)
    }
}

/// CF_DIB (BITMAPINFOHEADER + optional masks/palette + pixels) -> PNG.
pub fn png_from_dib(dib: &[u8]) -> Option<Vec<u8>> {
    if dib.len() < BITMAPINFOHEADER {
        return None;
    }
    let u32_at = |o: usize| u32::from_le_bytes(dib[o..o + 4].try_into().unwrap());
    let header = u32_at(0) as usize;
    let bits = u16::from_le_bytes(dib[14..16].try_into().unwrap()) as usize;
    let compression = u32_at(16);
    let used = u32_at(32) as usize;
    // where the pixels start: after the header, the BI_BITFIELDS masks (old headers only) and the palette
    let masks = if header == BITMAPINFOHEADER && (compression == 3 || compression == 6) { if compression == 3 { 12 } else { 16 } } else { 0 };
    let palette = if bits <= 8 { if used > 0 { used } else { 1 << bits } } else { used };
    let offset = header + masks + palette * 4;
    if header < BITMAPINFOHEADER || offset > dib.len() {
        return None;
    }
    // a .bmp file is the DIB with a 14-byte file header in front
    let mut bmp = Vec::with_capacity(BMP_FILE_HEADER + dib.len());
    bmp.extend_from_slice(b"BM");
    bmp.extend_from_slice(&((BMP_FILE_HEADER + dib.len()) as u32).to_le_bytes());
    bmp.extend_from_slice(&[0; 4]);
    bmp.extend_from_slice(&((BMP_FILE_HEADER + offset) as u32).to_le_bytes());
    bmp.extend_from_slice(dib);
    let (w, h, mut pixels) = decode(&bmp).ok()?;
    // 32-bit clipboard bitmaps usually carry no alpha (all zero): show them opaque, not invisible
    if bits == 32 && pixels.as_chunks::<4>().0.iter().all(|p| p[3] == 0) {
        pixels.as_chunks_mut::<4>().0.iter_mut().for_each(|p| p[3] = 255);
    }
    encode_png(w, h, &pixels).ok()
}

/// PNG -> CF_DIB: 32-bit bottom-up BI_RGB, which every Windows program reads (alpha in the fourth byte).
pub fn dib_from_png(png: &[u8]) -> Option<Vec<u8>> {
    let (w, h, pixels) = decode(png).ok()?;
    let row = w as usize * 4;
    let mut dib = Vec::with_capacity(BITMAPINFOHEADER + pixels.len());
    dib.extend_from_slice(&(BITMAPINFOHEADER as u32).to_le_bytes());
    dib.extend_from_slice(&(w as i32).to_le_bytes());
    dib.extend_from_slice(&(h as i32).to_le_bytes()); // positive: bottom-up rows
    dib.extend_from_slice(&1u16.to_le_bytes()); // planes
    dib.extend_from_slice(&32u16.to_le_bytes()); // bits per pixel
    dib.extend_from_slice(&0u32.to_le_bytes()); // BI_RGB
    dib.extend_from_slice(&(pixels.len() as u32).to_le_bytes());
    dib.extend_from_slice(&[0; 16]); // resolution, palette: unused
    for y in (0..h as usize).rev() {
        dib.extend_from_slice(&pixels[y * row..(y + 1) * row]);
    }
    Some(dib)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 3x2 image with distinct, partly transparent pixels.
    fn sample() -> (u32, u32, Vec<u8>) {
        let px: Vec<u8> = (0..6u8).flat_map(|i| [i * 40, 255 - i * 40, i * 10, 128 + i * 20]).collect();
        (3, 2, px)
    }

    #[test]
    fn png_round_trip_keeps_pixels() {
        let (w, h, px) = sample();
        let png = encode_png(w, h, &px).unwrap();
        assert!(is_png(&png));
        assert_eq!(decode(&png).unwrap(), (w, h, px));
    }

    #[test]
    fn dib_round_trip_keeps_colours() {
        let (w, h, px) = sample();
        let png = encode_png(w, h, &px).unwrap();
        let dib = dib_from_png(&png).unwrap();
        assert_eq!(dib.len(), BITMAPINFOHEADER + px.len());
        let (bw, bh, back) = decode(&png_from_dib(&dib).unwrap()).unwrap();
        assert_eq!((bw, bh), (w, h));
        // colours survive; alpha doesn't (BI_RGB bitmaps are read as opaque), which is why the
        // clipboard also gets the PNG itself
        for (a, b) in px.as_chunks::<4>().0.iter().zip(back.as_chunks::<4>().0.iter()) {
            assert_eq!((&a[..3], b[3]), (&b[..3], 255));
        }
    }

    #[test]
    fn opaque_32bit_dibs_without_alpha_stay_visible() {
        let (w, h, mut px) = sample();
        px.as_chunks_mut::<4>().0.iter_mut().for_each(|p| p[3] = 0);
        let png = encode_png(w, h, &px).unwrap();
        let mut dib = dib_from_png(&png).unwrap();
        // what many programs put on the clipboard: 32-bit BI_RGB with the alpha bytes all zero
        dib[BITMAPINFOHEADER..].as_chunks_mut::<4>().0.iter_mut().for_each(|p| p[3] = 0);
        let (_, _, back) = decode(&png_from_dib(&dib).unwrap()).unwrap();
        assert!(back.as_chunks::<4>().0.iter().all(|p| p[3] == 255));
    }

    #[test]
    fn garbage_is_rejected() {
        assert!(png_from_dib(&[0u8; 10]).is_none());
        assert!(dib_from_png(b"not a png").is_none());
        assert!(!is_png(b"GIF89a"));
    }
}
