use crate::protocol::*;
use desktop_pet_contracts::{DomainAccess, PromptError, PromptReceipt, SessionKey};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::time::Instant;
static NEXT_COMMAND: AtomicU64 = AtomicU64::new(0);

#[derive(Debug)]
pub(crate) struct TernRegistry {
    windows: HashMap<String, Window>,
    retired_epochs: HashMap<String, u64>,
    // Keep first-loss clocks independently of child routing so an orphaned
    // offline source still retires without weakening domain generation fences.
    offline_sources: HashMap<String, OfflineSource>,
}

#[derive(Debug)]
pub(crate) struct Window {
    pub(crate) epoch: u64,
    pub(crate) sequence: u64,
    pub(crate) hosts: HashMap<String, Host>,
    pub(crate) observations: HashMap<String, Observation>,
    pub(crate) last_host_reply_bytes: usize,
    pub(crate) bound: bool,
    pub(crate) confirmed_sequence: Option<u64>,
    pub(crate) last_seen: Instant,
    pub(crate) offline: bool,
    pub(crate) offline_since: Option<Instant>,
    pending: Option<Pending>,
}

#[derive(Debug)]
struct OfflineSource {
    generation: u64,
    since: Instant,
}

fn record_offline(sources: &mut HashMap<String, OfflineSource>, source: &str, generation: u64, since: Instant) {
    if let Some(previous) = sources.get_mut(source) {
        if previous.generation == generation {
            previous.since = previous.since.min(since);
        } else {
            *previous = OfflineSource { generation, since };
        }
        return;
    }
    sources.insert(source.to_owned(), OfflineSource { generation, since });
}

#[derive(Debug)]
pub(crate) struct Host {
    pub(crate) source: String,
    pub(crate) generation: u64,
    pub(crate) observation_generation: u64,
    pub(crate) is_local: bool,
    pub(crate) last_seen: Instant,
    pub(crate) offline: bool,
}

#[derive(Debug)]
pub(crate) struct Observation {
    pub(crate) generation: u64,
    pub(crate) is_local: bool,
    // Explicit loss requires a newer plugin observation. Native expiry alone does not.
    pub(crate) requires_new: bool,
}

#[derive(Debug)]
struct Pending {
    key: SessionKey,
    host: String,
    observation_generation: u64,
    command: TernCommand,
    sender: SyncSender<Result<PromptReceipt, PromptError>>,
    offered: bool,
}

impl Pending {
    fn reject(self, error: PromptError) {
        let error = if self.offered {
            PromptError::UnknownDelivery
        } else {
            error
        };
        let _ = self.sender.send(Err(error));
    }
}

impl Default for TernRegistry {
    fn default() -> Self {
        Self {
            windows: HashMap::new(),
            retired_epochs: HashMap::new(),
            offline_sources: HashMap::new(),
        }
    }
}

impl TernRegistry {
    pub(crate) fn get(&self, window: &str) -> Option<&Window> {
        self.windows.get(window)
    }
    pub(crate) fn windows(&self) -> impl Iterator<Item = (&str, &Window)> {
        self.windows.iter().map(|(id, window)| (id.as_str(), window))
    }
    pub(crate) fn get_mut(&mut self, window: &str) -> Option<&mut Window> {
        self.windows.get_mut(window)
    }
    pub(crate) fn len(&self) -> usize {
        self.windows.len()
    }
    pub(crate) fn retired_epoch(&self, window: &str) -> Option<u64> {
        self.retired_epochs.get(window).copied()
    }
    pub(crate) fn insert(&mut self, window: String, entry: Window) {
        self.windows.insert(window, entry);
    }
    pub(crate) fn expired_registrations(
        &self,
        now: Instant,
    ) -> impl Iterator<Item = (&str, &Window)> {
        self.windows.iter().filter_map(move |(window, entry)| {
            (entry.offline
                && entry.pending.is_none()
                && now.saturating_duration_since(entry.last_seen) >= FRESHNESS)
                .then_some((window.as_str(), entry))
        })
    }
    pub(crate) fn expired_hosts(&self, now: Instant) -> impl Iterator<Item = &Host> {
        self.windows.values().flat_map(move |entry| {
            let parent_expired = entry.offline && now.saturating_duration_since(entry.last_seen) >= FRESHNESS;
            entry.hosts.values().filter(move |host| host.offline
                && (parent_expired || now.saturating_duration_since(host.last_seen) >= FRESHNESS))
        })
    }
    pub(crate) fn remove_source(&mut self, source: &str, generation: u64) {
        if self.offline_sources.get(source).is_some_and(|entry| entry.generation == generation) {
            self.offline_sources.remove(source);
        }
        for entry in self.windows.values_mut() {
            let id = entry.hosts.iter().find_map(|(id, host)| {
                (host.source == source && host.generation == generation).then(|| id.clone())
            });
            if let Some(id) = id {
                entry.reject_host_pending(&id, PromptError::StaleTarget);
                entry.hosts.remove(&id);
                // Keep observation high water marks and the parent binding.
                break;
            }
        }
    }
    pub(crate) fn retire_window(&mut self, window: &str) {
        if let Some(mut entry) = self.windows.remove(window) {
            if let Some(pending) = entry.pending.take() { pending.reject(PromptError::StaleTarget); }
            for host in entry.hosts.into_values() {
                if self.offline_sources.get(&host.source).is_some_and(|offline| offline.generation == host.generation) {
                    self.offline_sources.remove(&host.source);
                }
            }
            self.retired_epochs.entry(window.to_owned())
                .and_modify(|epoch| *epoch = (*epoch).max(entry.epoch)).or_insert(entry.epoch);
        }
    }
    pub(crate) fn retire(&mut self, domain: &mut dyn DomainAccess) {
        for (window, mut entry) in self.windows.drain() {
            if let Some(pending) = entry.pending.take() { pending.reject(PromptError::Offline); }
            for host in entry.hosts.into_values() {
                domain.remove_source(&host.source, host.generation);
                if self.offline_sources.get(&host.source).is_some_and(|offline| offline.generation == host.generation) {
                    self.offline_sources.remove(&host.source);
                }
            }
            self.retired_epochs.entry(window).and_modify(|epoch| *epoch = (*epoch).max(entry.epoch)).or_insert(entry.epoch);
        }
        for (source, offline) in self.offline_sources.drain() {
            domain.remove_source(&source, offline.generation);
        }
    }
    pub(crate) fn clear(&mut self) { self.windows.clear(); self.retired_epochs.clear(); self.offline_sources.clear(); }
    #[cfg(test)]
    pub(crate) fn is_empty(&self) -> bool { self.windows.is_empty() }
    pub(crate) fn route(&self, source: &str, generation: u64) -> Option<(String, u64, String, u64)> {
        self.windows.iter().find_map(|(window, entry)| {
            if entry.offline || entry.last_seen.elapsed() >= FRESHNESS { return None; }
            entry.hosts.iter().find_map(|(id, host)| {
                (host.source == source && host.generation == generation && host.is_local
                    && !host.offline && host.last_seen.elapsed() < FRESHNESS)
                    .then(|| (window.clone(), entry.epoch, id.clone(), host.observation_generation))
            })
        })
    }
    pub(crate) fn expire(&mut self, now: Instant) -> Vec<(String, u64)> {
        let mut offline = Vec::new();
        for entry in self.windows.values_mut() {
            let parent_deadline = entry.last_seen + FRESHNESS;
            let parent_expired = now >= parent_deadline;
            if parent_expired {
                entry.offline = true;
                entry.offline_since = Some(entry.offline_since.map_or(parent_deadline, |since| since.min(parent_deadline)));
            }
            let mut pending_lost = false;
            for (id, host) in &mut entry.hosts {
                let host_deadline = host.last_seen + FRESHNESS;
                if parent_expired || now >= host_deadline {
                    if !host.offline {
                        host.offline = true;
                        let since = if parent_expired { host_deadline.min(parent_deadline) } else { host_deadline };
                        record_offline(&mut self.offline_sources, &host.source, host.generation, since);
                        offline.push((host.source.clone(), host.generation));
                    }
                    pending_lost |= entry.pending.as_ref().is_some_and(|pending| pending.host == *id);
                }
            }
            if pending_lost || parent_expired {
                if let Some(pending) = entry.pending.take() { pending.reject(PromptError::Offline); }
            }
        }
        offline
    }

    pub(crate) fn lose_host(&mut self, window: &str, id: &str, now: Instant) -> Option<(&str, u64)> {
        let entry = self.windows.get_mut(window).expect("registered parent");
        if let Some(observed) = entry.observations.get_mut(id) { observed.requires_new = true; }
        entry.reject_host_pending(id, PromptError::Offline);
        let host = entry.hosts.get_mut(id)?;
        host.offline = true;
        record_offline(&mut self.offline_sources, &host.source, host.generation, now);
        Some((&host.source, host.generation))
    }

    pub(crate) fn offline_window_hosts(&mut self, window: &str, now: Instant, domain: &mut dyn DomainAccess) {
        if let Some(entry) = self.windows.get_mut(window) {
            for host in entry.hosts.values_mut() {
                host.offline = true;
                record_offline(&mut self.offline_sources, &host.source, host.generation, now);
                domain.mark_source_offline(&host.source, host.generation);
            }
        }
    }

    pub(crate) fn clear_offline(&mut self, source: &str) {
        self.offline_sources.remove(source);
    }

    /// Only the control tick prunes retention. Exchanges and pressure reclamation
    /// keep their existing freshness-only behavior.
    pub(crate) fn prune_offline(&mut self, domain: &mut dyn DomainAccess, now: Instant) -> bool {
        let mut changed = false;
        let windows = &mut self.windows;
        self.offline_sources.retain(|source, offline| {
            if now.saturating_duration_since(offline.since) < OFFLINE_GRACE { return true; }
            let current = windows.values().all(|window| window.hosts.iter().all(|(id, host)| {
                host.source != *source || (host.generation == offline.generation && host.offline
                    && !window.pending.as_ref().is_some_and(|pending| pending.host == *id))
            }));
            if !current || !domain.remove_offline_source(source, offline.generation) {
                return true;
            }
            for window in windows.values_mut() {
                window.hosts.retain(|_, host| host.source != *source || host.generation != offline.generation);
            }
            changed = true;
            false
        });
        let retired_epochs = &mut self.retired_epochs;
        windows.retain(|id, window| {
            if window.offline && window.hosts.is_empty() && window.pending.is_none()
                && window.offline_since.is_some_and(|since| now.saturating_duration_since(since) >= OFFLINE_GRACE) {
                retired_epochs.entry(id.clone()).and_modify(|epoch| *epoch = (*epoch).max(window.epoch)).or_insert(window.epoch);
                changed = true;
                false
            } else {
                true
            }
        });
        changed
    }
    pub(crate) fn queue(
        &mut self,
        window: &str,
        epoch: u64,
        host: &str,
        observation_generation: u64,
        key: SessionKey,
        pane: &str,
        text: String,
        instance_id: &str,
    ) -> Result<Receiver<Result<PromptReceipt, PromptError>>, PromptError> {
        let entry = self.windows.get_mut(window).ok_or(PromptError::Offline)?;
        let child = entry.hosts.get(host).ok_or(PromptError::StaleTarget)?;
        if !child.is_local { return Err(PromptError::ReadOnly); }
        if entry.epoch != epoch || child.generation != key.generation
            || child.observation_generation != observation_generation
            || entry.offline || child.offline || !entry.bound
            || entry.last_seen.elapsed() >= FRESHNESS || child.last_seen.elapsed() >= FRESHNESS
        { return Err(PromptError::StaleTarget); }
        if entry.pending.is_some() {
            return Err(PromptError::Busy);
        }
        let operation_id = format!(
            "tern-prompt-{}-{}",
            std::process::id(),
            NEXT_COMMAND
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
                .map_err(|_| PromptError::Other("Tern command IDs exhausted".into()))?
        );
        check_command_response(instance_id, entry.last_host_reply_bytes, &operation_id, pane, &text)?;
        let (tx, rx) = mpsc::sync_channel(1);
        entry.pending = Some(Pending {
            key,
            host: host.to_owned(),
            observation_generation,
            command: TernCommand {
                operation_id,
                pane: pane.to_owned(),
                text,
            },
            sender: tx,
            offered: false,
        });
        Ok(rx)
    }
    pub(crate) fn validate_result(&self, request: &TernExchangeRequest) -> Result<(), String> {
        let pending = self
            .windows
            .get(&request.window)
            .and_then(|window| window.pending.as_ref());
        for result in &request.results {
            if !pending.is_some_and(|pending| {
                pending.offered
                    && pending.command.operation_id == result.operation_id
                    && pending.command.pane == result.pane
                    && request.hosts.iter().any(|host| host.host == pending.host && host.is_local
                        && host.observation_generation == pending.observation_generation)
            }) {
                return Err("stale or unrecognized Tern command result".into());
            }
        }
        Ok(())
    }
    pub(crate) fn settle(&mut self, window: &str, result: Option<&TernResult>) {
        let Some(entry) = self.windows.get_mut(window) else {
            return;
        };
        if let Some(pending) = entry.pending.as_ref() {
            if pending.offered {
                let pending = entry.pending.take().expect("offered command");
                let receipt = match result {
                    Some(TernResult {
                        status: TernResultStatus::Accepted,
                        ..
                    }) => Ok(PromptReceipt::Accepted),
                    Some(TernResult {
                        status: TernResultStatus::Failed,
                        error,
                        ..
                    }) => Err(PromptError::Other(
                        error.clone().unwrap_or_else(|| "Tern rejected ask".into()),
                    )),
                    None => Err(PromptError::UnknownDelivery),
                };
                let _ = pending.sender.send(receipt);
            }
        }
    }
    pub(crate) fn pending_target(&self, window: &str) -> Option<(SessionKey, String)> {
        let pending = self.windows.get(window)?.pending.as_ref()?;
        (!pending.offered).then(|| (pending.key.clone(), pending.command.pane.clone()))
    }
    pub(crate) fn offer(&mut self, window: &str, instance_id: &str) -> Option<TernCommand> {
        let entry = self.windows.get(window)?;
        let pending = entry.pending.as_ref()?;
        if pending.offered {
            return None;
        }
        let child = entry.hosts.get(&pending.host);
        let admission = if child.is_some_and(|child| !child.is_local) {
            Err(PromptError::ReadOnly)
        } else if entry.offline || entry.last_seen.elapsed() >= FRESHNESS
            || child.is_none_or(|child| child.offline || child.last_seen.elapsed() >= FRESHNESS
                || child.generation != pending.key.generation
                || child.observation_generation != pending.observation_generation)
        {
            Err(PromptError::StaleTarget)
        } else {
            check_command_response(
                instance_id,
                entry.last_host_reply_bytes,
                &pending.command.operation_id,
                &pending.command.pane,
                &pending.command.text,
            )
        };
        if let Err(error) = admission {
            self.reject_pending(window, error);
            return None;
        }
        let pending = self.windows.get_mut(window)?.pending.as_mut()?;
        pending.offered = true;
        Some(TernCommand {
            operation_id: pending.command.operation_id.clone(),
            pane: pending.command.pane.clone(),
            text: std::mem::take(&mut pending.command.text),
        })
    }
    pub(crate) fn reject_pending(&mut self, window: &str, error: PromptError) {
        if let Some(pending) = self
            .windows
            .get_mut(window)
            .and_then(|entry| entry.pending.take())
        {
            pending.reject(error);
        }
    }
    pub(crate) fn reject_all_pending(&mut self, error: PromptError) {
        for entry in self.windows.values_mut() {
            if let Some(pending) = entry.pending.take() {
                pending.reject(error.clone());
            }
        }
    }
}

impl Window {
    pub(crate) fn new(epoch: u64, now: Instant) -> Self {
        Self {
            epoch, sequence: 0, hosts: HashMap::new(), observations: HashMap::new(),
            last_host_reply_bytes: 2, bound: false, confirmed_sequence: None, last_seen: now, offline: false, offline_since: None, pending: None,
        }
    }
    pub(crate) fn reject_host_pending(&mut self, host: &str, error: PromptError) {
        if self.pending.as_ref().is_some_and(|pending| pending.host == host) {
            if let Some(pending) = self.pending.take() { pending.reject(error); }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reply(text: String) -> TernExchangeReply {
        TernExchangeReply {
            ok: true,
            instance_id: "daemon-a".into(),
            hosts: (0..MAX_HOSTS).map(|id| TernHostReply {
                host: id.to_string(), observation_generation: 1, generation: MAX_SAFE_INTEGER,
                error: Some("\"\\\n한".repeat(70)), error_code: Some(TernExchangeErrorCode::Rejected),
            }).collect(),
            command: Some(TernCommand {
                operation_id: "boundary-operation".into(),
                pane: "pane-한".into(),
                text,
            }),
            error: None,
            error_code: None,
        }
    }

    #[test]
    fn real_reply_serializer_admits_exact_utf8_and_escaped_boundaries() {
        let escaped = "\"\\\n\t한🪶";
        let empty = serialize_response(&reply(String::new())).unwrap().len();
        let escaped_len = serde_json::to_string(escaped).unwrap().len() - 2;
        let text = format!(
            "{escaped}{}",
            "a".repeat(MAX_RESPONSE_BYTES - empty - escaped_len)
        );
        let exact = reply(text.clone());
        let bytes = serialize_response(&exact).unwrap();
        assert_eq!(bytes.len(), MAX_RESPONSE_BYTES);
        assert_eq!(bytes.last(), Some(&b'\n'));
        let decoded: TernExchangeReply = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(decoded.command.unwrap().text, text);
        assert_eq!(
            check_command_response(
                "daemon-a",
                host_reply_bytes(&exact.hosts).unwrap(),
                "boundary-operation",
                "pane-한",
                &text,
            ),
            Ok(())
        );
        let mut above = text.clone();
        above.push('a');
        assert_eq!(
            check_command_response(
                "daemon-a",
                host_reply_bytes(&exact.hosts).unwrap(),
                "boundary-operation",
                "pane-한",
                &above,
            ),
            Err(PromptError::TooLarge)
        );
        assert!(serialize_response(&reply(above)).is_err());
        let mut below = text;
        below.pop();
        assert_eq!(
            serialize_response(&reply(below.clone())).unwrap().len(),
            MAX_RESPONSE_BYTES - 1
        );
        assert_eq!(
            check_command_response(
                "daemon-a",
                host_reply_bytes(&exact.hosts).unwrap(),
                "boundary-operation",
                "pane-한",
                &below,
            ),
            Ok(())
        );
    }

    #[test]
    fn preoffer_size_invariant_fails_definitely_before_offered_state() {
        let mut registry = TernRegistry::default();
        let mut window = test_window(MAX_SAFE_INTEGER, Instant::now());
        let (sender, receipt) = mpsc::sync_channel(1);
        window.pending = Some(Pending {
            key: SessionKey {
                source_id: 0,
                generation: MAX_SAFE_INTEGER,
                terminal_id: "pane-한".into(),
            },
            host: "0".into(),
            observation_generation: 1,
            command: reply("a".repeat(MAX_RESPONSE_BYTES)).command.unwrap(),
            sender,
            offered: false,
        });
        registry.insert("window-a".into(), window);
        assert!(registry.offer("window-a", "daemon-a").is_none());
        assert_eq!(receipt.try_recv(), Ok(Err(PromptError::TooLarge)));
        assert!(registry.get("window-a").unwrap().pending.is_none());
        let key = SessionKey {
            source_id: 0,
            generation: MAX_SAFE_INTEGER,
            terminal_id: "pane-한".into(),
        };
        let accepted = registry
            .queue("window-a", 1, "0", 1, key, "pane-한", "next valid ask".into(), "daemon-a")
            .unwrap();
        let command = registry.offer("window-a", "daemon-a").unwrap();
        assert_eq!(command.text, "next valid ask");
        assert!(registry.offer("window-a", "daemon-a").is_none());
        registry.settle("window-a", None);
        assert_eq!(accepted.try_recv(), Ok(Err(PromptError::UnknownDelivery)));
    }

    #[test]
    fn freshness_boundary_finalizes_pending_before_selecting_registration() {
        let mut registry = TernRegistry::default();
        let now = Instant::now();
        registry.insert("window-a".into(), test_window(1, now));
        let key = SessionKey {
            source_id: 0,
            generation: 1,
            terminal_id: "pane".into(),
        };
        let receipt = registry
            .queue("window-a", 1, "0", 1, key.clone(), "pane", "ask".into(), "daemon-a")
            .unwrap();
        registry.get_mut("window-a").unwrap().last_seen = now - FRESHNESS;
        assert!(registry.route(&source_id("window-a", "0"), 1).is_none());
        assert!(matches!(
            registry.queue("window-a", 1, "0", 1, key, "pane", "stale".into(), "daemon-a",),
            Err(PromptError::StaleTarget)
        ));
        assert_eq!(registry.expired_registrations(now).count(), 0);
        assert_eq!(registry.expire(now), vec![(source_id("window-a", "0"), 1)]);
        assert_eq!(receipt.try_recv(), Ok(Err(PromptError::Offline)));
        assert_eq!(registry.expired_registrations(now).count(), 1);
    }

    #[test]
    fn canonical_error_codes_are_bounded_and_success_uses_host_shape() {
        let failure = TernExchangeReply::error(
            "daemon-a".into(),
            TernExchangeErrorCode::ReceiptRejected,
            "한".repeat(4096),
        );
        assert!(failure.error.as_ref().unwrap().len() <= MAX_FIELD_BYTES);
        let failure: serde_json::Value =
            serde_json::from_slice(&serialize_response(&failure).unwrap()).unwrap();
        assert_eq!(failure["error_code"], "receipt_rejected");
        assert_eq!(failure["hosts"], serde_json::json!([]));
        assert!(failure.get("generation").is_none());
        assert!(failure["command"].is_null());
        let mut success = reply("ask".into());
        success.command = None;
        let bytes = serialize_response(&success).unwrap();
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert!(value.get("error_code").is_none());
        assert!(serde_json::from_slice::<TernExchangeReply>(&bytes).is_ok());
        value["error_code"] = serde_json::Value::Null;
        assert!(serde_json::from_value::<TernExchangeReply>(value).is_err());
    }

    fn test_window(generation: u64, now: Instant) -> Window {
        let mut window = Window::new(1, now);
        window.bound = true;
        window.hosts.insert("0".into(), Host {
            source: source_id("window-a", "0"), generation, observation_generation: 1,
            is_local: true, last_seen: now, offline: false,
        });
        window
    }

    #[test]
    fn tern_host_id_and_error_boundaries_do_not_alias_or_overflow() {
        for valid in ["0", "1", "9007199254740991"] { assert!(canonical_host(valid)); }
        for invalid in ["", "00", "01", "-1", "+1", "1.0", "9007199254740992", "18446744073709551616"] {
            assert!(!canonical_host(invalid));
        }
        assert_eq!(source_id("a:b", "0"), "tern:613a62:30");
        assert_ne!(source_id("a", "12"), source_id("a", "21"));
        let mut text = "한".repeat(4096);
        truncate_utf8(&mut text, MAX_HOST_ERROR_BYTES);
        assert_eq!(text.len(), 510);
        assert_eq!(check_command_response("daemon-a", usize::MAX, "o", "p", "text"), Err(PromptError::TooLarge));
        assert_eq!(check_command_response("daemon-a", 1, "o", "p", "text"), Err(PromptError::TooLarge));
    }
    #[test]
    fn natural_expiry_records_the_earliest_child_or_parent_deadline() {
        for (parent_age, host_age) in [(0, 1), (1, 0)] {
            let mut registry = TernRegistry::default(); let base = Instant::now();
            let parent_seen = base + std::time::Duration::from_secs(parent_age);
            let mut window = test_window(1, parent_seen);
            window.hosts.get_mut("0").unwrap().last_seen = base + std::time::Duration::from_secs(host_age);
            registry.insert("window-a".into(), window);
            let now = base + FRESHNESS + OFFLINE_GRACE;
            assert_eq!(registry.expire(now), vec![(source_id("window-a", "0"), 1)]);
            assert_eq!(registry.offline_sources[&source_id("window-a", "0")].since, base + FRESHNESS);
            assert_eq!(registry.get("window-a").unwrap().offline_since, Some(parent_seen + FRESHNESS));
            assert!(registry.expire(now + OFFLINE_GRACE).is_empty());
            assert_eq!(registry.offline_sources[&source_id("window-a", "0")].since, base + FRESHNESS);
            assert_eq!(registry.get("window-a").unwrap().offline_since, Some(parent_seen + FRESHNESS));
        }
    }
}
