//! Tern window exchange, binding fences, and prompt delivery authority.
//! The only dependency on the application is the host-neutral contracts port.
mod protocol;
mod registry;
mod transport;
mod evidence;

pub use protocol::{TernAgent, TernAgentState, TernCommand, TernExchangeErrorCode, TernExchangeReply, TernExchangeRequest, TernHostInventory, TernHostReply, TernHostStatus, TernResult, TernResultStatus, FRESHNESS, MAX_EXCHANGE_BYTES, MAX_RESPONSE_BYTES};
pub use transport::{decode_exchange_request, send_exchange};

use desktop_pet_contracts::*;
use registry::{TernRegistry, Window, Host, Observation};
use std::sync::{Arc, Mutex, OnceLock};
use std::sync::mpsc::Receiver;
use std::time::Instant;

pub const PROVIDER_ID: &str = "tern";
pub const PROVIDER_LABEL: &str = "Tern";

struct RegistryState {
    enabled: bool,
    registry: TernRegistry,
}

pub struct TernIntegration {
    state: Mutex<RegistryState>,
    runtime: OnceLock<Arc<dyn RuntimePort>>,
}

impl Default for TernIntegration {
    fn default() -> Self { Self::new() }
}

impl TernIntegration {
    pub fn new() -> Self {
        Self { state: Mutex::new(RegistryState { enabled: true, registry: TernRegistry::default() }), runtime: OnceLock::new() }
    }

    pub fn extensions(self: &Arc<Self>) -> IntegrationExtensions {
        IntegrationExtensions { control: vec![self.exchange_handler(), Arc::new(evidence::EvidenceHandler { integration: self.clone() })], cli: vec![Arc::new(transport::ExchangeCli)], lifecycle: vec![] }
    }

    pub fn exchange_handler(self: &Arc<Self>) -> Arc<dyn ControlExtension> {
        Arc::new(ExchangeHandler { integration: self.clone() })
    }

    /// Obtain both locks in the sole permitted order, domain then registry.
    pub fn exchange(&self, request: TernExchangeRequest) -> Result<TernExchangeReply, String> {
        let runtime = self.runtime.get().ok_or("Tern runtime is not started")?;
        // Validate the complete inventory and receipts before any mutation.
        let normalized = request.normalize();
        let mut reply = None;
        let mut failure = None;
        runtime.with_domain(&mut |domain| {
            match self.state.lock() {
                Ok(state) => {
                    reply = Some(match &normalized {
                        Ok(snapshots) => exchange_transaction(self, domain, state, &request, snapshots, Instant::now()),
                        Err(detail) => TernExchangeReply::error(domain.instance_id().into(), TernExchangeErrorCode::Rejected, detail.clone()),
                    });
                }
                Err(_) => failure = Some("Tern source registry lock poisoned".to_owned()),
            }
        })?;
        if let Some(error) = failure { return Err(error); }
        let reply = reply.ok_or("Tern domain callback was not invoked")?;
        if reply.ok { runtime.wake_ui(); }
        Ok(reply)
    }

    fn retire_locked(domain: &mut dyn DomainAccess, state: &mut RegistryState) {
        // No worker exists: all exchanges and queue admissions use this transaction.
        state.registry.retire(domain);
    }
}

pub fn registration() -> (Arc<dyn Integration>, IntegrationExtensions) {
    let integration = Arc::new(TernIntegration::new());
    let extensions = integration.extensions();
    (integration, extensions)
}

impl Integration for TernIntegration {
    fn id(&self) -> &'static str { PROVIDER_ID }
    fn start(&self, runtime: Arc<dyn RuntimePort>) -> Result<(), String> {
        self.runtime.set(runtime).map_err(|_| "Tern runtime already started".to_owned())
    }
    fn tick(&self, now: Instant) {
        let Some(runtime) = self.runtime.get() else { return; };
        let mut changed = false;
        let result = runtime.with_domain(&mut |domain| {
            match self.state.lock() {
                Ok(mut state) => {
                    for (source, generation) in state.registry.expire(now) {
                        changed |= domain.mark_source_offline(&source, generation);
                    }
                    changed |= state.registry.prune_offline(domain, now);
                }
                Err(_) => eprintln!("Tern source registry lock poisoned"),
            }
        });
        if let Err(error) = result { eprintln!("Tern source expiry failed: {error}"); }
        if changed { runtime.wake_ui(); }
    }
    fn reclaim_expired_sources(&self, now: Instant, domain: &mut dyn DomainAccess) -> usize {
        let Ok(mut state) = self.state.lock() else {
            eprintln!("Tern capacity reclamation failed: registry lock poisoned");
            return 0;
        };
        expire(domain, &mut state.registry, now);
        let candidate = state.registry.expired_hosts(now)
            .filter(|entry| domain.source_generation(&entry.source) == Some(entry.generation))
            .min_by_key(|entry| entry.last_seen)
            .map(|entry| (entry.source.clone(), entry.generation));
        if let Some((source, generation)) = candidate {
            if domain.remove_offline_source(&source, generation) {
                state.registry.remove_source(&source, generation);
                return 1;
            }
        }
        0
    }
    fn set_enabled(&self, enabled: bool, domain: &mut dyn DomainAccess) {
        match self.state.lock() {
            Ok(mut state) => {
                if !enabled { Self::retire_locked(domain, &mut state); }
                state.enabled = enabled;
            }
            Err(_) => eprintln!("Tern source registry lock poisoned"),
        }
    }
    fn retire(&self, domain: &mut dyn DomainAccess) {
        match self.state.lock() {
            Ok(mut state) => Self::retire_locked(domain, &mut state),
            Err(_) => eprintln!("Tern source retirement failed: registry lock poisoned"),
        }
    }
    fn shutdown(&self) {
        // Retire has already removed sources inside the domain gate transaction.
        // This adapter has no worker threads to join.
        match self.state.lock() {
            Ok(mut state) => {
                state.enabled = false;
                state.registry.reject_all_pending(PromptError::Offline);
                state.registry.clear();
            }
            Err(_) => eprintln!("Tern shutdown failed: registry lock poisoned"),
        }
    }
    fn submit_prompt(&self, key: SessionKey, text: String) -> Result<Receiver<Result<PromptReceipt, PromptError>>, PromptError> {
        if text.trim().is_empty() { return Err(PromptError::Empty); }
        let runtime = self.runtime.get().ok_or(PromptError::NotReady)?;
        let mut admission = Err(PromptError::NotReady);
        let mut submission = Some((key, text));
        runtime.with_domain(&mut |domain| {
            let Some((key, text)) = submission.take() else { return; };
            admission = (|| {
                domain.mutation_allowed().map_err(PromptError::Other)?;
                if domain.instance_id().is_empty() { return Err(PromptError::NotReady); }
                let (target, provider) = domain.prompt_route(&key)?;
                if provider != PROVIDER_ID { return Err(PromptError::Unsupported); }
                let descriptor = domain.source_descriptor(&target.source).ok_or(PromptError::StaleTarget)?;
                if descriptor.provider != PROVIDER_ID || !descriptor.capabilities.prompt { return Err(PromptError::ReadOnly); }
                if domain.source_generation(&target.source) != Some(key.generation) { return Err(PromptError::StaleTarget); }
                let mut state = self.state.lock().map_err(|_| PromptError::Other("Tern source registry lock poisoned".into()))?;
                if !state.enabled { return Err(PromptError::Offline); }
                let (window, epoch, host, observation_generation) = state.registry.route(&target.source, key.generation).ok_or(PromptError::StaleTarget)?;
                state.registry.queue(&window, epoch, &host, observation_generation, key, &target.pane_id, text, domain.instance_id())
            })();
        }).map_err(|error| PromptError::Other(format!("Tern source admission failed: {error}")))?;
        admission
    }
    fn submit_worktree_remove(&self, _target: WorktreeRemoveTarget) -> Result<Receiver<Result<(), WorktreeRemoveError>>, WorktreeRemoveError> {
        Err(WorktreeRemoveError::Unsupported)
    }
}

struct ExchangeHandler { integration: Arc<TernIntegration> }
impl ControlExtension for ExchangeHandler {
    fn kind(&self) -> &'static str { "tern" }
    fn max_request_bytes(&self) -> usize { MAX_EXCHANGE_BYTES + 2 }
    fn max_response_bytes(&self) -> usize { MAX_RESPONSE_BYTES }
    fn handle_frame(&self, frame: &[u8]) -> Result<Vec<u8>, String> {
        let reply = match decode_exchange_request(frame) {
            Ok(request) => self.integration.exchange(request)?,
            Err(error) => {
                let runtime = self.integration.runtime.get().ok_or("Tern runtime is not started")?;
                let mut instance_id = String::new();
                runtime.with_domain(&mut |domain| instance_id = domain.instance_id().into())?;
                TernExchangeReply::error(instance_id, TernExchangeErrorCode::Rejected, error)
            }
        };
        protocol::serialize_response(&reply).map_err(|error| error.to_string())
    }
}

fn expire(domain: &mut dyn DomainAccess, registry: &mut TernRegistry, now: Instant) {
    for (source, generation) in registry.expire(now) { domain.mark_source_offline(&source, generation); }
}


fn lose_host(domain: &mut dyn DomainAccess, registry: &mut TernRegistry, window: &str, id: &str, now: Instant) {
    if let Some((source, generation)) = registry.lose_host(window, id, now) {
        domain.mark_source_offline(source, generation);
    }
}

fn ensure_parent_capacity(domain: &mut dyn DomainAccess, registry: &mut TernRegistry, now: Instant) -> bool {
    // Parent bindings are bounded independently of the shared child-source
    // budget. No live parent or child and no pending work may be evicted.
    while registry.len() >= protocol::MAX_WINDOWS {
        let candidate = registry.expired_registrations(now)
            .filter(|(_, window)| window.hosts.values().all(|host| host.offline && domain.source_generation(&host.source) == Some(host.generation)))
            .min_by_key(|(_, window)| window.last_seen)
            .map(|(id, _)| id.to_owned());
        let Some(id) = candidate else { return false; };
        let window = registry.get(&id).expect("selected parent");
        for host in window.hosts.values() {
            if !domain.remove_offline_source(&host.source, host.generation) { return false; }
        }
        registry.retire_window(&id);
    }
    true
}

fn exchange_transaction<'a>(integration: &'a TernIntegration, domain: &mut dyn DomainAccess, mut state: std::sync::MutexGuard<'a, RegistryState>, request: &TernExchangeRequest, snapshots: &[(Vec<AgentRecord>, SourceCounts)], now: Instant) -> TernExchangeReply {
    use TernExchangeErrorCode::*;
    let instance_id = domain.instance_id().to_owned();
    let error = |code, message: &str| TernExchangeReply::error(instance_id.clone(), code, message.into());
    if !state.enabled || instance_id.is_empty() { return error(Rejected, "Tern observation is unavailable"); }
    let registry = &mut state.registry;
    if registry.retired_epoch(&request.window).is_some_and(|epoch| request.epoch <= epoch) {
        return error(SourceRetired, "stale retired Tern window epoch");
    }
    let previous = registry.get(&request.window);
    if previous.is_none() && request.instance_id.is_some() { return error(SourceRetired, "Tern window is retired"); }
    if previous.is_some() && request.instance_id.is_none() { return error(BindingRequired, "missing bound daemon instance"); }
    if request.instance_id.as_deref().is_some_and(|id| id != instance_id) { return error(InstanceChanged, "daemon instance changed"); }
    let new_epoch = previous.is_none_or(|previous| request.epoch > previous.epoch);
    if previous.is_some_and(|previous| request.epoch < previous.epoch || (request.epoch == previous.epoch && request.sequence <= previous.sequence)) {
        return error(Rejected, "stale Tern window epoch or sequence");
    }
    if new_epoch && !request.results.is_empty() { return error(Rejected, "Tern results require the currently bound window epoch"); }
    if !new_epoch {
        if let Err(detail) = registry.validate_result(request) { return TernExchangeReply::error(instance_id.clone(), ReceiptRejected, detail); }
    }
    // Complete structural/binding/receipt validation precedes all lifecycle mutation.
    expire(domain, registry, now);
    if new_epoch {
        if registry.get(&request.window).is_none() && !ensure_parent_capacity(domain, registry, now) {
            return error(Rejected, "Tern window registry is full");
        }
        registry.offline_window_hosts(&request.window, now, domain);
        registry.reject_pending(&request.window, PromptError::StaleTarget);
        let mut next = Window::new(request.epoch, now);
        if let Some(previous) = registry.get_mut(&request.window) {
            next.hosts = std::mem::take(&mut previous.hosts);
            for host in next.hosts.values_mut() { host.offline = true; }
        }
        registry.insert(request.window.clone(), next);
    }
    let omitted: Vec<_> = registry.get(&request.window).expect("registered parent").observations.keys()
        .filter(|id| !request.hosts.iter().any(|host| &host.host == *id)).cloned().collect();
    for id in omitted { lose_host(domain, registry, &request.window, &id, now); }
    let mut order: Vec<usize> = (0..request.hosts.len()).collect();
    order.sort_unstable_by_key(|&index| {
        let host = &request.hosts[index];
        (!registry.get(&request.window).expect("registered parent").hosts.contains_key(&host.host), !host.is_local, host.host.parse::<u64>().expect("validated host"))
    });
    let mut replies: Vec<Option<TernHostReply>> = (0..request.hosts.len()).map(|_| None).collect();
    for index in order {
        let inventory = &request.hosts[index];
        let (records, counts) = &snapshots[index];
        let source = protocol::source_id(&request.window, &inventory.host);
        let window = state.registry.get(&request.window).expect("registered parent");
        let child = window.hosts.get(&inventory.host);
        let current_generation = child.map_or(0, |host| host.generation);
        let invalid = window.observations.get(&inventory.host).is_some_and(|observed| {
            inventory.observation_generation < observed.generation
                || (inventory.observation_generation == observed.generation
                    && (inventory.is_local != observed.is_local || (observed.requires_new && inventory.status == TernHostStatus::Available)))
        });
        if invalid {
            replies[index] = Some(TernHostReply::new(inventory, current_generation, Some("stale Tern host observation or locality".into())));
            continue;
        }
        if inventory.status != TernHostStatus::Available {
            state.registry.get_mut(&request.window).expect("registered parent").observations.insert(inventory.host.clone(),
                Observation { generation: inventory.observation_generation, is_local: inventory.is_local, requires_new: true });
            lose_host(domain, &mut state.registry, &request.window, &inventory.host, now);
            replies[index] = Some(TernHostReply::new(inventory, current_generation, None));
            continue;
        }
        let replacement = child.is_none_or(|host| host.offline || host.observation_generation != inventory.observation_generation);
        let generation = if replacement {
            domain.source_generation(&source).into_iter().chain(domain.retired_source_generation(&source)).max().unwrap_or(0)
                .checked_add(1).filter(|generation| *generation <= protocol::MAX_SAFE_INTEGER)
        } else { Some(current_generation) };
        let Some(generation) = generation else {
            replies[index] = Some(TernHostReply::new(inventory, current_generation, Some("Tern source generation exhausted".into())));
            continue;
        };
        if domain.source_admission(&source, generation) == SourceAdmission::Rejected {
            replies[index] = Some(TernHostReply::new(inventory, current_generation, Some("cannot register or publish Tern host".into())));
            continue;
        }
        let label = if inventory.label.chars().any(meaningful_label_char) { &inventory.label } else { &inventory.host };
        if replacement {
            // Cross-provider pressure dispatch can lock this registry. Keep the
            // domain locked but release the registry until admission returns.
            drop(state);
            let capacity = domain.ensure_source_capacity(&source, generation, now);
            state = match integration.state.lock() {
                Ok(state) => state,
                Err(_) => return error(Rejected, "Tern source registry lock poisoned"),
            };
            if capacity != SourceAdmission::Allowed || !domain.begin_source(SourceDescriptor {
                id: source.clone(), provider: PROVIDER_ID.into(), label: label.clone(),
                locality: if inventory.is_local { SourceLocality::Local } else { SourceLocality::Remote },
                capabilities: SourceCapabilities { prompt: inventory.is_local, remove_worktree: false },
            }, generation) {
                replies[index] = Some(TernHostReply::new(inventory, current_generation, Some("cannot register or publish Tern host".into())));
                continue;
            }
            state.registry.get_mut(&request.window).expect("registered parent").reject_host_pending(&inventory.host, PromptError::StaleTarget);
            state.registry.clear_offline(&source);
        }
        let pane_ids: Arc<[String]> = records.iter().map(|record| record.pane_id.clone()).collect();
        if !domain.publish_source_snapshot(&source, generation, &mut records.iter(), *counts, pane_ids, &[], now) {
            replies[index] = Some(TernHostReply::new(inventory, current_generation, Some("cannot publish Tern host snapshot".into())));
            continue;
        }
        domain.set_source_label(&source, generation, label);
        state.registry.clear_offline(&source);
        let window = state.registry.get_mut(&request.window).expect("registered parent");
        window.observations.insert(inventory.host.clone(), Observation {
            generation: inventory.observation_generation, is_local: inventory.is_local, requires_new: false,
        });
        window.hosts.insert(inventory.host.clone(), Host {
            source, generation, observation_generation: inventory.observation_generation,
            is_local: inventory.is_local, last_seen: now, offline: false,
        });
        replies[index] = Some(TernHostReply::new(inventory, generation, None));
    }
    let hosts: Vec<_> = replies.into_iter().map(|reply| reply.expect("processed host")).collect();
    let host_bytes = match protocol::host_reply_bytes(&hosts) {
        Ok(bytes) => bytes,
        Err(detail) => return error(Rejected, &format!("{detail:?}")),
    };
    let registry = &mut state.registry;
    let window = registry.get_mut(&request.window).expect("registered parent");
    window.sequence = request.sequence;
    window.last_seen = now;
    window.offline = false;
    window.offline_since = None;
    window.last_host_reply_bytes = host_bytes;
    window.bound = true;
    if request.instance_id.is_some() && request.hosts.iter().any(|inventory| inventory.is_local
        && inventory.status == TernHostStatus::Available
        && hosts.iter().any(|reply| reply.host == inventory.host && reply.generation > 0 && reply.error.is_none())) {
        window.confirmed_sequence = Some(request.sequence);
    }
    registry.settle(&request.window, request.results.first());
    let command = request.instance_id.as_ref().and_then(|_| registry.pending_target(&request.window)).and_then(|(key, pane)| {
        match domain.prompt_route(&key) {
            Ok((target, provider)) if provider == PROVIDER_ID && target.pane_id == pane && domain.mutation_allowed().is_ok() => {
                match registry.route(&target.source, key.generation) {
                    Some((window, epoch, host, observation_generation)) if window == request.window && epoch == request.epoch
                        && request.hosts.iter().any(|inventory| inventory.host == host && inventory.is_local && inventory.status == TernHostStatus::Available && inventory.observation_generation == observation_generation)
                        && hosts.iter().any(|reply| reply.host == host && reply.error.is_none()) => registry.offer(&request.window, &instance_id),
                    _ => { registry.reject_pending(&request.window, PromptError::StaleTarget); None }
                }
            }
            _ => { registry.reject_pending(&request.window, PromptError::StaleTarget); None }
        }
    });
    TernExchangeReply { ok: true, instance_id, hosts, command, error: None, error_code: None }
}

#[cfg(test)]
mod tests;

fn meaningful_label_char(character: char) -> bool {
    !character.is_whitespace() && !character.is_control()
        && !matches!(character, '\u{00AD}' | '\u{061C}' | '\u{200B}' | '\u{200E}'..='\u{200F}'
            | '\u{2028}'..='\u{202E}' | '\u{2060}'..='\u{206F}' | '\u{FEFF}' | '\u{FFF9}'..='\u{FFFB}')
}
