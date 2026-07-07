use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use envelope_core::{Contact, Identity};
use envelope_store::{ImportOutcome, LocalStore};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Parser)]
#[command(name = "envelope")]
#[command(about = "Envelope / 信封 phase-1 CLI prototype")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Run the full phase-1 chain in a local output directory.
    Demo {
        #[arg(long, default_value = "target/envelope-demo")]
        out_dir: PathBuf,
    },
    /// Identity and contact operations.
    Identity {
        #[command(subcommand)]
        command: IdentityCommand,
    },
    /// Encrypt and decrypt opaque envelope files.
    Message {
        #[command(subcommand)]
        command: MessageCommand,
    },
    /// Local JSON store operations.
    Store {
        #[command(subcommand)]
        command: StoreCommand,
    },
}

#[derive(Debug, Subcommand)]
enum IdentityCommand {
    /// Generate a BIP39 24-word recovery phrase.
    RecoveryPhrase,
    /// Create a local identity file containing private keys.
    New {
        #[arg(long)]
        name: String,
        #[arg(long)]
        out: PathBuf,
    },
    /// Recover a local identity file from a BIP39 24-word phrase.
    Recover {
        #[arg(long)]
        name: String,
        #[arg(long)]
        phrase: Option<String>,
        #[arg(long)]
        phrase_file: Option<PathBuf>,
        #[arg(long)]
        out: PathBuf,
    },
    /// Export a public contact file from a local identity.
    ExportContact {
        #[arg(long)]
        identity: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
}

#[derive(Debug, Subcommand)]
enum MessageCommand {
    /// Encrypt a text message for a contact.
    Encrypt {
        #[arg(long)]
        sender: PathBuf,
        #[arg(long)]
        recipient: PathBuf,
        #[arg(long)]
        text: String,
        #[arg(long, default_value_t = 1)]
        counter: u64,
        #[arg(long)]
        out: PathBuf,
    },
    /// Decrypt an opaque text envelope file.
    Decrypt {
        #[arg(long)]
        recipient: PathBuf,
        #[arg(long)]
        sender: PathBuf,
        #[arg(long)]
        input: PathBuf,
    },
}

#[derive(Debug, Subcommand)]
enum StoreCommand {
    /// Initialize a local development store.
    Init {
        #[arg(long)]
        dir: PathBuf,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        identity: Option<PathBuf>,
    },
    /// Export this store's public contact.
    ExportContact {
        #[arg(long)]
        dir: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// Add or update a contact in the store.
    AddContact {
        #[arg(long)]
        dir: PathBuf,
        #[arg(long)]
        contact: PathBuf,
    },
    /// List contacts in the store.
    ListContacts {
        #[arg(long)]
        dir: PathBuf,
    },
    /// Import an opaque envelope file into the store.
    ImportEnvelope {
        #[arg(long)]
        dir: PathBuf,
        #[arg(long)]
        input: PathBuf,
    },
    /// Create an outbound opaque envelope file from this store.
    ExportEnvelope {
        #[arg(long)]
        dir: PathBuf,
        #[arg(long)]
        recipient: String,
        #[arg(long)]
        text: String,
        #[arg(long)]
        out: PathBuf,
    },
    /// Listen for direct TCP envelope delivery.
    Serve {
        #[arg(long)]
        dir: PathBuf,
        #[arg(long, default_value = "127.0.0.1:19092")]
        listen: String,
    },
    /// Send one encrypted envelope over direct TCP.
    SendOnline {
        #[arg(long)]
        dir: PathBuf,
        #[arg(long)]
        recipient: String,
        #[arg(long)]
        text: String,
        #[arg(long)]
        addr: String,
    },
    /// Listen for P2P envelope delivery over iroh.
    P2pServe {
        #[arg(long)]
        dir: PathBuf,
    },
    /// Send one encrypted envelope over iroh P2P.
    P2pSend {
        #[arg(long)]
        dir: PathBuf,
        #[arg(long)]
        recipient: String,
        #[arg(long)]
        text: String,
        #[arg(long)]
        ticket: String,
    },
    /// List decrypted messages in the store.
    ListMessages {
        #[arg(long)]
        dir: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Demo { out_dir } => run_demo(&out_dir),
        Commands::Identity { command } => run_identity(command),
        Commands::Message { command } => run_message(command),
        Commands::Store { command } => run_store(command),
    }
}

fn run_identity(command: IdentityCommand) -> Result<()> {
    match command {
        IdentityCommand::RecoveryPhrase => {
            let phrase = envelope_core::generate_recovery_phrase()?;
            println!("{phrase}");
            println!(
                "warning: store this offline; anyone with this phrase can recover the identity"
            );
        }
        IdentityCommand::New { name, out } => {
            let identity = Identity::generate(name);
            write_json(&out, &identity)?;
            println!("identity written: {}", out.display());
            println!("key id: {}", identity.public.key_id);
        }
        IdentityCommand::Recover {
            name,
            phrase,
            phrase_file,
            out,
        } => {
            let phrase = read_recovery_phrase(phrase, phrase_file)?;
            let identity = Identity::from_recovery_phrase(name, &phrase)?;
            write_json(&out, &identity)?;
            println!("identity recovered: {}", out.display());
            println!("key id: {}", identity.public.key_id);
            println!("warning: development identity file contains private keys");
        }
        IdentityCommand::ExportContact { identity, out } => {
            let identity: Identity = read_json(&identity)?;
            write_json(&out, &identity.contact())?;
            println!("contact written: {}", out.display());
        }
    }
    Ok(())
}

fn read_recovery_phrase(phrase: Option<String>, phrase_file: Option<PathBuf>) -> Result<String> {
    match (phrase, phrase_file) {
        (Some(_), Some(_)) => bail!("use either --phrase or --phrase-file, not both"),
        (Some(phrase), None) => Ok(phrase.trim().to_string()),
        (None, Some(path)) => {
            let phrase =
                fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
            Ok(phrase.trim().to_string())
        }
        (None, None) => bail!("provide --phrase-file for recovery phrase input"),
    }
}

fn run_message(command: MessageCommand) -> Result<()> {
    match command {
        MessageCommand::Encrypt {
            sender,
            recipient,
            text,
            counter,
            out,
        } => {
            let sender: Identity = read_json(&sender)?;
            let recipient: Contact = read_json(&recipient)?;
            let envelope = envelope_core::encrypt_opaque_text(&sender, &recipient, &text, counter)?;
            ensure_parent(&out)?;
            fs::write(&out, &envelope.envelope_bytes)
                .with_context(|| format!("write {}", out.display()))?;
            println!("envelope written: {}", out.display());
            println!("envelope id: {}", envelope.envelope_id);
        }
        MessageCommand::Decrypt {
            recipient,
            sender,
            input,
        } => {
            let recipient: Identity = read_json(&recipient)?;
            let sender: Contact = read_json(&sender)?;
            let envelope = fs::read(&input).with_context(|| format!("read {}", input.display()))?;
            let text = envelope_core::decrypt_opaque_text(&recipient, &sender, &envelope)?;
            println!("{text}");
        }
    }
    Ok(())
}

fn run_store(command: StoreCommand) -> Result<()> {
    match command {
        StoreCommand::Init {
            dir,
            name,
            identity,
        } => {
            let store = if let Some(identity) = identity {
                let identity: Identity = read_json(&identity)?;
                LocalStore::init_with_identity(&dir, identity)?
            } else {
                LocalStore::init(&dir, name.unwrap_or_else(|| "Envelope User".to_string()))?
            };
            println!("store initialized: {}", dir.display());
            println!("key id: {}", store.identity().public.key_id);
            println!("warning: development JSON store is not encrypted");
        }
        StoreCommand::ExportContact { dir, out } => {
            let store = LocalStore::open(&dir)?;
            write_json(&out, &store.contact())?;
            println!("contact written: {}", out.display());
        }
        StoreCommand::AddContact { dir, contact } => {
            let mut store = LocalStore::open(&dir)?;
            let contact: Contact = read_json(&contact)?;
            let added = store.add_contact(contact.clone())?;
            if added {
                println!(
                    "contact added: {} ({})",
                    contact.display_name, contact.key_id
                );
            } else {
                println!(
                    "contact updated: {} ({})",
                    contact.display_name, contact.key_id
                );
            }
        }
        StoreCommand::ListContacts { dir } => {
            let store = LocalStore::open(&dir)?;
            for contact in store.contacts() {
                println!("{}\t{}", contact.key_id, contact.display_name);
            }
        }
        StoreCommand::ImportEnvelope { dir, input } => {
            let mut store = LocalStore::open(&dir)?;
            let bytes = fs::read(&input).with_context(|| format!("read {}", input.display()))?;
            let envelope = envelope_store::parse_opaque_envelope(&bytes)?;
            print_import_outcome(store.import_opaque_envelope(&envelope)?);
        }
        StoreCommand::ExportEnvelope {
            dir,
            recipient,
            text,
            out,
        } => {
            ensure_parent(&out)?;
            let mut store = LocalStore::open(&dir)?;
            let outbound = store.create_outbound_text(&recipient, &text)?;
            fs::write(&out, &outbound.envelope.envelope_bytes)
                .with_context(|| format!("write {}", out.display()))?;
            println!("offline envelope written: {}", out.display());
            println!("recipient: {}", outbound.recipient.display_name);
            println!("envelope id: {}", outbound.envelope.envelope_id);
            println!("{}", outbound.message.text);
        }
        StoreCommand::Serve { dir, listen } => {
            let mut store = LocalStore::open(&dir)?;
            println!("store listening: {listen}");
            println!("store dir: {}", dir.display());
            println!("local key id: {}", store.identity().public.key_id);

            envelope_net::serve(&listen, move |envelope| {
                import_envelope_ack(&mut store, envelope)
            })?;
        }
        StoreCommand::SendOnline {
            dir,
            recipient,
            text,
            addr,
        } => {
            let mut store = LocalStore::open(&dir)?;
            let outbound = store.create_outbound_text(&recipient, &text)?;
            let ack = envelope_net::send_envelope(&addr, &outbound.envelope.envelope_bytes)
                .with_context(|| format!("send envelope to {addr}"))?;

            println!("online message sent: {addr}");
            println!("recipient: {}", outbound.recipient.display_name);
            println!("envelope id: {}", ack.envelope_id);
            println!("ack: {}", ack.detail);
            println!("{}", outbound.message.text);
        }
        StoreCommand::P2pServe { dir } => {
            let mut store = LocalStore::open(&dir)?;
            println!("p2p store dir: {}", dir.display());
            println!("local key id: {}", store.identity().public.key_id);

            envelope_net::p2p_serve_blocking(print_p2p_endpoint_info, move |envelope| {
                import_envelope_ack(&mut store, envelope)
            })?;
        }
        StoreCommand::P2pSend {
            dir,
            recipient,
            text,
            ticket,
        } => {
            let mut store = LocalStore::open(&dir)?;
            let outbound = store.create_outbound_text(&recipient, &text)?;
            let ack = envelope_net::p2p_send_envelope_blocking(
                &ticket,
                &outbound.envelope.envelope_bytes,
            )
            .with_context(|| "send envelope over iroh p2p")?;

            println!("p2p message sent");
            println!("recipient: {}", outbound.recipient.display_name);
            println!("envelope id: {}", ack.envelope_id);
            println!("ack: {}", ack.detail);
            println!("{}", outbound.message.text);
        }
        StoreCommand::ListMessages { dir } => {
            let store = LocalStore::open(&dir)?;
            for message in store.messages() {
                println!(
                    "{}\t{}\t{:?}\t{}",
                    message.created_at_unix_ms,
                    message.sender_display_name,
                    message.direction,
                    message.text
                );
            }
        }
    }
    Ok(())
}

fn import_envelope_ack(store: &mut LocalStore, envelope: Vec<u8>) -> envelope_net::DeliveryAck {
    match store.import_opaque_envelope(&envelope) {
        Ok(ImportOutcome::Imported(message)) => {
            println!(
                "imported: {} from {}",
                message.envelope_id, message.sender_display_name
            );
            envelope_net::DeliveryAck::ok(
                message.envelope_id,
                format!("imported from {}", message.sender_display_name),
            )
        }
        Ok(ImportOutcome::Duplicate { envelope_id }) => {
            println!("duplicate envelope ignored: {envelope_id}");
            envelope_net::DeliveryAck::ok(envelope_id, "duplicate ignored")
        }
        Ok(ImportOutcome::Replay {
            sender_key_id,
            message_counter,
        }) => {
            let message =
                format!("message counter replay detected: {sender_key_id}#{message_counter}");
            eprintln!("{message}");
            envelope_net::DeliveryAck::error("", message)
        }
        Err(error) => {
            eprintln!("import failed: {error}");
            envelope_net::DeliveryAck::error("", error.to_string())
        }
    }
}

fn print_p2p_endpoint_info(info: envelope_net::P2pEndpointInfo) {
    println!("p2p endpoint id: {}", info.endpoint_id);
    println!("p2p online: {}", info.online);
    println!("p2p ticket: {}", info.ticket);
    if !info.direct_addrs.is_empty() {
        println!("p2p direct addrs: {}", info.direct_addrs.join(" "));
    }
    if !info.relay_urls.is_empty() {
        println!("p2p relay urls: {}", info.relay_urls.join(" "));
    }
    println!("waiting for p2p messages; press Ctrl+C to stop");
}

fn run_demo(out_dir: &Path) -> Result<()> {
    fs::create_dir_all(out_dir).with_context(|| format!("create {}", out_dir.display()))?;

    let alice = Identity::generate("Alice");
    let bob = Identity::generate("Bob");
    let alice_identity = out_dir.join("alice.identity.json");
    let bob_identity = out_dir.join("bob.identity.json");
    let alice_contact = out_dir.join("alice.contact.json");
    let bob_contact = out_dir.join("bob.contact.json");
    write_json(&alice_identity, &alice)?;
    write_json(&bob_identity, &bob)?;
    write_json(&alice_contact, &alice.contact())?;
    write_json(&bob_contact, &bob.contact())?;

    let envelope = envelope_core::encrypt_opaque_text(
        &alice,
        &bob.contact(),
        "你好，Envelope 第一阶段跑通了。",
        1,
    )?;
    let envelope_path = out_dir.join("message");
    fs::write(&envelope_path, &envelope.envelope_bytes)
        .with_context(|| format!("write {}", envelope_path.display()))?;

    let decrypted =
        envelope_core::decrypt_opaque_text(&bob, &alice.contact(), &envelope.envelope_bytes)?;
    fs::write(out_dir.join("decrypted.txt"), decrypted.as_bytes())?;

    println!("demo output: {}", out_dir.display());
    println!("alice identity: {}", alice_identity.display());
    println!("bob identity: {}", bob_identity.display());
    println!("envelope: {}", envelope_path.display());
    println!("decrypted: {decrypted}");
    Ok(())
}

fn read_json<T: for<'de> serde::Deserialize<'de>>(path: &Path) -> Result<T> {
    let bytes = fs::read(path).with_context(|| format!("read {}", path.display()))?;
    serde_json::from_slice(&bytes).with_context(|| format!("parse json {}", path.display()))
}

fn write_json<T: serde::Serialize>(path: &Path, value: &T) -> Result<()> {
    ensure_parent(path)?;
    let json = serde_json::to_string_pretty(value).context("serialize json")?;
    fs::write(path, json).with_context(|| format!("write {}", path.display()))
}

fn print_import_outcome(outcome: ImportOutcome) {
    match outcome {
        ImportOutcome::Imported(message) => {
            println!(
                "imported: {} from {}",
                message.envelope_id, message.sender_display_name
            );
            println!("{}", message.text);
        }
        ImportOutcome::Duplicate { envelope_id } => {
            println!("duplicate envelope ignored: {envelope_id}");
        }
        ImportOutcome::Replay {
            sender_key_id,
            message_counter,
        } => {
            println!("message counter replay detected: {sender_key_id}#{message_counter}");
        }
    }
}

fn ensure_parent(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    Ok(())
}
