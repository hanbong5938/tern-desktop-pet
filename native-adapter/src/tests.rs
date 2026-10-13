use super::*;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::Duration;

struct Source {
    descriptor: SourceDescriptor,
    generation: u64,
    numeric_id: u64,
    connected: bool,
    records: Vec<AgentRecord>,
    counts: SourceCounts,
}
struct Domain {
    instance: String,
    gated: bool,
    sources: HashMap<String, Source>,
    retired: HashMap<String, u64>,
    next_id: u64,
    revision: u64,
    completions: Vec<CompletionObservation>,
    outcomes: Vec<OutcomeObservation>,
    integrations: Vec<std::sync::Weak<dyn Integration>>,
}
impl Default for Domain {
    fn default() -> Self {
        Self {
            instance: "daemon-a".into(),
            gated: false,
            sources: HashMap::new(),
            retired: HashMap::new(),
            next_id: 1,
            revision: 0,
            completions: vec![],
            outcomes: vec![],
            integrations: vec![],
        }
    }
}
impl DomainAccess for Domain {
    fn instance_id(&self) -> &str {
        &self.instance
    }
    fn mutation_allowed(&self) -> Result<(), String> {
        if self.gated {
            Err("Prepare gate closed".into())
        } else {
            Ok(())
        }
    }
    fn source_generation(&self, source: &str) -> Option<u64> {
        self.sources.get(source).map(|source| source.generation)
    }
    fn retired_source_generation(&self, source: &str) -> Option<u64> {
        self.retired.get(source).copied()
    }
    fn source_descriptor(&self, source: &str) -> Option<&SourceDescriptor> {
        self.sources.get(source).map(|source| &source.descriptor)
    }
    fn set_source_label(&mut self, source: &str, generation: u64, label: &str) -> bool {
        let Some(entry) = self
            .sources
            .get_mut(source)
            .filter(|entry| entry.generation == generation)
        else {
            return false;
        };
        entry.descriptor.label = label.into();
        true
    }
    fn source_admission(&self, source: &str, generation: u64) -> SourceAdmission {
        if generation == 0
            || self
                .retired
                .get(source)
                .is_some_and(|retired| generation <= *retired)
        {
            SourceAdmission::Rejected
        } else if self.sources.contains_key(source) || self.sources.len() < MAX_SOURCES {
            SourceAdmission::Allowed
        } else {
            SourceAdmission::Capacity
        }
    }
    fn ensure_source_capacity(
        &mut self,
        source: &str,
        generation: u64,
        now: Instant,
    ) -> SourceAdmission {
        if self.source_admission(source, generation) == SourceAdmission::Capacity {
            let integrations = self.integrations.clone();
            for integration in integrations {
                if let Some(integration) = integration.upgrade() {
                    integration.reclaim_expired_sources(now, self);
                }
                if self.source_admission(source, generation) != SourceAdmission::Capacity {
                    break;
                }
            }
        }
        self.source_admission(source, generation)
    }
    fn remove_offline_source(&mut self, source: &str, generation: u64) -> bool {
        if self
            .sources
            .get(source)
            .is_some_and(|entry| entry.generation == generation && !entry.connected)
        {
            self.remove_source(source, generation)
        } else {
            false
        }
    }
    fn begin_source(&mut self, descriptor: SourceDescriptor, generation: u64) -> bool {
        if self.ensure_source_capacity(&descriptor.id, generation, Instant::now())
            != SourceAdmission::Allowed
            || self
                .source_generation(&descriptor.id)
                .is_some_and(|current| generation <= current)
        {
            return false;
        }
        let numeric_id = self
            .sources
            .get(&descriptor.id)
            .map(|source| source.numeric_id)
            .unwrap_or_else(|| {
                let id = self.next_id;
                self.next_id += 1;
                id
            });
        self.sources.insert(
            descriptor.id.clone(),
            Source {
                descriptor,
                generation,
                numeric_id,
                connected: false,
                records: vec![],
                counts: SourceCounts::default(),
            },
        );
        true
    }
    fn publish_source_snapshot(
        &mut self,
        source: &str,
        generation: u64,
        records: &mut dyn Iterator<Item = &AgentRecord>,
        counts: SourceCounts,
        _panes: Arc<[String]>,
        completions: &[(String, String)],
        _observed: Instant,
    ) -> bool {
        let Some(entry) = self
            .sources
            .get_mut(source)
            .filter(|source| source.generation == generation)
        else {
            return false;
        };
        entry.records = records.cloned().collect();
        entry.counts = counts;
        entry.connected = true;
        self.revision += 1;
        assert!(completions.is_empty(), "Tern must not invent completion");
        true
    }
    fn update_session_status(&mut self, update: SessionStatusUpdate<'_>) -> bool {
        let Some(entry) = self
            .sources
            .get_mut(update.source)
            .filter(|source| source.generation == update.generation)
        else {
            return false;
        };
        let Some(record) = entry.records.iter_mut().find(|record| {
            record.terminal_id == update.terminal_id && record.pane_id == update.pane_id
        }) else {
            return false;
        };
        record.status = update.status;
        entry.counts = update.counts;
        true
    }
    fn mark_source_offline(&mut self, source: &str, generation: u64) -> bool {
        let Some(entry) = self
            .sources
            .get_mut(source)
            .filter(|source| source.generation == generation)
        else {
            return false;
        };
        entry.connected = false;
        entry.counts = entry.counts.disconnected();
        true
    }
    fn remove_source(&mut self, source: &str, generation: u64) -> bool {
        if self.source_generation(source) != Some(generation) {
            return false;
        }
        self.sources.remove(source);
        self.retired.insert(source.into(), generation);
        true
    }
    fn invalidate_session_outcome(
        &mut self,
        source: &str,
        generation: u64,
        terminal: &str,
        pane: &str,
    ) {
        if let Some(entry) = self
            .sources
            .get_mut(source)
            .filter(|source| source.generation == generation)
        {
            if let Some(record) = entry
                .records
                .iter_mut()
                .find(|record| record.terminal_id == terminal && record.pane_id == pane)
            {
                record.outcome = None;
            }
        }
    }
    fn push_outcome(&mut self, observation: OutcomeObservation) {
        self.outcomes.push(observation);
    }
    fn push_completion(&mut self, observation: CompletionObservation) {
        self.completions.push(observation);
    }
    fn prompt_target(&self, key: &SessionKey) -> Result<PromptTarget, PromptError> {
        self.prompt_route(key).map(|(target, _)| target)
    }
    fn prompt_route(&self, key: &SessionKey) -> Result<(PromptTarget, String), PromptError> {
        let entry = self
            .sources
            .values()
            .find(|source| {
                source.numeric_id == key.source_id && source.generation == key.generation
            })
            .ok_or(PromptError::StaleTarget)?;
        if !entry.connected {
            return Err(PromptError::Offline);
        }
        if !entry.descriptor.capabilities.prompt {
            return Err(PromptError::ReadOnly);
        }
        let record = entry
            .records
            .iter()
            .find(|record| record.terminal_id == key.terminal_id)
            .ok_or(PromptError::StaleTarget)?;
        Ok((
            PromptTarget {
                source: entry.descriptor.id.clone(),
                pane_id: record.pane_id.clone(),
            },
            entry.descriptor.provider.clone(),
        ))
    }
    fn worktree_remove_target(
        &self,
        _key: &SessionKey,
    ) -> Result<WorktreeRemoveTarget, WorktreeRemoveTargetError> {
        Err(WorktreeRemoveTargetError::ReadOnly)
    }
}
#[derive(Default)]
struct Runtime {
    domain: Mutex<Domain>,
    wakes: AtomicUsize,
}
impl RuntimePort for Runtime {
    fn with_domain(&self, operation: &mut dyn FnMut(&mut dyn DomainAccess)) -> Result<(), String> {
        let mut domain = self
            .domain
            .lock()
            .map_err(|_| "source domain lock poisoned".to_owned())?;
        operation(&mut *domain);
        Ok(())
    }
    fn wake_ui(&self) {
        self.wakes.fetch_add(1, Ordering::Relaxed);
    }
}
struct Fixture {
    runtime: Arc<Runtime>,
    integration: Arc<TernIntegration>,
}
impl Fixture {
    fn new() -> Self {
        let runtime = Arc::new(Runtime::default());
        let integration = Arc::new(TernIntegration::new());
        integration.start(runtime.clone()).unwrap();
        let erased: Arc<dyn Integration> = integration.clone();
        runtime
            .domain
            .lock()
            .unwrap()
            .integrations
            .push(Arc::downgrade(&erased));
        Self {
            runtime,
            integration,
        }
    }
    fn exchange(&self, request: &TernExchangeRequest) -> TernExchangeReply {
        let bytes = self
            .integration
            .exchange_handler()
            .handle_frame(&serde_json::to_vec(request).unwrap())
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }
    fn key(&self, window: &str) -> SessionKey {
        let domain = self.runtime.domain.lock().unwrap();
        let source = &domain.sources[&protocol::source_id(window, "0")];
        SessionKey {
            source_id: source.numeric_id,
            generation: source.generation,
            terminal_id: source.records[0].terminal_id.clone(),
        }
    }
    fn age(&self, window: &str) {
        self.runtime
            .with_domain(&mut |_| {
                self.integration
                    .state
                    .lock()
                    .unwrap()
                    .registry
                    .get_mut(window)
                    .unwrap()
                    .last_seen = Instant::now() - FRESHNESS
            })
            .unwrap();
    }
    fn enabled(&self, enabled: bool) {
        self.runtime
            .with_domain(&mut |domain| self.integration.set_enabled(enabled, domain))
            .unwrap();
    }
}
fn request(window: &str) -> TernExchangeRequest {
    TernExchangeRequest {
        version: 2,
        kind: "tern".into(),
        window: window.into(),
        epoch: 1,
        sequence: 1,
        instance_id: None,
        hosts: vec![TernHostInventory {
            host: "0".into(),
            label: "Tern".into(),
            is_local: true,
            observation_generation: 1,
            status: TernHostStatus::Available,
            agents: vec![TernAgent {
                pane: "pane-a".into(),
                title: "fixture agent".into(),
                cwd: "/local/looking/worktree".into(),
                session_id: Some("session".into()),
                session_label: None,
                tab_id: None,
                tab_label: None,
                state: TernAgentState::Idle,
                delivery_error: None,
            }],
        }],
        results: vec![],
    }
}
fn inventory_with_json_bytes(bytes: usize) -> TernExchangeRequest {
    let mut inventory = request("request-budget");
    let template = inventory.hosts[0].agents[0].clone();
    inventory.hosts[0].agents = (0..128)
        .map(|index| {
            let mut agent = template.clone();
            agent.pane = format!("pane-{index}");
            agent.title.clear();
            agent
        })
        .collect();
    let mut remaining = bytes - serde_json::to_vec(&inventory).unwrap().len();
    for agent in &mut inventory.hosts[0].agents {
        let length = remaining.min(4096);
        agent.title = "x".repeat(length);
        remaining -= length;
    }
    assert_eq!(remaining, 0);
    assert_eq!(serde_json::to_vec(&inventory).unwrap().len(), bytes);
    assert_eq!(inventory.normalize().is_ok(), bytes <= MAX_EXCHANGE_BYTES);
    inventory
}

#[test]
fn request_budget_is_json_only_and_invalid_inventory_never_mutates() {
    let fixture = Fixture::new();
    let inventory = inventory_with_json_bytes(MAX_EXCHANGE_BYTES);
    let json = serde_json::to_vec(&inventory).unwrap();
    for terminator in [b"".as_slice(), b"\n".as_slice(), b"\r\n".as_slice()] {
        let mut input = json.clone();
        input.extend_from_slice(terminator);
        assert!(decode_exchange_request(&input).is_ok());
    }
    assert!(fixture.exchange(&inventory).ok);
    let revision = fixture.runtime.domain.lock().unwrap().revision;
    let oversized = inventory_with_json_bytes(MAX_EXCHANGE_BYTES + 1);
    let bytes = serde_json::to_vec(&oversized).unwrap();
    assert!(decode_exchange_request(&bytes).is_err());
    assert_eq!(
        send_exchange(
            std::path::Path::new("/absent.sock"),
            &bytes,
            Duration::from_secs(1)
        )
        .unwrap_err(),
        "Tern exchange request JSON exceeds 256 KiB"
    );
    let mut duplicate = request("invalid");
    let repeated = duplicate.hosts[0].agents[0].clone();
    duplicate.hosts[0].agents.push(repeated);
    assert!(!fixture.exchange(&duplicate).ok);
    let response: Value = serde_json::from_slice(
        &fixture
            .integration
            .exchange_handler()
            .handle_frame(br#"{"kind":"tern","kind":"tern"}"#)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(response["error_code"], "rejected");
    assert_eq!(fixture.runtime.domain.lock().unwrap().revision, revision);
}

#[test]
fn bindings_receipts_epoch_and_sequence_fences_preserve_one_offer() {
    let fixture = Fixture::new();
    let mut poll = request("window");
    let first = fixture.exchange(&poll);
    assert!(first.ok && first.command.is_none());
    let key = fixture.key("window");
    let receipt = fixture
        .integration
        .submit_prompt(key.clone(), "question".into())
        .unwrap();
    assert!(matches!(
        fixture
            .integration
            .submit_prompt(key.clone(), "another".into()),
        Err(PromptError::Busy)
    ));
    poll.sequence = 2;
    assert_eq!(
        fixture.exchange(&poll).error_code,
        Some(TernExchangeErrorCode::BindingRequired)
    );
    poll.instance_id = Some("different-daemon".into());
    assert_eq!(
        fixture.exchange(&poll).error_code,
        Some(TernExchangeErrorCode::InstanceChanged)
    );
    poll.instance_id = Some(first.instance_id);
    let command = fixture.exchange(&poll).command.unwrap();
    assert_eq!(command.text, "question");
    poll.sequence = 3;
    poll.results.push(TernResult {
        operation_id: "wrong-operation".into(),
        pane: "pane-a".into(),
        status: TernResultStatus::Accepted,
        error: None,
    });
    let before = fixture.runtime.domain.lock().unwrap().revision;
    assert_eq!(
        fixture.exchange(&poll).error_code,
        Some(TernExchangeErrorCode::ReceiptRejected)
    );
    assert_eq!(fixture.runtime.domain.lock().unwrap().revision, before);
    assert_eq!(receipt.try_recv(), Err(mpsc::TryRecvError::Empty));
    poll.results[0].operation_id = command.operation_id;
    poll.results[0].pane = "wrong-pane".into();
    assert_eq!(
        fixture.exchange(&poll).error_code,
        Some(TernExchangeErrorCode::ReceiptRejected)
    );
    poll.results[0].pane = "pane-a".into();
    assert!(fixture.exchange(&poll).ok);
    assert_eq!(receipt.try_recv(), Ok(Ok(PromptReceipt::Accepted)));
    poll.sequence = 4;
    assert_eq!(
        fixture.exchange(&poll).error_code,
        Some(TernExchangeErrorCode::ReceiptRejected)
    );
    poll.results.clear();
    poll.epoch = 2;
    poll.sequence = 1;
    assert_eq!(fixture.exchange(&poll).hosts[0].generation, 2);
    assert!(matches!(
        fixture.integration.submit_prompt(key, "stale".into()),
        Err(PromptError::StaleTarget)
    ));
    let domain = fixture.runtime.domain.lock().unwrap();
    assert!(domain.completions.is_empty() && domain.outcomes.is_empty());
}

#[test]
fn retirement_prepare_and_expiry_finalize_truthfully_without_replay() {
    for offered in [false, true] {
        for prepare in [false, true] {
            let fixture = Fixture::new();
            let mut poll = request("retired");
            let first = fixture.exchange(&poll);
            let receipt = fixture
                .integration
                .submit_prompt(fixture.key("retired"), "deliver once".into())
                .unwrap();
            poll.instance_id = Some(first.instance_id);
            poll.sequence = 2;
            if offered {
                assert!(fixture.exchange(&poll).command.is_some());
            }
            if prepare {
                let mut domain = fixture.runtime.domain.lock().unwrap();
                domain.gated = true;
                fixture.integration.retire(&mut *domain);
            } else {
                fixture.enabled(false);
            }
            assert_eq!(
                receipt.try_recv(),
                Ok(Err(if offered {
                    PromptError::UnknownDelivery
                } else {
                    PromptError::Offline
                }))
            );
            assert_eq!(
                fixture.exchange(&poll).error_code,
                Some(if prepare {
                    TernExchangeErrorCode::SourceRetired
                } else {
                    TernExchangeErrorCode::Rejected
                })
            );
            fixture.runtime.domain.lock().unwrap().gated = false;
            fixture.enabled(true);
            assert_eq!(
                fixture.exchange(&poll).error_code,
                Some(TernExchangeErrorCode::SourceRetired)
            );
            poll.instance_id = None;
            poll.epoch = 2;
            poll.sequence = 1;
            assert!(fixture.exchange(&poll).command.is_none());
            poll.instance_id = Some("daemon-a".into());
            poll.sequence = 2;
            assert!(fixture.exchange(&poll).command.is_none());
        }
        let fixture = Fixture::new();
        let mut poll = request("expired");
        fixture.exchange(&poll);
        let key = fixture.key("expired");
        let receipt = fixture
            .integration
            .submit_prompt(key.clone(), "ask".into())
            .unwrap();
        if offered {
            poll.instance_id = Some("daemon-a".into());
            poll.sequence = 2;
            assert!(fixture.exchange(&poll).command.is_some());
        }
        fixture.age("expired");
        assert!(matches!(
            fixture.integration.submit_prompt(key, "stale".into()),
            Err(PromptError::StaleTarget)
        ));
        fixture.integration.tick(Instant::now());
        assert_eq!(
            receipt.try_recv(),
            Ok(Err(if offered {
                PromptError::UnknownDelivery
            } else {
                PromptError::Offline
            }))
        );
        assert!(
            !fixture.runtime.domain.lock().unwrap().sources[&protocol::source_id("expired", "0")]
                .connected
        );
    }
}

#[test]
fn same_transaction_final_gate_and_prompt_only_descriptor() {
    let fixture = Fixture::new();
    let mut poll = request("window");
    poll.hosts[0].agents[0].state = TernAgentState::WaitingInput;
    let exited = TernAgent {
        pane: "exited".into(),
        state: TernAgentState::Exited,
        ..poll.hosts[0].agents[0].clone()
    };
    poll.hosts[0].agents.push(exited);
    assert!(fixture.exchange(&poll).ok);
    let key = fixture.key("window");
    {
        let domain = fixture.runtime.domain.lock().unwrap();
        let source = &domain.sources[&protocol::source_id("window", "0")];
        assert!(source.descriptor.capabilities.prompt);
        assert!(!source.descriptor.capabilities.remove_worktree);
        assert_eq!(source.records[0].status, AgentStatus::Blocked);
        assert_eq!(source.records[1].status, AgentStatus::Unknown);
        assert!(source
            .records
            .iter()
            .all(|record| !record.outcome_authoritative && record.outcome.is_none()));
        assert_eq!(
            domain.worktree_remove_target(&key),
            Err(WorktreeRemoveTargetError::ReadOnly)
        );
    }
    fixture
        .runtime
        .with_domain(&mut |domain| {
            fixture.integration.retire(domain);
        })
        .unwrap();
    fixture.runtime.domain.lock().unwrap().gated = true;
    assert!(matches!(
        fixture
            .integration
            .submit_prompt(key, "cannot admit".into()),
        Err(PromptError::Other(_))
    ));
    assert!(!fixture.exchange(&poll).ok);
    assert!(fixture
        .integration
        .state
        .lock()
        .unwrap()
        .registry
        .is_empty());
}

#[test]
fn shared_capacity_preserves_live_pending_and_other_provider_and_requires_same_generation() {
    for mismatched in [false, true] {
        let fixture = Fixture::new();
        fixture
            .runtime
            .with_domain(&mut |domain| {
                assert!(domain.begin_source(
                    SourceDescriptor {
                        id: "opaque-other".into(),
                        provider: "herdr".into(),
                        label: "Herdr".into(),
                        locality: SourceLocality::Local,
                        capabilities: SourceCapabilities {
                            prompt: true,
                            remove_worktree: true
                        }
                    },
                    1
                ));
            })
            .unwrap();
        for index in 0..63 {
            assert!(fixture.exchange(&request(&format!("window-{index}"))).ok);
        }
        let live_key = fixture.key("window-1");
        let pending = fixture
            .integration
            .submit_prompt(live_key, "keep pending".into())
            .unwrap();
        fixture.age("window-0");
        if mismatched {
            fixture
                .runtime
                .domain
                .lock()
                .unwrap()
                .sources
                .get_mut(&protocol::source_id("window-0", "0"))
                .unwrap()
                .generation = 2;
        }
        let mut invalid = request("invalid");
        let repeated = invalid.hosts[0].agents[0].clone();
        invalid.hosts[0].agents.push(repeated);
        assert!(!fixture.exchange(&invalid).ok);
        assert!(fixture
            .integration
            .state
            .lock()
            .unwrap()
            .registry
            .get("window-0")
            .is_some());
        assert_eq!(
            fixture.exchange(&request("replacement")).hosts[0]
                .error
                .is_none(),
            !mismatched
        );
        assert_eq!(
            fixture.runtime.domain.lock().unwrap().sources.len(),
            MAX_SOURCES
        );
        assert!(fixture
            .runtime
            .domain
            .lock()
            .unwrap()
            .sources
            .contains_key("opaque-other"));
        assert_eq!(pending.try_recv(), Err(mpsc::TryRecvError::Empty));
        // The failed replacement still established a parent binding. With a
        // mismatched child generation, all 64 parent slots are occupied and the
        // old parent cannot safely be reclaimed. That is an envelope rejection,
        // distinct from a child-source budget's partial host rejection.
        let new_parent = fixture.exchange(&request("all-live-full"));
        if mismatched {
            assert!(!new_parent.ok);
            assert!(new_parent.hosts.is_empty());
            assert_eq!(new_parent.error_code, Some(TernExchangeErrorCode::Rejected));
            assert_eq!(
                new_parent.error.as_deref(),
                Some("Tern window registry is full")
            );
            assert!(fixture
                .integration
                .state
                .lock()
                .unwrap()
                .registry
                .get("window-0")
                .is_some());
        } else {
            assert!(new_parent.ok);
            assert_eq!(new_parent.hosts.len(), 1);
            assert_eq!(new_parent.hosts[0].generation, 0);
            assert_eq!(
                new_parent.hosts[0].error_code,
                Some(TernExchangeErrorCode::Rejected)
            );
            assert!(fixture
                .integration
                .state
                .lock()
                .unwrap()
                .registry
                .get("window-0")
                .is_none());
        }
        // Exercise the shared source limit without requesting another parent:
        // new remote host admission fails independently inside the already
        // established replacement binding, preserving every existing source.
        let mut partial = request("replacement");
        partial.instance_id = Some("daemon-a".into());
        partial.sequence = 2;
        partial.hosts.push(remote_host("1"));
        let reply = fixture.exchange(&partial);
        assert!(reply.ok && reply.error.is_none() && reply.command.is_none());
        assert_eq!(reply.hosts.len(), 2);
        assert_eq!(reply.hosts[0].host, "0");
        assert_eq!(reply.hosts[0].error.is_none(), !mismatched);
        assert_eq!(reply.hosts[1].host, "1");
        assert_eq!(reply.hosts[1].generation, 0);
        assert_eq!(
            reply.hosts[1].error_code,
            Some(TernExchangeErrorCode::Rejected)
        );
        let domain = fixture.runtime.domain.lock().unwrap();
        assert_eq!(domain.sources.len(), MAX_SOURCES);
        assert!(domain.sources.contains_key("opaque-other"));
        assert!(domain.sources[&protocol::source_id("window-1", "0")].connected);
        assert_eq!(
            domain.source_generation(&protocol::source_id("window-0", "0")),
            mismatched.then_some(2)
        );
        drop(domain);
        assert_eq!(pending.try_recv(), Err(mpsc::TryRecvError::Empty));
    }
}

#[test]
fn escaped_response_budget_checked_before_queue_and_omitted_receipt_never_reoffers() {
    let fixture = Fixture::new();
    let mut poll = request("window");
    fixture.exchange(&poll);
    let key = fixture.key("window");
    assert!(matches!(
        fixture
            .integration
            .submit_prompt(key.clone(), "\u{1}".repeat(100_000)),
        Err(PromptError::TooLarge)
    ));
    let text = "✓\n".repeat(60_000);
    let receipt = fixture
        .integration
        .submit_prompt(key, text.clone())
        .unwrap();
    poll.instance_id = Some("daemon-a".into());
    poll.sequence = 2;
    assert_eq!(fixture.exchange(&poll).command.unwrap().text, text);
    poll.sequence = 3;
    assert!(fixture.exchange(&poll).command.is_none());
    assert_eq!(receipt.try_recv(), Ok(Err(PromptError::UnknownDelivery)));
    poll.sequence = 4;
    assert!(fixture.exchange(&poll).command.is_none());
}

#[test]
fn poisoned_domain_is_source_error_without_callback_or_publication() {
    let fixture = Fixture::new();
    let runtime = fixture.runtime.clone();
    let _ = std::thread::spawn(move || {
        let _guard = runtime.domain.lock().unwrap();
        panic!("poison fixture");
    })
    .join();
    assert!(fixture
        .integration
        .exchange(request("window"))
        .unwrap_err()
        .contains("poisoned"));
    assert!(matches!(
        fixture.integration.submit_prompt(
            SessionKey {
                source_id: 1,
                generation: 1,
                terminal_id: "pane-a".into()
            },
            "ask".into()
        ),
        Err(PromptError::Other(_))
    ));
    assert!(fixture
        .integration
        .state
        .lock()
        .unwrap()
        .registry
        .is_empty());
}

static NEXT_SOCKET: AtomicUsize = AtomicUsize::new(0);
fn peer_reply(reply: Value) -> Result<TernExchangeReply, String> {
    let path = std::env::temp_dir().join(format!(
        "dpt-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ));
    let listener = UnixListener::bind(&path).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let peer = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(&stream).read_line(&mut line).unwrap();
        let request: TernExchangeRequest = serde_json::from_str(&line).unwrap();
        assert_eq!(request.window, "wire");
        let mut bytes = serde_json::to_vec(&reply).unwrap();
        bytes.push(b'\n');
        let _ = stream.write_all(&bytes);
    });
    let mut poll = request("wire");
    poll.instance_id = Some("daemon".into());
    let result = send_exchange(
        &path,
        &serde_json::to_vec(&poll).unwrap(),
        Duration::from_secs(2),
    );
    peer.join().unwrap();
    std::fs::remove_file(path).unwrap();
    result
}
#[test]
fn helper_transport_rejects_invalid_error_contract_and_honors_response_lf_limit() {
    let failed = json!({"ok":false,"instance_id":"daemon","hosts":[],"command":null,"error":"rejected","error_code":"source_retired"});
    assert_eq!(
        peer_reply(failed.clone()).unwrap().error_code,
        Some(TernExchangeErrorCode::SourceRetired)
    );
    let mut missing = failed.clone();
    missing.as_object_mut().unwrap().remove("error_code");
    assert!(peer_reply(missing).is_err());
    for (field, value) in [
        ("error_code", Value::Null),
        ("error_code", json!("unknown_code")),
        ("generation", json!(1)),
        ("error", json!("")),
        ("error", json!("e".repeat(4097))),
        ("command", json!({"operation_id":"o","pane":"p","text":"x"})),
    ] {
        let mut candidate = failed.clone();
        candidate[field] = value;
        assert!(peer_reply(candidate).is_err());
    }
    let success = json!({"ok":true,"instance_id":"daemon","hosts":[{"host":"0","observation_generation":1,"generation":1,"error":null}],"command":null,"error":null});
    for value in [Value::Null, json!("rejected")] {
        let mut candidate = success.clone();
        candidate["error_code"] = value;
        assert!(peer_reply(candidate).is_err());
    }
    let mut largest = success;
    largest["command"] = json!({"operation_id":"operation","pane":"pane-a","text":""});
    let overhead = serde_json::to_vec(&largest).unwrap().len() + 1;
    let text = "x".repeat(MAX_RESPONSE_BYTES - overhead);
    largest["command"]["text"] = json!(text);
    assert_eq!(
        peer_reply(largest.clone()).unwrap().command.unwrap().text,
        text
    );
    largest["command"]["text"] = json!(format!("{text}x"));
    assert!(peer_reply(largest).is_err());
}

#[test]
fn other_provider_admission_expires_pending_before_reclaiming_one_shared_slot() {
    let fixture = Fixture::new();
    for index in 0..MAX_SOURCES {
        assert!(fixture.exchange(&request(&format!("window-{index}"))).ok);
    }
    let unoffered = fixture
        .integration
        .submit_prompt(fixture.key("window-0"), "not offered".into())
        .unwrap();
    let offered = fixture
        .integration
        .submit_prompt(fixture.key("window-1"), "offered once".into())
        .unwrap();
    let mut poll = request("window-1");
    poll.instance_id = Some("daemon-a".into());
    poll.sequence = 2;
    assert!(fixture.exchange(&poll).command.is_some());
    fixture.age("window-0");
    fixture.age("window-1");
    fixture
        .runtime
        .with_domain(&mut |domain| {
            assert!(domain.begin_source(
                SourceDescriptor {
                    id: "new-other-provider".into(),
                    provider: "herdr".into(),
                    label: "Herdr".into(),
                    locality: SourceLocality::Local,
                    capabilities: SourceCapabilities {
                        prompt: true,
                        remove_worktree: true
                    },
                },
                1
            ));
        })
        .unwrap();
    assert_eq!(unoffered.try_recv(), Ok(Err(PromptError::Offline)));
    assert_eq!(offered.try_recv(), Ok(Err(PromptError::UnknownDelivery)));
    assert_eq!(
        fixture.runtime.domain.lock().unwrap().sources.len(),
        MAX_SOURCES
    );
    let state = fixture.integration.state.lock().unwrap();
    assert!(state.registry.get("window-0").unwrap().hosts.is_empty());
    assert!(state.registry.get("window-1").unwrap().offline);
    assert!(state.registry.get("window-2").is_some());
}

#[test]
fn exhausted_generation_rejects_only_its_host_without_refreshing_snapshot() {
    let fixture = Fixture::new();
    for index in 0..MAX_SOURCES {
        assert!(fixture.exchange(&request(&format!("window-{index}"))).ok);
    }
    fixture.age("window-0");
    fixture
        .runtime
        .with_domain(&mut |_| {
            fixture
                .integration
                .state
                .lock()
                .unwrap()
                .registry
                .get_mut("window-1")
                .unwrap()
                .hosts
                .get_mut("0")
                .unwrap()
                .generation = protocol::MAX_SAFE_INTEGER;
        })
        .unwrap();
    let before = fixture.runtime.domain.lock().unwrap().revision;
    let mut poll = request("window-1");
    poll.instance_id = Some("daemon-a".into());
    poll.sequence = 2;
    poll.hosts[0].observation_generation = 2;
    fixture
        .runtime
        .domain
        .lock()
        .unwrap()
        .sources
        .get_mut(&protocol::source_id("window-1", "0"))
        .unwrap()
        .generation = protocol::MAX_SAFE_INTEGER;
    assert_eq!(
        fixture.exchange(&poll).hosts[0].error_code,
        Some(TernExchangeErrorCode::Rejected)
    );
    assert_eq!(fixture.runtime.domain.lock().unwrap().revision, before);
    assert!(
        fixture
            .integration
            .state
            .lock()
            .unwrap()
            .registry
            .get("window-0")
            .unwrap()
            .offline
    );
}

#[test]
fn failed_receipt_and_disappearing_pane_do_not_create_completion() {
    let fixture = Fixture::new();
    let mut poll = request("window");
    fixture.exchange(&poll);
    let receipt = fixture
        .integration
        .submit_prompt(fixture.key("window"), "ask".into())
        .unwrap();
    poll.instance_id = Some("daemon-a".into());
    poll.sequence = 2;
    let command = fixture.exchange(&poll).command.unwrap();
    poll.sequence = 3;
    poll.results.push(TernResult {
        operation_id: command.operation_id,
        pane: command.pane,
        status: TernResultStatus::Failed,
        error: Some("ask rejected".into()),
    });
    assert!(fixture.exchange(&poll).command.is_none());
    assert_eq!(
        receipt.try_recv(),
        Ok(Err(PromptError::Other("ask rejected".into())))
    );
    let queued = fixture
        .integration
        .submit_prompt(fixture.key("window"), "stale pane".into())
        .unwrap();
    poll.sequence = 4;
    poll.results.clear();
    poll.hosts[0].agents.clear();
    assert!(fixture.exchange(&poll).command.is_none());
    assert_eq!(queued.try_recv(), Ok(Err(PromptError::StaleTarget)));
    let domain = fixture.runtime.domain.lock().unwrap();
    assert!(domain.completions.is_empty() && domain.outcomes.is_empty());
}

#[test]
fn shutdown_clears_queue_and_retains_unknown_delivery_for_offered_work() {
    for offered in [false, true] {
        let fixture = Fixture::new();
        let mut poll = request("shutdown");
        fixture.exchange(&poll);
        let receipt = fixture
            .integration
            .submit_prompt(fixture.key("shutdown"), "ask".into())
            .unwrap();
        if offered {
            poll.instance_id = Some("daemon-a".into());
            poll.sequence = 2;
            assert!(fixture.exchange(&poll).command.is_some());
        }
        {
            let mut domain = fixture.runtime.domain.lock().unwrap();
            domain.gated = true;
            fixture.integration.retire(&mut *domain);
        }
        fixture.integration.shutdown();
        assert_eq!(
            receipt.try_recv(),
            Ok(Err(if offered {
                PromptError::UnknownDelivery
            } else {
                PromptError::Offline
            }))
        );
        assert!(fixture
            .integration
            .state
            .lock()
            .unwrap()
            .registry
            .is_empty());
        assert!(!fixture.exchange(&poll).ok);
    }
}

fn remote_host(id: &str) -> TernHostInventory {
    let mut host = request("template").hosts.remove(0);
    host.host = id.into();
    host.label = format!("Remote {id}");
    host.is_local = false;
    host
}
fn host_key(fixture: &Fixture, window: &str, host: &str) -> SessionKey {
    let domain = fixture.runtime.domain.lock().unwrap();
    let source = &domain.sources[&protocol::source_id(window, host)];
    SessionKey {
        source_id: source.numeric_id,
        generation: source.generation,
        terminal_id: source.records[0].terminal_id.clone(),
    }
}

#[test]
fn grouped_hosts_disjoin_identical_panes_and_remote_paths_never_grant_authority() {
    let fixture = Fixture::new();
    let mut poll = request("grouped");
    poll.hosts.push(remote_host("1"));
    poll.hosts.push(remote_host("2"));
    let first = fixture.exchange(&poll);
    assert_eq!(first.hosts.len(), 3);
    let local = host_key(&fixture, "grouped", "0");
    let remote = host_key(&fixture, "grouped", "1");
    assert_ne!(local.source_id, remote.source_id);
    assert_eq!(
        fixture
            .integration
            .submit_prompt(remote.clone(), "never remote".into())
            .unwrap_err(),
        PromptError::ReadOnly
    );
    {
        let domain = fixture.runtime.domain.lock().unwrap();
        let source = &domain.sources[&protocol::source_id("grouped", "1")];
        assert_eq!(source.descriptor.locality, SourceLocality::Remote);
        assert_eq!(
            source.descriptor.capabilities,
            SourceCapabilities {
                prompt: false,
                remove_worktree: false
            }
        );
        assert_eq!(
            domain.worktree_remove_target(&remote),
            Err(WorktreeRemoveTargetError::ReadOnly)
        );
    }
    poll.instance_id = Some(first.instance_id);
    poll.sequence = 2;
    poll.hosts[1].label = "Renamed remote".into();
    assert!(fixture
        .exchange(&poll)
        .hosts
        .iter()
        .all(|host| host.error.is_none()));
    assert_eq!(host_key(&fixture, "grouped", "1"), remote);
    assert_eq!(
        fixture.runtime.domain.lock().unwrap().sources[&protocol::source_id("grouped", "1")]
            .descriptor
            .label,
        "Renamed remote"
    );
}

#[test]
fn grouped_host_losses_require_new_observation_but_native_expiry_does_not() {
    for loss in [TernHostStatus::Unavailable, TernHostStatus::Disconnected] {
        let fixture = Fixture::new();
        let mut poll = request("loss");
        poll.hosts.push(remote_host("1"));
        let first = fixture.exchange(&poll);
        let local = fixture.key("loss");
        let old = host_key(&fixture, "loss", "1");
        poll.instance_id = Some(first.instance_id);
        poll.sequence = 2;
        let agents = poll.hosts[1].agents.clone();
        poll.hosts[1].status = loss;
        poll.hosts[1].agents.clear();
        assert!(fixture.exchange(&poll).hosts[1].error.is_none());
        assert!(
            !fixture.runtime.domain.lock().unwrap().sources[&protocol::source_id("loss", "1")]
                .connected
        );
        poll.sequence = 3;
        poll.hosts[1].status = TernHostStatus::Available;
        poll.hosts[1].agents = agents;
        assert_eq!(
            fixture.exchange(&poll).hosts[1].error_code,
            Some(TernExchangeErrorCode::Rejected)
        );
        poll.sequence = 4;
        poll.hosts[1].observation_generation = 2;
        assert!(fixture.exchange(&poll).hosts[1].error.is_none());
        assert_ne!(host_key(&fixture, "loss", "1"), old);
        assert_eq!(fixture.key("loss"), local);
        let renewed = host_key(&fixture, "loss", "1");
        fixture
            .runtime
            .with_domain(&mut |_| {
                fixture
                    .integration
                    .state
                    .lock()
                    .unwrap()
                    .registry
                    .get_mut("loss")
                    .unwrap()
                    .hosts
                    .get_mut("1")
                    .unwrap()
                    .last_seen = Instant::now() - FRESHNESS;
            })
            .unwrap();
        poll.sequence = 5;
        poll.hosts[1].observation_generation = 1;
        assert_eq!(
            fixture.exchange(&poll).hosts[1].error_code,
            Some(TernExchangeErrorCode::Rejected)
        );
        assert!(
            !fixture.runtime.domain.lock().unwrap().sources[&protocol::source_id("loss", "1")]
                .connected
        );
        assert!(
            fixture.runtime.domain.lock().unwrap().sources[&protocol::source_id("loss", "0")]
                .connected
        );
        poll.sequence = 6;
        poll.hosts[1].observation_generation = 2;
        assert!(fixture.exchange(&poll).hosts[1].error.is_none());
        assert_ne!(host_key(&fixture, "loss", "1"), renewed);
    }
}

#[test]
fn omission_and_locality_high_watermarks_are_independent_of_other_hosts() {
    let fixture = Fixture::new();
    let mut poll = request("omitted");
    poll.hosts.push(remote_host("1"));
    let first = fixture.exchange(&poll);
    let remote = poll.hosts.remove(1);
    poll.instance_id = Some(first.instance_id);
    poll.sequence = 2;
    assert!(fixture.exchange(&poll).ok);
    poll.sequence = 3;
    poll.hosts.push(remote);
    assert_eq!(
        fixture.exchange(&poll).hosts[1].error_code,
        Some(TernExchangeErrorCode::Rejected)
    );
    poll.sequence = 4;
    poll.hosts[1].observation_generation = 2;
    assert!(fixture.exchange(&poll).hosts[1].error.is_none());
    poll.sequence = 5;
    poll.hosts[0].is_local = false;
    poll.hosts[1].is_local = true;
    let rejected = fixture.exchange(&poll);
    assert!(rejected.hosts.iter().all(|host| host.error.is_some()));
    poll.sequence = 6;
    poll.hosts[0].observation_generation = 2;
    poll.hosts[1].observation_generation = 3;
    assert!(fixture
        .exchange(&poll)
        .hosts
        .iter()
        .all(|host| host.error.is_none()));
    let domain = fixture.runtime.domain.lock().unwrap();
    assert_eq!(
        domain.sources[&protocol::source_id("omitted", "0")]
            .descriptor
            .locality,
        SourceLocality::Remote
    );
    assert_eq!(
        domain.sources[&protocol::source_id("omitted", "1")]
            .descriptor
            .locality,
        SourceLocality::Local
    );
}

#[test]
fn local_admission_priority_and_partial_capacity_failure_preserve_receipt() {
    let fixture = Fixture::new();
    fixture
        .runtime
        .with_domain(&mut |domain| {
            for index in 0..63 {
                assert!(domain.begin_source(
                    SourceDescriptor {
                        id: format!("other-{index}"),
                        provider: "herdr".into(),
                        label: "Other".into(),
                        locality: SourceLocality::Local,
                        capabilities: SourceCapabilities {
                            prompt: true,
                            remove_worktree: true
                        },
                    },
                    1
                ));
            }
        })
        .unwrap();
    let mut poll = request("priority");
    poll.hosts.insert(0, remote_host("1"));
    let first = fixture.exchange(&poll);
    assert_eq!(first.hosts[0].host, "1");
    assert!(first.hosts[0].error.is_some());
    assert_eq!(first.hosts[1].host, "0");
    assert!(first.hosts[1].error.is_none());
    let receipt = fixture
        .integration
        .submit_prompt(fixture.key("priority"), "local survives".into())
        .unwrap();
    poll.instance_id = Some(first.instance_id);
    poll.sequence = 2;
    let offered = fixture.exchange(&poll).command.unwrap();
    poll.sequence = 3;
    poll.results.push(TernResult {
        operation_id: offered.operation_id,
        pane: offered.pane,
        status: TernResultStatus::Accepted,
        error: None,
    });
    let reply = fixture.exchange(&poll);
    assert!(reply.hosts[0].error.is_some());
    assert!(reply.hosts[1].error.is_none());
    assert_eq!(receipt.try_recv(), Ok(Ok(PromptReceipt::Accepted)));
}

#[test]
fn local_loss_cancels_queued_and_marks_offered_unknown_without_remote_loss() {
    for offered in [false, true] {
        let fixture = Fixture::new();
        let mut poll = request("local-loss");
        poll.hosts.push(remote_host("1"));
        let first = fixture.exchange(&poll);
        let receipt = fixture
            .integration
            .submit_prompt(fixture.key("local-loss"), "one ask".into())
            .unwrap();
        poll.instance_id = Some(first.instance_id);
        poll.sequence = 2;
        if offered {
            assert!(fixture.exchange(&poll).command.is_some());
            poll.sequence = 3;
        }
        poll.hosts[0].status = TernHostStatus::Disconnected;
        poll.hosts[0].agents.clear();
        assert!(fixture.exchange(&poll).command.is_none());
        assert_eq!(
            receipt.try_recv(),
            Ok(Err(if offered {
                PromptError::UnknownDelivery
            } else {
                PromptError::Offline
            }))
        );
        assert!(
            fixture.runtime.domain.lock().unwrap().sources[&protocol::source_id("local-loss", "1")]
                .connected
        );
    }
}

#[test]
fn version_one_and_top_level_generation_are_not_compatibility_fallbacks() {
    let fixture = Fixture::new();
    let mut old = serde_json::to_value(request("old")).unwrap();
    old["version"] = json!(1);
    assert!(!fixture.exchange(&serde_json::from_value(old).unwrap()).ok);
    let legacy =
        json!({"ok":true,"instance_id":"daemon","generation":1,"command":null,"error":null});
    assert!(peer_reply(legacy).is_err());
    let mut malformed = request("invalid-hosts");
    malformed.hosts.push(remote_host("01"));
    assert!(!fixture.exchange(&malformed).ok);
    assert!(fixture.runtime.domain.lock().unwrap().sources.is_empty());
}

#[test]
fn evidence_requires_actual_confirmed_fresh_reconnect_and_observation_survives_gate() {
    let fixture = Fixture::new();
    let extensions = fixture.integration.extensions();
    let evidence = extensions
        .control
        .iter()
        .find(|extension| extension.kind() == "tern-migration-evidence")
        .unwrap();
    let query = br#"{"version":1,"kind":"tern-migration-evidence","window_id":"reconnect"}"#;
    assert!(evidence.handle_frame(query).is_err());
    let mut poll = request("reconnect");
    fixture.exchange(&poll);
    assert!(
        evidence.handle_frame(query).is_err(),
        "unbound first exchange is not reconnection proof"
    );
    fixture.runtime.domain.lock().unwrap().gated = true;
    poll.instance_id = Some("daemon-a".into());
    poll.sequence = 2;
    assert!(
        fixture.exchange(&poll).ok,
        "observation remains read-only under migration mutation gate"
    );
    assert!(matches!(
        fixture
            .integration
            .submit_prompt(fixture.key("reconnect"), "blocked".into()),
        Err(PromptError::Other(_))
    ));
    let reply: Value = serde_json::from_slice(&evidence.handle_frame(query).unwrap()).unwrap();
    assert_eq!(reply["fresh"], true);
    assert_eq!(reply["binding_epoch"], 1);
    assert_eq!(reply["sequence"], 2);
    assert_eq!(reply["observation_generation"], 1);
    assert_eq!(reply["native_generation"], 1);
    assert_eq!(reply["instance_id"], "daemon-a");
    assert_eq!(reply["local_host"], "0");
    fixture.age("reconnect");
    assert!(evidence.handle_frame(query).is_err());
}

#[test]
fn hostile_empty_label_uses_adapter_owned_numeric_host_fallback() {
    let fixture = Fixture::new();
    let mut poll = request("label");
    poll.hosts[0].label = "\u{202E} \u{200B}".into();
    assert!(fixture.exchange(&poll).ok);
    assert_eq!(
        fixture.runtime.domain.lock().unwrap().sources[&protocol::source_id("label", "0")]
            .descriptor
            .label,
        "0"
    );
}
