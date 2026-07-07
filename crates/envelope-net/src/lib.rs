use iroh::{Endpoint, EndpointAddr, RelayMode, endpoint::presets};
use iroh_tickets::endpoint::EndpointTicket;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::sync::OnceLock;
use std::time::Duration;
use thiserror::Error;

pub const NET_PROTOCOL_VERSION: u16 = 1;
pub const STATUS_OK: &str = "ok";
pub const STATUS_ERROR: &str = "error";
pub const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;
pub const ENVELOPE_IROH_ALPN: &[u8] = b"envelope/opaque-envelope/1";
const IROH_ONLINE_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeliveryAck {
    pub version: u16,
    pub status: String,
    pub envelope_id: String,
    pub detail: String,
}

#[derive(Debug, Clone)]
pub struct P2pEndpointInfo {
    pub endpoint_id: String,
    pub ticket: String,
    pub direct_addrs: Vec<String>,
    pub relay_urls: Vec<String>,
    pub online: bool,
}

#[derive(Debug, Error)]
pub enum NetError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("frame is too large: {0} bytes")]
    FrameTooLarge(usize),
    #[error("unsupported ack version {0}")]
    UnsupportedAckVersion(u16),
    #[error("delivery rejected: {0}")]
    DeliveryRejected(String),
    #[error("p2p error: {0}")]
    P2p(String),
    #[error("invalid p2p endpoint ticket: {0}")]
    InvalidP2pTicket(String),
}

pub type Result<T> = std::result::Result<T, NetError>;

impl DeliveryAck {
    pub fn ok(envelope_id: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            version: NET_PROTOCOL_VERSION,
            status: STATUS_OK.to_string(),
            envelope_id: envelope_id.into(),
            detail: detail.into(),
        }
    }

    pub fn error(envelope_id: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            version: NET_PROTOCOL_VERSION,
            status: STATUS_ERROR.to_string(),
            envelope_id: envelope_id.into(),
            detail: detail.into(),
        }
    }

    pub fn is_ok(&self) -> bool {
        self.status == STATUS_OK
    }
}

pub fn send_envelope<A: ToSocketAddrs>(addr: A, envelope: &[u8]) -> Result<DeliveryAck> {
    let mut stream = TcpStream::connect(addr)?;
    write_envelope_frame(&mut stream, envelope)?;
    let ack = read_ack(&mut stream)?;
    validate_ack(&ack)?;
    if !ack.is_ok() {
        return Err(NetError::DeliveryRejected(ack.detail));
    }
    Ok(ack)
}

pub fn serve<A, F>(addr: A, mut handler: F) -> Result<()>
where
    A: ToSocketAddrs,
    F: FnMut(Vec<u8>) -> DeliveryAck,
{
    let listener = TcpListener::bind(addr)?;
    for stream in listener.incoming() {
        let mut stream = stream?;
        let ack = match read_envelope_frame(&mut stream) {
            Ok(envelope) => handler(envelope),
            Err(error) => DeliveryAck::error("", error.to_string()),
        };
        let _ = write_ack(&mut stream, &ack);
    }
    Ok(())
}

pub fn p2p_serve_blocking<F, R>(on_ready: R, handler: F) -> Result<()>
where
    F: FnMut(Vec<u8>) -> DeliveryAck,
    R: FnOnce(P2pEndpointInfo),
{
    runtime()?.block_on(p2p_serve(on_ready, handler))
}

pub fn p2p_send_envelope_blocking(ticket: &str, envelope: &[u8]) -> Result<DeliveryAck> {
    runtime()?.block_on(p2p_send_envelope(ticket, envelope))
}

pub async fn p2p_serve<F, R>(on_ready: R, mut handler: F) -> Result<()>
where
    F: FnMut(Vec<u8>) -> DeliveryAck,
    R: FnOnce(P2pEndpointInfo),
{
    let endpoint = build_p2p_endpoint(true).await?;
    let online = wait_until_online(&endpoint).await;
    on_ready(p2p_endpoint_info(&endpoint, online));

    while let Some(incoming) = endpoint.accept().await {
        let accepting = match incoming.accept() {
            Ok(accepting) => accepting,
            Err(_) => continue,
        };
        let conn = match accepting.await {
            Ok(conn) => conn,
            Err(_) => continue,
        };

        let (mut send, mut recv) = match conn.accept_bi().await {
            Ok(streams) => streams,
            Err(_) => continue,
        };

        let ack = match recv.read_to_end(MAX_FRAME_BYTES).await {
            Ok(payload) => {
                if payload.len() > MAX_FRAME_BYTES {
                    DeliveryAck::error("", NetError::FrameTooLarge(payload.len()).to_string())
                } else {
                    handler(payload)
                }
            }
            Err(error) => DeliveryAck::error("", error.to_string()),
        };

        if let Ok(payload) = write_json_payload(&ack) {
            let _ = send.write_all(&payload).await;
            let _ = send.finish();
            let _ = tokio::time::timeout(Duration::from_secs(3), conn.closed()).await;
        }
    }

    Ok(())
}

pub async fn p2p_send_envelope(ticket: &str, envelope: &[u8]) -> Result<DeliveryAck> {
    let endpoint = build_p2p_endpoint(false).await?;
    let _ = wait_until_online(&endpoint).await;

    let ticket = ticket
        .parse::<EndpointTicket>()
        .map_err(|error| NetError::InvalidP2pTicket(error.to_string()))?;
    let addr = EndpointAddr::from(ticket);
    let conn = endpoint
        .connect(addr, ENVELOPE_IROH_ALPN)
        .await
        .map_err(to_p2p_error)?;

    let (mut send, mut recv) = conn.open_bi().await.map_err(to_p2p_error)?;
    if envelope.len() > MAX_FRAME_BYTES {
        return Err(NetError::FrameTooLarge(envelope.len()));
    }
    send.write_all(envelope).await.map_err(to_p2p_error)?;
    send.finish().map_err(to_p2p_error)?;

    let ack_payload = recv
        .read_to_end(MAX_FRAME_BYTES)
        .await
        .map_err(to_p2p_error)?;
    let ack = read_json_payload::<DeliveryAck>(&ack_payload)?;
    validate_ack(&ack)?;
    if !ack.is_ok() {
        return Err(NetError::DeliveryRejected(ack.detail));
    }

    conn.close(0u8.into(), b"done");
    endpoint.close().await;
    Ok(ack)
}

pub fn write_envelope_frame<W: Write>(writer: &mut W, envelope: &[u8]) -> Result<()> {
    if envelope.len() > MAX_FRAME_BYTES {
        return Err(NetError::FrameTooLarge(envelope.len()));
    }
    writer.write_all(&(envelope.len() as u32).to_be_bytes())?;
    writer.write_all(envelope)?;
    writer.flush()?;
    Ok(())
}

pub fn read_envelope_frame<R: Read>(reader: &mut R) -> Result<Vec<u8>> {
    let mut length_bytes = [0u8; 4];
    reader.read_exact(&mut length_bytes)?;
    let length = u32::from_be_bytes(length_bytes) as usize;
    if length > MAX_FRAME_BYTES {
        return Err(NetError::FrameTooLarge(length));
    }

    let mut payload = vec![0u8; length];
    reader.read_exact(&mut payload)?;
    Ok(payload)
}

pub fn write_ack<W: Write>(writer: &mut W, ack: &DeliveryAck) -> Result<()> {
    write_json_frame(writer, ack)
}

pub fn read_ack<R: Read>(reader: &mut R) -> Result<DeliveryAck> {
    read_json_frame(reader)
}

fn validate_ack(ack: &DeliveryAck) -> Result<()> {
    if ack.version != NET_PROTOCOL_VERSION {
        return Err(NetError::UnsupportedAckVersion(ack.version));
    }
    Ok(())
}

fn write_json_frame<W, T>(writer: &mut W, value: &T) -> Result<()>
where
    W: Write,
    T: Serialize,
{
    let payload = serde_json::to_vec(value)?;
    if payload.len() > MAX_FRAME_BYTES {
        return Err(NetError::FrameTooLarge(payload.len()));
    }
    writer.write_all(&(payload.len() as u32).to_be_bytes())?;
    writer.write_all(&payload)?;
    writer.flush()?;
    Ok(())
}

fn read_json_frame<R, T>(reader: &mut R) -> Result<T>
where
    R: Read,
    T: DeserializeOwned,
{
    let mut length_bytes = [0u8; 4];
    reader.read_exact(&mut length_bytes)?;
    let length = u32::from_be_bytes(length_bytes) as usize;
    if length > MAX_FRAME_BYTES {
        return Err(NetError::FrameTooLarge(length));
    }

    let mut payload = vec![0u8; length];
    reader.read_exact(&mut payload)?;
    Ok(serde_json::from_slice(&payload)?)
}

async fn build_p2p_endpoint(accept_incoming: bool) -> Result<Endpoint> {
    let mut builder = Endpoint::builder(presets::N0).relay_mode(RelayMode::Default);
    if accept_incoming {
        builder = builder.alpns(vec![ENVELOPE_IROH_ALPN.to_vec()]);
    }
    builder.bind().await.map_err(to_p2p_error)
}

async fn wait_until_online(endpoint: &Endpoint) -> bool {
    tokio::time::timeout(IROH_ONLINE_TIMEOUT, endpoint.online())
        .await
        .is_ok()
}

fn p2p_endpoint_info(endpoint: &Endpoint, online: bool) -> P2pEndpointInfo {
    let addr = endpoint.addr();
    let ticket = EndpointTicket::new(addr.clone()).to_string();
    P2pEndpointInfo {
        endpoint_id: endpoint.id().to_string(),
        ticket,
        direct_addrs: addr.ip_addrs().map(|addr| addr.to_string()).collect(),
        relay_urls: addr.relay_urls().map(|url| url.to_string()).collect(),
        online,
    }
}

fn write_json_payload<T>(value: &T) -> Result<Vec<u8>>
where
    T: Serialize,
{
    let payload = serde_json::to_vec(value)?;
    if payload.len() > MAX_FRAME_BYTES {
        return Err(NetError::FrameTooLarge(payload.len()));
    }
    Ok(payload)
}

fn read_json_payload<T>(payload: &[u8]) -> Result<T>
where
    T: DeserializeOwned,
{
    if payload.len() > MAX_FRAME_BYTES {
        return Err(NetError::FrameTooLarge(payload.len()));
    }
    Ok(serde_json::from_slice(payload)?)
}

fn runtime() -> Result<&'static tokio::runtime::Runtime> {
    static RUNTIME: OnceLock<std::result::Result<tokio::runtime::Runtime, String>> =
        OnceLock::new();
    match RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|error| error.to_string())
    }) {
        Ok(runtime) => Ok(runtime),
        Err(error) => Err(NetError::P2p(format!(
            "tokio runtime initialization failed: {error}"
        ))),
    }
}

fn to_p2p_error(error: impl std::fmt::Display) -> NetError {
    NetError::P2p(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use envelope_core::Identity;
    use std::io::Cursor;

    #[test]
    fn envelope_frame_round_trip() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");
        let envelope = envelope_core::encrypt_opaque_text(&alice, &bob.contact(), "hello", 1)
            .unwrap()
            .envelope_bytes;

        let mut bytes = Vec::new();
        write_envelope_frame(&mut bytes, &envelope).unwrap();
        let decoded = read_envelope_frame(&mut Cursor::new(bytes)).unwrap();

        assert_eq!(decoded, envelope);
    }

    #[test]
    fn oversize_frame_is_rejected_before_allocation() {
        let length = ((MAX_FRAME_BYTES + 1) as u32).to_be_bytes();
        let error = read_envelope_frame(&mut Cursor::new(length)).unwrap_err();

        assert!(matches!(error, NetError::FrameTooLarge(size) if size == MAX_FRAME_BYTES + 1));
    }

    #[test]
    fn blocking_runtime_is_reused() {
        let first = runtime().unwrap() as *const tokio::runtime::Runtime;
        let second = runtime().unwrap() as *const tokio::runtime::Runtime;

        assert_eq!(first, second);
    }
}
