use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use envelope_server::ha::{coordinator::now_ms, recovery};
use envelope_server_core::ha::ClusterConfigV2;
use std::path::{Path, PathBuf};

#[derive(Parser)]
#[command(about = "Verify HA snapshots and rebuild a stopped node into a new data incarnation")]
struct Arguments {
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    Backup {
        #[arg(long)]
        source_db: PathBuf,
        #[arg(long)]
        snapshot_dir: PathBuf,
        #[arg(long)]
        cluster_config: PathBuf,
        #[arg(long)]
        administrator_public: String,
        #[arg(long)]
        signing_secret_file: PathBuf,
        #[arg(long)]
        archived_config: Vec<PathBuf>,
    },
    Verify {
        #[arg(long)]
        snapshot_dir: PathBuf,
        #[arg(long)]
        administrator_public: String,
    },
    Restore {
        #[arg(long)]
        snapshot_dir: PathBuf,
        #[arg(long)]
        destination_db: PathBuf,
        #[arg(long)]
        cluster_config: PathBuf,
        #[arg(long)]
        administrator_public: String,
        #[arg(long)]
        target_node_id: String,
    },
}
fn config(path: &Path) -> Result<ClusterConfigV2> {
    serde_json::from_slice(&std::fs::read(path)?).context("parse signed cluster configuration")
}
#[tokio::main]
async fn main() -> Result<()> {
    match Arguments::parse().command {
        Command::Backup {
            source_db,
            snapshot_dir,
            cluster_config,
            administrator_public,
            signing_secret_file,
            archived_config,
        } => {
            let secret = std::fs::read_to_string(signing_secret_file)?;
            let archives = archived_config
                .iter()
                .map(|p| config(p))
                .collect::<Result<Vec<_>>>()?;
            let manifest = recovery::backup(
                &source_db,
                &snapshot_dir,
                config(&cluster_config)?,
                archives,
                &administrator_public,
                secret.trim(),
                now_ms(),
            )
            .await?;
            println!(
                "{}",
                serde_json::to_string_pretty(
                    &serde_json::json!({"snapshot_id":manifest.snapshot_id,"snapshot_dir":snapshot_dir,"database_sha256":manifest.database_sha256,"applied_index":manifest.contents.applied_index.to_string(),"bytes":manifest.database_bytes})
                )?
            );
        }
        Command::Verify {
            snapshot_dir,
            administrator_public,
        } => {
            let manifest = recovery::verify_bundle(&snapshot_dir, &administrator_public).await?;
            println!(
                "{}",
                serde_json::to_string_pretty(
                    &serde_json::json!({"verified":true,"snapshot_id":manifest.snapshot_id,"contents":manifest.contents,"database_sha256":manifest.database_sha256})
                )?
            );
        }
        Command::Restore {
            snapshot_dir,
            destination_db,
            cluster_config,
            administrator_public,
            target_node_id,
        } => {
            let report = recovery::restore(
                &snapshot_dir,
                &destination_db,
                &config(&cluster_config)?,
                &target_node_id,
                &administrator_public,
                now_ms(),
            )
            .await?;
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
    }
    Ok(())
}
