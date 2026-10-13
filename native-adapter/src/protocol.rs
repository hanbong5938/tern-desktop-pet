use desktop_pet_contracts::{
    AgentRecord, AgentStatus, PromptError, SessionMetadata, SourceCounts, MAX_AGENT_RECORDS,
};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::time::Duration;
pub const MAX_WINDOWS: usize = 64;
pub const MAX_HOSTS: usize = 64;
pub const MAX_HOST_AGENTS: usize = 128;
pub const MAX_HOST_ERROR_BYTES: usize = 512;
// Request JSON only; the optional line terminator is not part of this budget.
pub const MAX_EXCHANGE_BYTES: usize = 256 * 1024;
pub const MAX_RESPONSE_BYTES: usize = 512 * 1024;
pub const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
pub const FRESHNESS: Duration = Duration::from_secs(5);
pub(crate) const OFFLINE_GRACE: Duration = Duration::from_secs(30);
pub(crate) const MAX_FIELD_BYTES: usize = 4096;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TernExchangeRequest {
    pub version: u64,
    pub kind: String,
    pub window: String,
    pub epoch: u64,
    pub sequence: u64,
    pub instance_id: Option<String>,
    pub hosts: Vec<TernHostInventory>,
    pub results: Vec<TernResult>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TernHostInventory {
    pub host: String,
    pub label: String,
    pub is_local: bool,
    pub observation_generation: u64,
    pub status: TernHostStatus,
    pub agents: Vec<TernAgent>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum TernHostStatus {
    Available,
    Unavailable,
    Disconnected,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TernHostReply {
    pub host: String,
    pub observation_generation: u64,
    pub generation: u64,
    pub error: Option<String>,
    #[serde(
        default,
        deserialize_with = "deserialize_error_code",
        skip_serializing_if = "Option::is_none"
    )]
    pub error_code: Option<TernExchangeErrorCode>,
}

impl TernHostReply {
    pub fn new(host: &TernHostInventory, generation: u64, error: Option<String>) -> Self {
        let error = error.map(|mut value| {
            truncate_utf8(&mut value, MAX_HOST_ERROR_BYTES);
            value
        });
        Self {
            host: host.host.clone(),
            observation_generation: host.observation_generation,
            generation,
            error_code: error.as_ref().map(|_| TernExchangeErrorCode::Rejected),
            error,
        }
    }
}

pub(crate) fn truncate_utf8(value: &mut String, maximum: usize) {
    if value.len() > maximum {
        let mut end = maximum;
        while !value.is_char_boundary(end) {
            end -= 1;
        }
        value.truncate(end);
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TernAgent {
    pub pane: String,
    pub title: String,
    pub cwd: String,
    pub session_id: Option<String>,
    pub session_label: Option<String>,
    pub tab_id: Option<String>,
    pub tab_label: Option<String>,
    pub state: TernAgentState,
    pub delivery_error: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TernAgentState {
    Idle,
    Working,
    WaitingInput,
    Exited,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TernResult {
    pub operation_id: String,
    pub pane: String,
    pub status: TernResultStatus,
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TernResultStatus {
    Accepted,
    Failed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TernCommand {
    pub operation_id: String,
    pub pane: String,
    pub text: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum TernExchangeErrorCode {
    BindingRequired,
    InstanceChanged,
    SourceRetired,
    ReceiptRejected,
    Rejected,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TernExchangeReply {
    pub ok: bool,
    pub instance_id: String,
    pub hosts: Vec<TernHostReply>,
    pub command: Option<TernCommand>,
    pub error: Option<String>,
    #[serde(default, deserialize_with = "deserialize_error_code")]
    pub error_code: Option<TernExchangeErrorCode>,
}

impl TernExchangeReply {
    pub fn error(instance_id: String, code: TernExchangeErrorCode, mut error: String) -> Self {
        truncate_utf8(&mut error, MAX_FIELD_BYTES);
        Self {
            ok: false,
            instance_id,
            hosts: Vec::new(),
            command: None,
            error: Some(error),
            error_code: Some(code),
        }
    }
}

fn deserialize_error_code<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<TernExchangeErrorCode>, D::Error> {
    TernExchangeErrorCode::deserialize(deserializer).map(Some)
}

pub fn serialize_response(reply: &TernExchangeReply) -> serde_json::Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(reply)?;
    bytes.push(b'\n');
    if bytes.len() > MAX_RESPONSE_BYTES {
        return Err(serde_json::Error::io(std::io::Error::other(
            "Tern response size admission invariant failed",
        )));
    }
    Ok(bytes)
}

#[derive(Serialize)]
struct CommandRef<'a> {
    operation_id: &'a str,
    pane: &'a str,
    text: &'a str,
}

#[derive(Serialize)]
struct ReplyRef<'a> {
    ok: bool,
    instance_id: &'a str,
    hosts: &'a [TernHostReply],
    command: Option<CommandRef<'a>>,
    error: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_code: Option<TernExchangeErrorCode>,
}

impl Serialize for TernExchangeReply {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        ReplyRef {
            ok: self.ok,
            instance_id: &self.instance_id,
            hosts: &self.hosts,
            command: self.command.as_ref().map(|command| CommandRef {
                operation_id: &command.operation_id,
                pane: &command.pane,
                text: &command.text,
            }),
            error: self.error.as_deref(),
            error_code: self.error_code,
        }
        .serialize(serializer)
    }
}

#[derive(Default)]
struct ResponseCounter {
    bytes: usize,
    too_large: bool,
}

impl std::io::Write for ResponseCounter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > (MAX_RESPONSE_BYTES - 1).saturating_sub(self.bytes) {
            self.too_large = true;
            return Err(std::io::Error::other("Tern response is too large"));
        }
        self.bytes += bytes.len();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Count the same borrowed envelope used by the real reply serializer, including
/// the helper's trailing LF, without allocating a second copy of the text.
pub fn check_command_response(
    instance_id: &str,
    host_replies_json_bytes: usize,
    operation_id: &str,
    pane: &str,
    text: &str,
) -> Result<(), PromptError> {
    let reply = ReplyRef {
        ok: true,
        instance_id,
        hosts: &[],
        command: Some(CommandRef {
            operation_id,
            pane,
            text,
        }),
        error: None,
        error_code: None,
    };
    let mut counter = ResponseCounter::default();
    let result = serde_json::to_writer(&mut counter, &reply);
    if counter.too_large {
        return Err(PromptError::TooLarge);
    }
    result.map_err(|error| PromptError::Other(error.to_string()))?;
    let bytes = host_replies_json_bytes
        .checked_sub(2)
        .and_then(|extra| counter.bytes.checked_add(extra))
        .and_then(|size| size.checked_add(1))
        .ok_or(PromptError::TooLarge)?;
    if bytes > MAX_RESPONSE_BYTES {
        Err(PromptError::TooLarge)
    } else {
        Ok(())
    }
}

pub fn host_reply_bytes(hosts: &[TernHostReply]) -> Result<usize, PromptError> {
    let mut counter = ResponseCounter::default();
    serde_json::to_writer(&mut counter, hosts).map_err(|error| {
        if counter.too_large {
            PromptError::TooLarge
        } else {
            PromptError::Other(error.to_string())
        }
    })?;
    Ok(counter.bytes)
}

pub fn canonical_host(value: &str) -> bool {
    !value.is_empty()
        && (value == "0" || !value.starts_with('0'))
        && value.bytes().all(|byte| byte.is_ascii_digit())
        && value.parse::<u64>().is_ok_and(|id| id <= MAX_SAFE_INTEGER)
}

fn bounded(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_FIELD_BYTES && !value.contains('\0')
}
fn optional_bounded(value: &Option<String>) -> bool {
    value.as_ref().is_none_or(|value| bounded(value))
}
fn optional_sized(value: &Option<String>) -> bool {
    value
        .as_ref()
        .is_none_or(|value| value.len() <= MAX_FIELD_BYTES && !value.contains('\0'))
}

impl TernExchangeRequest {
    /// Validate inventory shape before touching any source or receipt.
    /// Production ingress checks the raw JSON byte limit before decoding.
    pub fn normalize(&self) -> Result<Vec<(Vec<AgentRecord>, SourceCounts)>, String> {
        if self.version != 2
            || self.kind != "tern"
            || !bounded(&self.window)
            || self.epoch == 0
            || self.epoch > MAX_SAFE_INTEGER
            || self.sequence == 0
            || self.sequence > MAX_SAFE_INTEGER
            || !optional_bounded(&self.instance_id)
            || self.hosts.is_empty()
            || self.hosts.len() > MAX_HOSTS
            || self.hosts.iter().filter(|host| host.is_local).count() != 1
            || self
                .hosts
                .iter()
                .map(|host| host.agents.len())
                .sum::<usize>()
                > MAX_AGENT_RECORDS
            || self.results.len() > 1
        {
            return Err("invalid Tern exchange fields".into());
        }
        let mut hosts = HashSet::with_capacity(self.hosts.len());
        let mut snapshots = Vec::with_capacity(self.hosts.len());
        for host in &self.hosts {
            if !canonical_host(&host.host)
                || !hosts.insert(host.host.as_str())
                || host.label.len() > MAX_FIELD_BYTES
                || host.label.contains('\0')
                || host.observation_generation == 0
                || host.observation_generation > MAX_SAFE_INTEGER
                || host.agents.len() > MAX_HOST_AGENTS
                || (host.status != TernHostStatus::Available && !host.agents.is_empty())
            {
                return Err("invalid or duplicate Tern host".into());
            }
            let mut panes = HashSet::with_capacity(host.agents.len());
            let mut records = Vec::with_capacity(host.agents.len());
            let mut counts = SourceCounts::default();
            for agent in &host.agents {
                if !bounded(&agent.pane)
                    || agent.title.len() > MAX_FIELD_BYTES
                    || agent.cwd.len() > MAX_FIELD_BYTES
                    || agent.title.contains('\0')
                    || agent.cwd.contains('\0')
                    || !optional_sized(&agent.session_id)
                    || !optional_sized(&agent.session_label)
                    || !optional_sized(&agent.tab_id)
                    || !optional_sized(&agent.tab_label)
                    || !optional_sized(&agent.delivery_error)
                    || !panes.insert(agent.pane.as_str())
                {
                    return Err("invalid or duplicate Tern agent pane".into());
                }
                // Pane identity is scoped by this window and host, never session metadata.
                let terminal_id = agent.pane.clone();
                let status = match agent.state {
                    TernAgentState::Idle => AgentStatus::Idle,
                    TernAgentState::Working => AgentStatus::Working,
                    TernAgentState::WaitingInput => AgentStatus::Blocked,
                    // No completion signal or outcome is declared by the installed API.
                    TernAgentState::Exited => AgentStatus::Unknown,
                };
                counts.sessions += 1;
                match status {
                    AgentStatus::Working => counts.working += 1,
                    AgentStatus::Blocked => counts.blocked += 1,
                    AgentStatus::Unknown => counts.unknown += 1,
                    AgentStatus::Idle | AgentStatus::Done => {}
                }
                records.push(AgentRecord {
                    terminal_id,
                    pane_id: agent.pane.clone(),
                    status,
                    metadata: SessionMetadata {
                        title: Some(agent.title.clone()),
                        agent: Some("Tern".into()),
                        workspace_id: agent.session_id.clone(),
                        workspace_label: agent.session_label.clone(),
                        tab_id: agent.tab_id.clone(),
                        tab_label: agent.tab_label.clone(),
                        cwd: Some(agent.cwd.clone()),
                        ..SessionMetadata::default()
                    },
                    outcome_authoritative: false,
                    outcome: None,
                });
            }
            snapshots.push((records, counts));
        }
        for result in &self.results {
            if !bounded(&result.operation_id)
                || !bounded(&result.pane)
                || !optional_sized(&result.error)
                || matches!(result.status, TernResultStatus::Accepted) && result.error.is_some()
            {
                return Err("invalid Tern command result".into());
            }
        }
        Ok(snapshots)
    }
}

pub fn source_id(window: &str, host: &str) -> String {
    let mut source = String::with_capacity(6 + (window.len() + host.len()) * 2);
    source.push_str("tern:");
    for (index, component) in [window, host].into_iter().enumerate() {
        if index != 0 {
            source.push(':');
        }
        for byte in component.bytes() {
            use std::fmt::Write;
            let _ = write!(source, "{byte:02x}");
        }
    }
    source
}
