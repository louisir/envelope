use image::{Rgba, RgbaImage};
use sha2::{Digest, Sha256};
use std::path::Path;
use thiserror::Error;

const MAGIC: &[u8; 4] = b"ENV1";
const HEADER_LEN: usize = 4 + 8 + 32;

#[derive(Debug, Error)]
pub enum StegoError {
    #[error("carrier capacity is {capacity} bytes, payload needs {needed} bytes")]
    Capacity { capacity: usize, needed: usize },
    #[error("carrier does not contain a Envelope payload")]
    MissingPayload,
    #[error("embedded payload hash mismatch")]
    HashMismatch,
    #[error("embedded payload length is too large")]
    PayloadTooLarge,
    #[error("image error: {0}")]
    Image(#[from] image::ImageError),
}

pub type Result<T> = std::result::Result<T, StegoError>;

pub fn embed_png_file(
    cover_path: impl AsRef<Path>,
    payload: &[u8],
    output_path: impl AsRef<Path>,
) -> Result<()> {
    let image = image::open(cover_path)?.to_rgba8();
    let embedded = embed_payload(image, payload)?;
    embedded.save(output_path)?;
    Ok(())
}

pub fn extract_png_file(input_path: impl AsRef<Path>) -> Result<Vec<u8>> {
    let image = image::open(input_path)?.to_rgba8();
    extract_payload(&image)
}

pub fn embed_payload(image: RgbaImage, payload: &[u8]) -> Result<RgbaImage> {
    let framed = frame_payload(payload);
    let capacity = capacity_bytes(image.width(), image.height());
    if framed.len() > capacity {
        return Err(StegoError::Capacity {
            capacity,
            needed: framed.len(),
        });
    }

    let width = image.width();
    let height = image.height();
    let mut raw = image.into_raw();
    write_bits(&mut raw, &framed);
    Ok(RgbaImage::from_raw(width, height, raw).expect("raw RGBA dimensions remain valid"))
}

pub fn extract_payload(image: &RgbaImage) -> Result<Vec<u8>> {
    let capacity = capacity_bytes(image.width(), image.height());
    if capacity < HEADER_LEN {
        return Err(StegoError::MissingPayload);
    }

    let raw = image.as_raw();
    let header = read_bytes(raw, HEADER_LEN);
    if &header[..4] != MAGIC {
        return Err(StegoError::MissingPayload);
    }

    let mut len_bytes = [0u8; 8];
    len_bytes.copy_from_slice(&header[4..12]);
    let payload_len = u64::from_be_bytes(len_bytes);
    let payload_len: usize = payload_len
        .try_into()
        .map_err(|_| StegoError::PayloadTooLarge)?;

    let total_len = HEADER_LEN
        .checked_add(payload_len)
        .ok_or(StegoError::PayloadTooLarge)?;
    if total_len > capacity {
        return Err(StegoError::Capacity {
            capacity,
            needed: total_len,
        });
    }

    let framed = read_bytes(raw, total_len);
    let payload = framed[HEADER_LEN..].to_vec();
    let expected_hash = &framed[12..44];
    let actual_hash = Sha256::digest(&payload);
    if expected_hash != actual_hash.as_slice() {
        return Err(StegoError::HashMismatch);
    }

    Ok(payload)
}

pub fn capacity_bytes(width: u32, height: u32) -> usize {
    (width as usize * height as usize * 3) / 8
}

pub fn create_demo_cover(output_path: impl AsRef<Path>, width: u32, height: u32) -> Result<()> {
    let mut image = RgbaImage::new(width, height);
    for y in 0..height {
        for x in 0..width {
            let r = ((x * 255) / width.max(1)) as u8;
            let g = ((y * 255) / height.max(1)) as u8;
            let b = (((x + y) * 255) / (width + height).max(1)) as u8;
            image.put_pixel(x, y, Rgba([r, g, b, 255]));
        }
    }
    image.save(output_path)?;
    Ok(())
}

fn frame_payload(payload: &[u8]) -> Vec<u8> {
    let mut framed = Vec::with_capacity(HEADER_LEN + payload.len());
    framed.extend_from_slice(MAGIC);
    framed.extend_from_slice(&(payload.len() as u64).to_be_bytes());
    framed.extend_from_slice(&Sha256::digest(payload));
    framed.extend_from_slice(payload);
    framed
}

fn write_bits(raw: &mut [u8], data: &[u8]) {
    for bit_index in 0..(data.len() * 8) {
        let byte = data[bit_index / 8];
        let bit = (byte >> (7 - (bit_index % 8))) & 1;
        let channel_index = bit_index;
        let pixel_index = channel_index / 3;
        let color_index = channel_index % 3;
        let raw_index = pixel_index * 4 + color_index;
        raw[raw_index] = (raw[raw_index] & 0b1111_1110) | bit;
    }
}

fn read_bytes(raw: &[u8], byte_count: usize) -> Vec<u8> {
    let mut out = vec![0u8; byte_count];
    for bit_index in 0..(byte_count * 8) {
        let channel_index = bit_index;
        let pixel_index = channel_index / 3;
        let color_index = channel_index % 3;
        let raw_index = pixel_index * 4 + color_index;
        let bit = raw[raw_index] & 1;
        out[bit_index / 8] |= bit << (7 - (bit_index % 8));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_round_trip() {
        let image = RgbaImage::from_pixel(128, 128, Rgba([20, 40, 60, 255]));
        let payload = b"hello envelope";
        let embedded = embed_payload(image, payload).unwrap();
        let extracted = extract_payload(&embedded).unwrap();
        assert_eq!(extracted, payload);
    }
}
