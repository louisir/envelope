use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use envelope_server_core::NodeSetManifest;
use envelope_server_core::ha::{ClusterConfigV2, HaSigned};
use std::{
    fs::OpenOptions,
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Debug, Parser)]
#[command(name = "envelope-server-admin")]
#[command(about = "Envelope Server node-pool admin utilities")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    GenerateSigningKey {
        #[arg(long)]
        secret_out: Option<PathBuf>,
    },
    PublicKey {
        #[arg(long)]
        signing_secret_file: PathBuf,
    },
    SignManifest {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        signing_secret_file: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    SignHaConfig {
        #[arg(long)]
        config: PathBuf,
        #[arg(long)]
        signing_secret_file: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::GenerateSigningKey { secret_out } => generate_signing_key(secret_out),
        Command::PublicKey {
            signing_secret_file,
        } => print_public_key(&signing_secret_file),
        Command::SignManifest {
            manifest,
            signing_secret_file,
            out,
        } => sign_manifest(&manifest, &signing_secret_file, &out),
        Command::SignHaConfig { config, signing_secret_file, out } => {
            let mut config: ClusterConfigV2 = serde_json::from_slice(&std::fs::read(config)?)?;
            config.validate()?;
            config.sign(&read_secret_file(&signing_secret_file)?)?;
            std::fs::write(out, serde_json::to_vec_pretty(&config)?)?;
            Ok(())
        },
    }
}

fn generate_signing_key(secret_out: Option<PathBuf>) -> Result<()> {
    let (signing_secret, signing_public) = envelope_core::generate_signing_keypair();
    if let Some(path) = secret_out {
        write_new_secret_file(&path, &signing_secret)?;
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "signing_secret_file": path,
                "signing_public": signing_public,
            }))
            .context("serialize generated signing key")?
        );
    } else {
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "signing_secret": signing_secret,
                "signing_public": signing_public,
            }))
            .context("serialize generated signing key")?
        );
    }
    Ok(())
}

fn print_public_key(signing_secret_file: &Path) -> Result<()> {
    let signing_secret = read_secret_file(signing_secret_file)?;
    let signing_public = envelope_core::signing_public_from_secret(&signing_secret)
        .context("derive signing public key")?;
    println!("{signing_public}");
    Ok(())
}

fn sign_manifest(manifest_path: &Path, signing_secret_file: &Path, out: &Path) -> Result<()> {
    let signing_secret = read_secret_file(signing_secret_file)?;
    let content = std::fs::read_to_string(manifest_path)
        .with_context(|| format!("read manifest {}", manifest_path.display()))?;
    let mut manifest: NodeSetManifest = serde_json::from_str(&content)
        .with_context(|| format!("parse manifest {}", manifest_path.display()))?;
    manifest.sign(&signing_secret).context("sign manifest")?;
    let signed = serde_json::to_string_pretty(&manifest).context("serialize signed manifest")?;
    std::fs::write(out, signed).with_context(|| format!("write signed manifest {}", out.display()))
}

fn read_secret_file(path: &Path) -> Result<String> {
    let secret = std::fs::read_to_string(path)
        .with_context(|| format!("read signing secret {}", path.display()))?
        .trim()
        .to_string();
    if secret.is_empty() {
        bail!("signing secret file is empty: {}", path.display());
    }
    Ok(secret)
}

fn write_new_secret_file(path: &Path, secret: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .with_context(|| format!("create signing secret {}", path.display()))?;
    file.write_all(secret.as_bytes())
        .with_context(|| format!("write signing secret {}", path.display()))?;
    file.write_all(b"\n")
        .with_context(|| format!("write signing secret newline {}", path.display()))?;
    Ok(())
}
