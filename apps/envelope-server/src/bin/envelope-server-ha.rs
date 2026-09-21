use anyhow::Result;
use clap::Parser;
use std::path::PathBuf;
#[derive(Parser)]
#[command(about="Envelope managed HA v2 server; requires authenticated cluster config and control quorum")]
struct Args { #[arg(long)] config:PathBuf }
#[tokio::main]
async fn main()->Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_|"envelope_server=info".into())).init();
    let args=Args::parse();
    let config=serde_json::from_slice(&std::fs::read(args.config)?)?;
    envelope_server::ha::runtime::run(config).await
}
