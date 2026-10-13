use crate::{TernIntegration, FRESHNESS};
use desktop_pet_contracts::{ControlExtension, SourceLocality};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Instant;

const LIMIT: usize = 16 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request { version: u64, kind: String, window_id: String }

#[derive(Serialize)]
#[serde(deny_unknown_fields)]
struct Reply {
    version: u64,
    kind: &'static str,
    instance_id: String,
    window_id: String,
    binding_epoch: u64,
    sequence: u64,
    local_host: String,
    observation_generation: u64,
    native_generation: u64,
    fresh: bool,
}

pub(crate) struct EvidenceHandler { pub(crate) integration: Arc<TernIntegration> }
impl ControlExtension for EvidenceHandler {
    fn kind(&self) -> &'static str { "tern-migration-evidence" }
    fn max_request_bytes(&self) -> usize { LIMIT }
    fn max_response_bytes(&self) -> usize { LIMIT }
    fn handle_frame(&self, frame: &[u8]) -> Result<Vec<u8>, String> {
        if frame.len() > LIMIT { return Err("Tern migration evidence request exceeds limit".into()); }
        crate::transport::reject_duplicate_json_keys(frame)?;
        let request: Request = serde_json::from_slice(frame).map_err(|error| error.to_string())?;
        if request.version != 1 || request.kind != self.kind() || request.window_id.is_empty()
            || request.window_id.len() > 4096 || request.window_id.contains('\0') {
            return Err("invalid Tern migration evidence request".into());
        }
        let runtime = self.integration.runtime.get().ok_or("Tern runtime is not started")?;
        let mut evidence = Err("no fresh confirmed Tern local binding".to_owned());
        runtime.with_domain(&mut |domain| {
            evidence = (|| {
                let state = self.integration.state.lock().map_err(|_| "Tern source registry lock poisoned".to_owned())?;
                if !state.enabled { return Err("Tern observation is unavailable".into()); }
                let window = state.registry.get(&request.window_id).ok_or("Tern window is not registered")?;
                let now = Instant::now();
                if !window.bound || window.offline || now.saturating_duration_since(window.last_seen) >= FRESHNESS
                    || window.confirmed_sequence != Some(window.sequence) {
                    return Err("Tern binding has not confirmed the current daemon or is stale".into());
                }
                let mut locals = window.hosts.iter().filter(|(_, host)| host.is_local && !host.offline
                    && now.saturating_duration_since(host.last_seen) < FRESHNESS);
                let (id, host) = locals.next().ok_or("Tern window has no fresh local host")?;
                if locals.next().is_some() { return Err("Tern local host binding is ambiguous".into()); }
                let descriptor = domain.source_descriptor(&host.source).ok_or("Tern local source is retired")?;
                if domain.instance_id().is_empty() || domain.source_generation(&host.source) != Some(host.generation)
                    || descriptor.provider != crate::PROVIDER_ID || descriptor.locality != SourceLocality::Local
                    || !descriptor.capabilities.prompt {
                    return Err("Tern local source binding is stale or read-only".into());
                }
                Ok(Reply { version: 1, kind: self.kind(), instance_id: domain.instance_id().into(), window_id: request.window_id.clone(),
                    binding_epoch: window.epoch, sequence: window.sequence, local_host: id.clone(),
                    observation_generation: host.observation_generation, native_generation: host.generation, fresh: true })
            })();
        })?;
        let mut bytes = serde_json::to_vec(&evidence?).map_err(|error| error.to_string())?;
        bytes.push(b'\n');
        if bytes.len() > LIMIT { return Err("Tern migration evidence response exceeds limit".into()); }
        Ok(bytes)
    }
}
