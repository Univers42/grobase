//! A minimal async RFC 2812 IRC client (no external IRC crate).
//!
//! One [`run_session`] drives a single TCP connection: it registers
//! (PASS/NICK/USER), joins channels, answers PING, forwards inbound PRIVMSG as
//! [`EventEnvelope`]s, and writes outbound raw lines received on an mpsc channel.
//! [`run_client`] wraps it in a reconnect loop.

use std::time::Duration;

use bytes::Bytes;
use realtime_core::types::{EventEnvelope, EventSource, SourceKind, TopicPath};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::{broadcast, mpsc};
use tracing::{debug, info, warn};

use crate::mapping::channel_to_topic;

/// Connection parameters for one IRC link.
#[derive(Debug, Clone)]
pub struct SessionConfig {
    pub host: String,
    pub port: u16,
    pub password: String,
    pub nick: String,
    pub user: String,
    pub realname: String,
    pub channels: Vec<String>,
    pub namespace: String,
    /// Whether inbound PRIVMSGs are forwarded to the bus as events. The shared
    /// service connection sets this `true` (it is the single inbound source);
    /// per-user sessions set it `false` so a channel message isn't emitted once
    /// per joined session.
    pub forward_inbound: bool,
}

/// Reconnecting client loop. Runs until `cmd_rx` is closed.
pub async fn run_client(
    cfg: SessionConfig,
    mut cmd_rx: mpsc::Receiver<String>,
    inbound: broadcast::Sender<EventEnvelope>,
) {
    loop {
        match run_session(&cfg, &mut cmd_rx, &inbound).await {
            Ok(()) => {
                info!(nick = %cfg.nick, "IRC session ended cleanly");
                return;
            }
            Err(e) => {
                warn!(nick = %cfg.nick, error = %e, "IRC session error; reconnecting in 3s");
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
        }
    }
}

/// Drive a single connection. Returns `Ok(())` when `cmd_rx` closes (shutdown),
/// or `Err` on a connection/IO error so the caller can reconnect.
async fn run_session(
    cfg: &SessionConfig,
    cmd_rx: &mut mpsc::Receiver<String>,
    inbound: &broadcast::Sender<EventEnvelope>,
) -> anyhow::Result<()> {
    let stream = TcpStream::connect((cfg.host.as_str(), cfg.port)).await?;
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    // Registration handshake.
    let mut current_nick = cfg.nick.clone();
    let mut nick_try: u32 = 0;
    if !cfg.password.is_empty() {
        write_line(&mut write_half, &format!("PASS {}", cfg.password)).await?;
    }
    write_line(&mut write_half, &format!("NICK {current_nick}")).await?;
    write_line(
        &mut write_half,
        &format!("USER {} 0 * :{}", cfg.user, cfg.realname),
    )
    .await?;
    for channel in &cfg.channels {
        write_line(&mut write_half, &format!("JOIN {channel}")).await?;
    }
    info!(nick = %cfg.nick, host = %cfg.host, port = cfg.port, "IRC connected");

    let mut line = String::new();
    loop {
        tokio::select! {
            read = reader.read_line(&mut line) => {
                let n = read?;
                if n == 0 {
                    return Err(anyhow::anyhow!("connection closed by peer"));
                }
                let raw = line.trim_end_matches(['\r', '\n']).to_string();
                line.clear();
                if is_nick_error(&raw) {
                    nick_try += 1;
                    current_nick = retry_nick(&cfg.nick, nick_try);
                    write_line(&mut write_half, &format!("NICK {current_nick}")).await?;
                    continue;
                }
                handle_inbound(&raw, cfg, &mut write_half, inbound).await?;
            }
            cmd = cmd_rx.recv() => {
                if let Some(raw) = cmd {
                    write_line(&mut write_half, &raw).await?;
                } else {
                    // Channel closed: graceful shutdown.
                    let _ = write_line(&mut write_half, "QUIT :bye").await;
                    return Ok(());
                }
            }
        }
    }
}

/// Parse one inbound line and react: answer PING, forward PRIVMSG as an event.
async fn handle_inbound(
    raw: &str,
    cfg: &SessionConfig,
    write_half: &mut tokio::net::tcp::OwnedWriteHalf,
    inbound: &broadcast::Sender<EventEnvelope>,
) -> anyhow::Result<()> {
    if raw.is_empty() {
        return Ok(());
    }
    let msg = ParsedLine::parse(raw);

    if msg.command.eq_ignore_ascii_case("PING") {
        let token = msg.trailing.unwrap_or_default();
        write_line(write_half, &format!("PONG :{token}")).await?;
        return Ok(());
    }

    if msg.command.eq_ignore_ascii_case("PRIVMSG") {
        if !cfg.forward_inbound {
            return Ok(()); // per-user sessions don't re-emit channel traffic
        }
        let Some(channel) = msg.params.first() else {
            return Ok(());
        };
        if !channel.starts_with('#') {
            return Ok(()); // direct message, not a channel — ignored for now
        }
        let sender = msg.prefix_nick().unwrap_or_else(|| "unknown".to_string());
        let text = msg.trailing.unwrap_or_default();

        let topic = channel_to_topic(channel, &cfg.namespace);
        let body = serde_json::json!({ "from": sender, "text": text });
        let payload = Bytes::from(serde_json::to_vec(&body).unwrap_or_default());

        let mut event = EventEnvelope::new(TopicPath::new(&topic), "message", payload);
        event.source = Some(EventSource {
            kind: SourceKind::Custom("irc".to_string()),
            id: sender,
            metadata: std::collections::HashMap::new(),
        });
        // A send error only means there are currently no subscribers — fine.
        let _ = inbound.send(event);
        debug!(%channel, "forwarded IRC PRIVMSG to bus");
    }
    Ok(())
}

/// Write one line followed by CRLF.
async fn write_line(
    write_half: &mut tokio::net::tcp::OwnedWriteHalf,
    line: &str,
) -> anyhow::Result<()> {
    write_half.write_all(line.as_bytes()).await?;
    write_half.write_all(b"\r\n").await?;
    Ok(())
}

/// A parsed IRC protocol line: `[:prefix] COMMAND [params...] [:trailing]`.
struct ParsedLine<'a> {
    prefix: Option<&'a str>,
    command: &'a str,
    params: Vec<&'a str>,
    trailing: Option<String>,
}

impl<'a> ParsedLine<'a> {
    fn parse(raw: &'a str) -> Self {
        let mut rest = raw;
        let mut prefix = None;
        if let Some(stripped) = rest.strip_prefix(':') {
            let (p, r) = split_once_space(stripped);
            prefix = Some(p);
            rest = r;
        }

        let mut trailing = None;
        if let Some(idx) = rest.find(" :") {
            trailing = Some(rest[idx + 2..].to_string());
            rest = &rest[..idx];
        }

        let mut parts = rest.split_whitespace();
        let command = parts.next().unwrap_or("");
        let params = parts.collect::<Vec<&str>>();

        Self {
            prefix,
            command,
            params,
            trailing,
        }
    }

    /// Extract the nick from a `nick!user@host` prefix.
    fn prefix_nick(&self) -> Option<String> {
        self.prefix.map(|p| {
            let nick = p.split('!').next().unwrap_or(p);
            nick.to_string()
        })
    }
}

/// True if the line is an `ERR_NICKNAMEINUSE` (433) or `ERR_ERRONEUSNICKNAME` (432).
fn is_nick_error(raw: &str) -> bool {
    let cmd = ParsedLine::parse(raw).command;
    cmd == "433" || cmd == "432"
}

/// Build a fallback nick by appending an attempt number, capped to NICKLEN (9).
fn retry_nick(base: &str, attempt: u32) -> String {
    let suffix = attempt.to_string();
    let keep = 9usize.saturating_sub(suffix.len()).max(1);
    let head: String = base.chars().take(keep).collect();
    format!("{head}{suffix}")
}

/// Split a string at the first space into (head, tail).
fn split_once_space(s: &str) -> (&str, &str) {
    s.find(' ')
        .map_or((s, ""), |i| (&s[..i], s[i + 1..].trim_start()))
}
