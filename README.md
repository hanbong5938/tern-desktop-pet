# Tern Desktop Pet

**English** · [한국어](README.ko.md)

## Desktop Pet consumer — plugin 0.2.0

This window plugin connects Tern agent observations and semantic asks to the separately installed, host-neutral [Desktop Pet](https://github.com/hanbong5938/desktop-pet) app. Native adapter code lives in `native-adapter`; the app/UI/artwork/updater live in the core repository. The plugin **never downloads, installs, builds, auto-starts, or stops the native app**. Updating/removing the plugin does not update/remove the shared app or either native profile directory.

[App homepage](https://hanbong5938.github.io/desktop-pet/en/) · [Core installation / profiles](https://github.com/hanbong5938/desktop-pet/blob/main/docs/development.md) · [Current usage](https://github.com/hanbong5938/desktop-pet/blob/main/docs/usage.md) · [Core Wiki](https://github.com/hanbong5938/desktop-pet/wiki) · [Legacy migration](https://github.com/hanbong5938/desktop-pet/blob/main/docs/migrations/desktop-pet.md). These are core-owned destination links, not hosted-publication or real reconnect evidence.

**Publication/verification status:** these are consumer source instructions, not evidence that plugin 0.2.0, neutral 0.4.0, or the neutral Brew formula has been published or that a real Tern window has reconnected after migration. The current production-source harness passed **132/132 in an actual Tern 0.8.3 window VM**, with controlled SDK boundaries. That is not actual remote SDK agent, matching neutral installation, or model-delivery proof. The 0.1.0/Herdr-native observations below remain historical.

### Install and start native separately

Use an actually available, verified release or build from the core repository. After actual publication, install the app separately with `brew install hanbong5938/tap/desktop-pet`; do not use the old formula as an alias for the new product. Start native yourself, then **Configure desktop pet connection → Connect to desktop pet** with the actual executable and both profile paths. For local core development:

```sh
CORE=/absolute/path/to/desktop-pet
# In that core checkout, follow its build prerequisites and source installer:
(cd "$CORE" && bash scripts/install.sh --source)
PET_BIN="$CORE/dist/DesktopPet.app/Contents/MacOS/desktop-pet"
"$PET_BIN" update-capabilities
# Require integration_api: 1; neutral app/helper report protocol: 4, observation_mode: 2.
"$PET_BIN" profile show --json
```

`profile show --json` is read-only: it returns `{ "version":1, "config_dir":"/absolute/...", "state_dir":"/absolute/..." }`, without creating directories or starting a daemon. Copy **both** paths from that result or select both existing profile paths deliberately. Start the app yourself with the same explicit paths; use `--host tern` if you want Tern-only observation, or the native Auto selection for registered integrations:

```sh
PET_CONFIG=/absolute/path/from/profile-show
PET_STATE=/absolute/path/from/profile-show
DESKTOP_PET_CONFIG_DIR="$PET_CONFIG" DESKTOP_PET_STATE_DIR="$PET_STATE" \
  "$PET_BIN" --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" --host tern start
"$PET_BIN" --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" status

# Local plugin development; this does not build/install native:
tern plugin link /absolute/path/to/tern-desktop-pet
tern plugin reload
tern plugin list
```

After publication, plugin installation is separately `tern plugin install https://github.com/hanbong5938/tern-desktop-pet`. Tern requires your authorized signed-in beta access and an actual window; a headless catalog is not runtime/reconnection evidence.

### Connect, Configure, and migration

**Connect to desktop pet** validates a saved absolute executable, or discovers the neutral executable in this exact order: explicit absolute executable → validated private OS-account-home `.local/share/desktop-pet/installation.json` → `PATH` `desktop-pet` → actual `brew --prefix desktop-pet` → OS-account-home `Applications/DesktopPet.app`. Invalid explicit paths or locators fail closed instead of selecting another installation. The bootstrap verifies the neutral bundle identity and app/helper signatures before executing the paired helper's read-only `discover --json`; the helper validates actual origin and capabilities. Shell wrappers are never executed to discover an app. Compatibility is **`integration_api:1`**, not equality between plugin and app versions.

Discovery, native capabilities, and `profile show --json` run as bounded [documented awaitable subprocesses](https://docs.stencil.so/tern/reference/api-shared.md#ternprocessrun). The polling loop uses only the resulting validated absolute triple; it does not rediscover every 1.2 seconds or synchronously wait in callbacks. Fresh defaults come from the verified native profile, **never** constructed Herdr paths. A missing app, bad JSON, timeout, incompatible API, permission failure, or bad signature shows installation/configuration advice and saves nothing. If another window changes the saved route, old work is retired; explicitly Connect validates the new route before exchange resumes.

**Configure desktop pet connection** prompts for the absolute executable, absolute config directory, then absolute state directory. It validates the complete candidate against the installed app/profile before the single atomic KV save. The canonical object remains `{ version = 1, executable = "...", config_dir = "...", state_dir = "..." }`; Connect does not rewrite it. Cancel, validation failure, save failure, and obsolete callbacks preserve the previous object. A complete old three-key tuple may be read without silent adoption; a successful explicit Configure save commits the canonical object before best-effort cleanup. Incomplete old tuples require explicit repair, and malformed canonical data never revives old keys.

If your saved executable ends in `herdr-desktop-pet`, Connect asks you to migrate through Configure. Configure proposes the discovered neutral executable while keeping **both existing profile paths**; nothing changes until you successfully save. Custom executables are not replaced by discovery. Configure changes plugin routing only: no profile moves/merges/deletions, no native install/start, and no native profile adoption. To change the native default profile separately, follow the core repository's [explicit profile-adoption instructions](https://github.com/hanbong5938/desktop-pet/blob/main/docs/development.md#profiles-and-installation-discovery).

Before using the plugin, check native `status` for the actual running image and the selected two profile paths. If an older/different daemon owns that profile, stop it yourself using its own executable and paths before starting the intended app; the plugin never silently replaces it. Both `DESKTOP_PET_CONFIG_DIR` / `DESKTOP_PET_STATE_DIR` and explicit native arguments select the same pair.

Source/incarnation/generation, shared-KV, phase, and pane/host fences remain in effect. A connection cutover retires old work before active routing changes. Offered or uncertain asks remain **UnknownDelivery**, never replayed on a new binding. A semantic `agents:ask` success means accepted/maybe queued, not model completion. The current source uses exchange **version 2**, with independent grouped host snapshots and host observation/native generations, while the saved connection object stays **version 1**. Remote hosts are observed read-only; semantic `agents:get`/`agents:ask` remain local-only. Independent 256 KiB request/512 KiB reply bounds remain.

### Current source: all connected Tern hosts

When Tern observation is enabled, the plugin automatically observes the window's **local host and all connected remote hosts**, using Tern's `hosts`, `panes`, `tabs`, `sessions`, and `agents` inventories. There is no new host-selection UI. Herdr's local/remote switches and machine selection do **not** filter Tern hosts. The SDK inventory must still identify exactly one local host; this is a reply-safety requirement, not a local-only observation restriction.

Exchange **v2 only** sends a `hosts` array of grouped snapshots, each with host identity, host name/label, `is_local`, status (`available`, `disconnected`, or `unavailable`), `observation_generation`, and its own agents array. Native responses return each host's observation generation and independent native `generation`; there is no exchange-v1 fallback. Session keys include host identity/generation, so unrelated hosts cannot merge merely because pane IDs match. A host rename updates its label without changing its session key. The native source shows host names and **Local / Remote** labels with English, Korean, Japanese, and Chinese translations; these UI changes have not been visually verified.

Host loss, recovery, and freshness are independent. An observed disconnected/unavailable or omitted host becomes **Offline** without taking other hosts offline. The plugin advances that host's observation generation on observed recovery or identity/locality/address change; this is an observation lifetime, **not** an SDK transport-generation guarantee for a reconnect that occurs entirely between snapshots. Native expiry at a monotonic freshness age of at least five seconds retires the affected native lifetime; a later observation can receive a new native generation even if the plugin's observation generation is unchanged. Reloaded/closed windows have separate parent/source identities and do not silently merge.

**Matching native source: 5s freshness + 30s Offline retention.** The current native implementation retains Offline Tern rows for a monotonic 30-second grace, then its existing 100 ms maintenance removes the source, rows, aggregates and registry child without a new registration. Natural expiry starts grace at `last_seen + 5s`; explicit loss (disconnected/unavailable, complete-inventory omission or observation-epoch cutover) starts at its first valid observation. Repeated loss and other-host heartbeats do not reset it; coherent recovery before pruning clears it. Live Tern, healthy available empty hosts and Herdr are never TTL-pruned. Pruning a remote child preserves its live parent's binding/local state; a dead empty parent eventually retires, and old bound requests then receive `SourceRetired`. Generation/revision fences and non-reused IDs preserve stale-key rejection; asks settle at first loss without replay. Existing 64-source pressure can reclaim earlier, and high-water metadata remains: this is not a historical-memory bound or an exact wall-clock deadline. This source-only native change alters **no plugin RPC, timer or identity**, and does not claim the released neutral bundle includes it or relax native installation policy.

**Adapter extraction parity:** `native-adapter` owns these first-loss clocks and retention in `TernIntegration::tick`; the shared domain rechecks the exact offline generation through `remove_offline_source`. Exchanges only age freshness and never prune retention. Successful helper replies must match the bound daemon instance, and receipts cannot establish a new parent epoch. Raw request admission checks the received JSON before decoding, without recounting omitted optional fields as normalized `null`s. The reconciliation adds native-adapter regressions; they have not been run as part of this source reconciliation. The original-native evidence below is not verification of the revised adapter.

**Retention verification scope:** main native **760 passed / 1 ignored**, actual AppKit composer/native IME callbacks and rendered-image checks, coordinator **73**, Bun **59**, and actual Tern VM controlled-boundary Luau **132/132** passed. Populated injected v2 IPC cleared **1 live / 63 Offline → 1 live / 0 Offline** without new registration. Separately, an actual SDK-owned in-process loopback bridge with empty host inventories showed **2 connected / 0 Offline → stalled 1 connected / 1 Offline → pruned 1 connected / 0 Offline → recovered 2 connected / 0 Offline**, keeping the local generation. This is not an installed production-plugin connection, external remote-agent inclusion, network-outage or semantic ask/model-delivery proof. The API 1/protocol 4 neutral-install requirement versus the native checkout's protocol 3/no installation API remains blocked. User-approved permission-free AppKit/source-app IPC/selection-cursor checks do not claim actual card-click automation or physical IME certification; earlier 0.1.0/v0.3.6 evidence is unchanged.


Collection retains the zero-delay awaitable stages: `tabs`, `sessions`, and `agents` are read separately, then `hosts` and `panes` together using a fresh context. A scoped inventory failure clears only that host's agents and marks it unavailable; it does not replace invalid data with cached agents or discard valid siblings. Invalid whole-inventory identity/shape or the host-count limit fails the entire collection. Native host admission errors, including capacity failures, are returned per host, so valid sibling hosts and local receipts can still progress. Per-host response error text is bounded to **512 bytes**.

Limits are **64 hosts per window snapshot**, **128 agents per host** (not per whole window), a native **64-parent** limit, and a **64-source budget shared by Herdr and Tern host sources**. These are separate limits, not a promise of 64 hosts in addition to existing sources. Capacity recovery reclaims only expired/offline Tern sources after finalizing pending work, never live Tern or Herdr sources; source IDs are not reused. Serialized requests are limited to **256 KiB of JSON** (optional transport LF/CRLF excluded); replies are limited to **512 KiB of complete stdout including the trailing LF**. Over-limit escaped commands are rejected before an offer, not sent with uncertain delivery.

**Replies remain local-only.** The reply-by-pane map contains only available local agents. Remote cards are read-only: the native source refuses a remote prompt with `session_read_only` and offers no remote command; the plugin never calls remote `agents:get` or `agents:ask`, and never injects terminal/PTy input. Local sends revalidate fresh host membership, pane/session identity, profile, source incarnation, observation/native generations, and phase before semantic `agents:ask`. A receipt starts an immediate fresh full-inventory exchange; it never replays an uncertain ask. `prompt_accepted` still means accepted/maybe queued, not model completion.

### Current production-code Luau regression harness

[`tests/transition-regressions.luau`](tests/transition-regressions.luau) is a **small loader**, not an eagerly compiled monolithic suite. Keep it beside the ordinary modules `transition-fixture.luau`, `transition-cases-core.luau`, `transition-cases-installation.luau`, and `transition-cases-hosts.luau`. Module reading/compilation/registration, fixture work, and individual production callbacks are scheduled in separate real zero-delay continuations to respect the actual VM callback budget. Production `window.luau` runs unchanged inside `function(tern)` with the real JSON codec; splitting harness work does not add yields inside production callbacks.

Use a signed-in actual Tern window's supported Luau execution facility ([Carly's Lua tool](https://docs.stencil.so/tern/reference/api-window.html#carlys-lua-tool)). Substitute an absolute checkout path and a writable result path whose parent directory already exists. Run these as **separate invocations** in the same VM, retaining the globals; do not reload the suite to poll.

Invocation 1 — load only:

```lua
desktop_pet_root = "/absolute/path/to/tern-desktop-pet"
desktop_pet_result = "/tmp/desktop-pet-regressions.json"
desktop_pet_suite = assert(loadstring(tern.fs.read(
    desktop_pet_root .. "/tests/transition-regressions.luau")))()
return "suite loaded"
```

Invocation 2 — start once, with persisted checkpoints and the explicit **fifth tests-directory argument** (Carly's VM has no plugin root):

```lua
local function persist(results)
    tern.fs.write(desktop_pet_result, tern.json.encode(results))
end
return desktop_pet_suite.run(
    tern, tern.fs.read(desktop_pet_root .. "/window.luau"),
    nil, persist, desktop_pet_root .. "/tests")
```

Later invocation 3 — inspect without restarting:

```lua
return tern.json.encode(desktop_pet_suite.get_results())
```

Alternatively read the persisted JSON from another call/process. `scheduled = true` is only startup acknowledgment; case registration is asynchronous. Require **`done == true`, no `fatal_error`, and `passed == total`**; do not use a fixed sleep or an interim count as a completion gate. Check `cases` for failures. Checkpoints include completed cases and `active_case`/`stage`/`step` before the next work callback, leaving a useful cursor if a hard callback-budget abort prevents completion.

**Observed current result: 132/132, `done=true`, in Tern 0.8.3**, executing production source through controlled inventory/KV/prompt/subprocess/ask boundaries. The suite covers installation/setup and migration fences, grouped hosts, independent generations/offline/error handling, and local-only delivery. No real KV change, subprocess, prompt, or agent ask escapes the harness. This does **not** prove a real remote SDK agent or signed neutral app reconnection, and does not carry forward the historical 44/44 claim.

### Historical native source evidence and paired-install blocker

The following records the pre-core Herdr-native checkout, not the current independent core's ownership or capability contract. It remains historical scoped evidence; a current candidate/release alone does not prove this plugin's real Tern window reconnect, SDK asks or model delivery.

The native root used for this plan implements v2 observation but still packages **`HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet`**, reporting updater **protocol 3 / observation_mode 2**, without the neutral installation `integration_api:1` contract. The current plugin installation policy requires the signed **`DesktopPet.app/Contents/MacOS/desktop-pet` plus paired neutral helper**, **integration_api 1 / protocol 4 / observation_mode 2**. The plan's Herdr bundle is therefore **rejected**, not a compatible install route. Do not downgrade capabilities, bypass signature/bundle checks, or change a live configuration to make it pass. A matching real native/plugin installation remains **blocked and unproved**.

Separate actual native-helper fixtures demonstrated independent local/A/B host keys and labels, A-only Offline/recovery, expiry with unchanged plugin observation generation but new native generations, rename stability, and remote `session_read_only` without a command. A local injected command/accepted receipt reached `prompt_accepted`; it was **not a real SDK ask or model reply**. The packaged native GUI launched in an isolated profile with `ui_ready=true`, but host-label/search/sort/read-only composer/four-language/layout visual acceptance was not obtained. The actual Tern window exposed only local host 0 and five local agents; the remote-host CLI inventory was empty. **No actual remote SDK agent support or end-to-end neutral paired-install proof is claimed.**

<details>
<summary>Historical 0.1.0 instructions and observed evidence (preserved; not current installation guidance)</summary>

The following original notes are retained, including existing local README edits. References to “current,” Herdr executable/default paths, protocol 3, published v0.3.6, automatic legacy-key adoption, and 44/44 verification describe the previous implementation only. They are not compatibility or verification claims for plugin 0.2.0; use the consumer instructions above.

[`tern-desktop-pet`](https://github.com/hanbong5938/tern-desktop-pet) is a public, separate source Tern plugin repository. It connects agents in a local Tern window to the shared native Herdr Desktop Pet app; it does not contain, install, or build that app. Install the plugin from its public GitHub URL as shown below. No OMP extension, Herdr server, patched host, remote Tern agents, or Tern terminal/PTy injection is involved. The plugin contains no character artwork or screenshots.

## Requirements and installation

Use an Apple Silicon Mac running macOS 13+ with the separately installed [Herdr Desktop Pet native app](https://github.com/hanbong5938/herdr-desktop-pet) **0.3.6 or newer**. The primary public installation path is the Homebrew prebuilt native app, then the public Tern plugin: two explicit installs. The plugin never silently downloads, executes an installer for, or builds the app. This binary path needs neither a native source checkout nor Rust/Cargo, Bun, or Node.js/npm. The native CLI must support `tern-exchange`, `--host tern`, and `update-capabilities` reporting `protocol: 3` with `observation_mode: 1` (published v0.3.6) or `2` (the current unified native source). An older app with an unknown `tern-exchange` command cannot work. Capability 2 does not require a new plugin schema or API.

[v0.3.6](https://github.com/hanbong5938/herdr-desktop-pet/releases/tag/v0.3.6) is the published latest stable release, with verified public arm64 assets/checksums and the updated stable Homebrew formula. The matched app/helper pair reports `protocol: 3` and `observation_mode: 1`. Historical v0.3.5 and beta assets remain unchanged. The public plugin install is separate from native installation; existing binaries must still be explicitly upgraded.

**Published consumer-route evidence:** the actual stable Brew upgrade from 0.3.5 to 0.3.6 succeeded, and the public pinned `--prebuilt` installer completed with only system tools on `PATH` (no Cargo, Bun, Node.js or npm). Both installed apps started in separate private Tern config/state profiles with `app_version: 0.3.6`, `observation_mode: tern` and `ui_ready: true` despite an absent configured Herdr socket parent; a valid empty exchange-v1 snapshot was accepted with `command: null`, followed by clean ordinary Stop. The real public plugin URL installed version 0.1.0 into an isolated Tern configuration and its catalog was ready without problems. This proves these consumer routes, not a connected GUI plugin window, populated sessions/model delivery, a full updater transaction or general certification. Existing user profiles were untouched.

Tern is currently a closed beta requiring a signed-in account. Install/open a compatible Tern build through your own authorized beta access and sign in normally; do not bypass authentication. A manifest link or empty signed-out window alone is not functional verification. No specific minimum Tern version or public distribution is promised here.

**Earlier local live-agent verification:** in an existing signed-in Tern 0.6.1 window, a local agent pane was observed through the window plugin and native pet using an isolated verification profile. A semantic ask to an agent in a disposable tab returned native `prompt_accepted` with delivery `accepted_may_be_queued`; Tern's actual agent transcript subsequently showed the requested `TERN_PET_SMOKE_OK` assistant reply, and its state became idle with a matching last message. The transcript independently confirms this particular reply was delivered; neither the accepted receipt nor idle state alone is an authoritative completion event. This historic observation is separate from the current repair regression evidence below. It was local verification of unpublished source, not a published release or a minimum-version guarantee.

Install the native app first, then the plugin. If the formula is already installed, replace the first command with `brew update && brew upgrade hanbong5938/tap/herdr-desktop-pet`. The following **published v0.3.6 Tern-only example** uses an optional isolated profile to avoid affecting an existing Herdr pet. Keep its config/state paths identical in all native commands and in the Tern command-palette configuration. These isolated paths are not new mandatory defaults; existing native profiles/preferences are preserved.

```sh
brew install hanbong5938/tap/herdr-desktop-pet
tern plugin install https://github.com/hanbong5938/tern-desktop-pet

PET_BIN="$(command -v herdr-desktop-pet)"
PET_CONFIG="$HOME/.config/tern-desktop-pet/native"
PET_STATE="$HOME/.local/state/tern-desktop-pet/native"

"$PET_BIN" --version
"$PET_BIN" update-capabilities
# Published v0.3.6: confirm version, protocol: 3 and observation_mode: 1.
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" settings set exit_with_herdr off
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" start
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" status

tern plugin reload
tern plugin list
```

Confirm version **0.3.6+** and the appropriate capability fields **before** starting the app; the commands above are not a substitute for those checks. The published v0.3.6 app defaults to Herdr mode, so retain explicit `--host tern` for that binary. It does not contain the current-source Auto dropdown or live host preference described below. Next open a signed-in Tern window and use **Configure desktop pet connection** (`configure`) to save `PET_BIN` and the two expanded profile paths, then **Connect to desktop pet** (`connect`); shell variables do not configure the plugin.

### Build the published native tag

Optional native source development requires Rust/Cargo, Bun, Node.js/npm, Xcode Command Line Tools and `codesign`; builds can download dependencies. To reproduce the **published capability-1 app**, set `PET_SOURCE` to an actual absolute checkout path, using an unused directory for a new clone. Build the published v0.3.6 tag below; this is not the unified capability-2 source:

```sh
PET_SOURCE=/absolute/path/to/herdr-desktop-pet-source
git clone https://github.com/hanbong5938/herdr-desktop-pet.git "$PET_SOURCE"
cd "$PET_SOURCE"
git fetch origin tag v0.3.6
git checkout --detach v0.3.6
bash scripts/install.sh --source
PET_BIN="$PET_SOURCE/dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet"
"$PET_BIN" --version
"$PET_BIN" update-capabilities
```

For an existing native checkout, skip only the clone command, and do not switch a checkout containing your own changes to the published tag. The source installer packages the app into that checkout's `dist/HerdrDesktopPet.app`; it does not copy it into the plugin checkout. For this published-tag build, use the same optional isolated `PET_CONFIG`/`PET_STATE`, explicit `--host tern` settings/start/status commands and public plugin installation above, substituting this source-built `PET_BIN`.

### Historical unified native source (not current plugin installation guidance)

The current native checkout's unified connection feature is **source-only**. Its matching app/helper pair reports `protocol: 3` and `observation_mode: 2`; installing public v0.3.6 or building its tag does not supply this feature. In an existing native checkout containing the unified changes, build with `bash scripts/install.sh --source` and use its `dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet`, not an older `PATH` binary.

The native **Connection** card has an **Auto / Herdr / Tern** dropdown. **Auto** enables Herdr and local Tern connections together without choosing a preferred provider; installation alone is not proof of a connection. Per-provider **Connected / Waiting / Disabled** status reflects actual connections. Selecting a mode saves it and applies it **live to the same running app**, without a restart; a failed save retains the prior mode. A disabled provider cannot send through the bridge. Disconnecting a host in Auto does not close the pet, and pending replies keep their original provider identity rather than being replayed elsewhere.

A new native profile defaults to Auto, unless an explicit launch option or owned environment overrides it. Existing saved choices are preserved; a legacy preferences file without a host field keeps Herdr. The current source writes `auto`, `herdr`, or `tern`; legacy `both` is accepted only as a migration input. Use the dropdown or `preferences set --observation-host auto|herdr|tern` to change the running profile. Read/status commands do not require repeating `--host`.

The plugin already uses the **same native default profile paths**, so a separate Tern profile is unnecessary for this unified source. For manual commands, clear or align any injected `HERDR_PLUGIN_CONFIG_DIR` / `HERDR_PLUGIN_STATE_DIR`, then use the matching executable and profile:

```sh
PET_SOURCE=/absolute/path/to/native-checkout-with-unified-changes
PET_BIN="$PET_SOURCE/dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet"
PET_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/desktop-pet"
PET_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/desktop-pet"

"$PET_BIN" update-capabilities
# Confirm protocol: 3 and observation_mode: 2 for this source build.
"$PET_BIN" --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" start
# Explicitly opt this profile into Auto, including an existing Herdr profile:
"$PET_BIN" --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" preferences set --observation-host auto
"$PET_BIN" --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" status
```

To share an **existing base profile** instead, open the native Connection card's collapsed **Connection settings**, and copy its actual executable, config directory, and state directory into the plugin's three Configure prompts below. Select the profile you intend to use, not a mixture of paths from different profiles. Validate/save the complete triple, then choose Connect. This changes plugin routing only: it never moves, merges, overwrites, or deletes native profile files. Existing isolated profiles and saved plugin connections remain untouched unless you explicitly select a different route.

**Observation scope**, **Connection settings**, and **Diagnostics** start collapsed. Tern-only mode hides Herdr remote-machine controls without erasing their choices. The **App launch** card's automatic launch option remains Herdr-specific; exit-with-Herdr is available only in Herdr-only mode, not Auto or Tern. There is no implied Tern autostart.

### Local plugin checkout alternative

Alternatively, use a local plugin source checkout instead of the public `tern plugin install` command:

```sh
TERN_PLUGIN=/absolute/path/to/tern-desktop-pet
git clone https://github.com/hanbong5938/tern-desktop-pet.git "$TERN_PLUGIN"
tern plugin link "$TERN_PLUGIN"
tern plugin reload
tern plugin list
```

If the plugin checkout already exists, skip its clone command. Linking is a development alternative; it does not build or install the separate native app.

Run the examples after substituting real paths; `PET_*` shell variables are conveniences, not persistent Tern settings. Inspect capability JSON for the matching app version/capability and `status` for the running executable and effective `observation_mode` (`tern` in the published example). If a different/older daemon owns the selected profile, stop that daemon using the same config/state paths before starting the intended executable. This binary replacement is distinct from capability-2 live host changes, which do not require stopping. Optional isolated profiles remain useful for old binaries; the unified source and plugin can share the native default profile. The native `--socket` option points to a **Herdr** backend and is unnecessary for Tern-only operation. The published example's explicit `--host tern` avoids inherited host-mode environment settings, and `exit_with_herdr off` keeps that independently launched old app available without Herdr. If your shell exports `HERDR_PLUGIN_CONFIG_DIR` or `HERDR_PLUGIN_STATE_DIR`, unset them for manual commands or match the intended profile: injected plugin paths take precedence over CLI paths.

`status.herdr_socket` reports the configured Herdr socket path retained by the native app's update context, even in Tern-only mode; it is not evidence of a live Herdr endpoint. Tern-only operation needs neither a Herdr registration nor a socket at that path (nor its parent directory). This plugin does not introduce a second native application. Published v0.3.6 Tern updates require a matching signed app/helper pair supporting `protocol: 3` and `observation_mode: 1`. The unified source's Auto/live-host contract requires capability 2; its updater must preserve the saved/effective host and reject an incompatible target, rather than silently installing a capability-1 app that loses the selected behavior.

`tern plugin link` uses this checkout in place (rather than publishing or copying it). `tern plugin reload` reloads installed plugins in the running daemon; `tern plugin list` reports loading/errors. Run `tern plugin reload` after editing `window.luau`. Open an actual Tern **window** after signing in, with a local agent pane. Plugin execution is window-local, not a daemon-side background poll when there is no window: a headless daemon's plugin catalog alone does not exercise the plugin runtime. Use Tern's command palette entry **Connect to desktop pet** (`connect`) to request an immediate exchange; the plugin also polls about every 1.2 seconds and observes relevant pane/tab/command changes.

## Configure the window plugin

In the actual Tern window, choose the desired native base profile first, then **Configure desktop pet connection** (`configure`) from the command palette. For the unified source, copy the actual values shown under native **Connection settings**; for the published isolated example, use the expanded `PET_*` values. Its three prompts, in order, are:

1. **Desktop pet executable (path or command):** enter the actual executable's full absolute path, for example the value printed by `printf '%s\n' "$PET_BIN"` (not a variable name or app bundle directory). A source build uses `/absolute/path/to/native-checkout/dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet`.
2. **Absolute desktop pet config directory:** the selected base profile's actual expanded config path, matching `PET_CONFIG` when using a shell example.
3. **Absolute desktop pet state directory:** that same base profile's actual expanded state path, matching `PET_STATE`.

The window plugin stores one canonical `tern.kv` key, `connection`, containing `{ version = 1, executable = "...", config_dir = "...", state_dir = "..." }`. It validates the entire candidate (version/fields, a nonempty executable, absolute config/state paths, and no NUL bytes), then saves it in **one KV write**, before switching the active profile, resetting the source incarnation, and immediately exchanging. Canceling any prompt, a prompt/validation error, or a failed save leaves the previous saved and active connection intact; no partially entered profile becomes active.

After the complete triple validates and saves successfully, choose **Connect to desktop pet** (`connect`) to request an exchange against that route. Configure changes only the saved/active plugin connection, not native files: it does not copy, move, merge, or delete either the old or target profile. An existing separate Tern profile remains available. No uncertain ask is replayed into the newly selected profile.

Only when `connection` is absent does the plugin adopt the old three keys `executable`, `config_dir`, and `state_dir` together, filling missing values from defaults. This one-time migration validates and commits the canonical object before attempting to remove the legacy keys. Cleanup failure is logged but does not undo the committed object. A malformed existing `connection` is an error, **never** a reason to fall back to old keys; use **Configure desktop pet connection** to repair it.

Defaults, if left unconfigured, are executable `herdr-desktop-pet`, config `${XDG_CONFIG_HOME}/herdr/plugins/config/desktop-pet` or `~/.config/herdr/plugins/config/desktop-pet`, and state `${XDG_STATE_HOME}/herdr/plugins/desktop-pet` or `~/.local/state/herdr/plugins/desktop-pet`. These are **the native defaults too**, not a mandatory separate Tern profile. An existing saved `connection` is preserved rather than automatically redirected. If choosing another base profile or the optional isolated published example, explicitly configure all three values; also select an absolute executable to avoid an older `PATH` binary. The native pet must already be running in the selected profile with Tern enabled (Auto or Tern in the unified source); the plugin invokes `tern-exchange` and does not start it.

After configuring the complete connection, explicitly run `tern plugin reload` if an earlier error disabled the window's timer hook (for example, an invalid default executable followed by a callback-budget error). Saving the corrected profile or choosing **Connect to desktop pet** does not re-enable a hook that Tern has disabled; it stays disabled until reload. Then check the actual signed-in window, not only the daemon's plugin catalog. The user's existing window login was working in this repair; this is not evidence of a general login or Keychain problem.

KV is shared between windows. A profile committed by another window fences delayed configuration prompts and exchange callbacks: an old prompt chain cannot overwrite the newer object, and an old exchange cannot deliver an ask into the new profile. The profile is refreshed before interpreting a subprocess reply and again immediately before `agents:ask`; an external malformed object blocks exchange rather than reviving legacy settings.

The plugin reads Tern's window inventory (`hosts`, `panes`, `tabs`, `sessions`, `agents`), accepts exactly one local host, and sends only its local agent panes over a bounded stdin/stdout `tern-exchange` subprocess to the native app's private same-user socket. It has no remote-agent fallback. The native bubble shows those local sessions; a selected live card may offer a reply. On send, the plugin rechecks the pane and uses Tern's `agents:ask`, not terminal input. A successful ask and the subsequent native `prompt_accepted` state mean Tern **accepted or may have queued** the text, not that the model read it, delivered a final answer, or finished work. Never treat an accepted submission as completion. On an error, inspect the Tern window's desktop-pet error toast/log, `tern plugin list`, native `status`, the configured executable/profile, and `<state-dir>/desktop-pet.log`. A disconnected/unknown result must not be blindly resent.

Inventory collection uses **four zero-delay awaitable callbacks**, scheduled with Tern's documented `tern.sleep(0):next(...)`: `tabs`, `sessions`, and `agents` each get their own callback; the last callback reads `hosts` and `panes` together, then performs shared pure validation. The potentially large agent payload is collected separately. Critical local-host membership and pane checks share the last callback's fresh `cx`, and command revalidation uses that same fresh context for `agents:get` and `agents:ask`. Collection is already active/busy before its first continuation is scheduled, and incarnation, profile, work identity, and phase fences protect delayed callbacks throughout collection and revalidation. The ordinary 1.2-second polling timer remains; inventory handoffs no longer use coarse 1 ms timers.

Each callback makes **at most two synchronous inventory SDK calls**. At 12 ms per inventory call, this is at most `2 × 12 = 24 ms` of modeled inventory cost against Tern's 50 ms callback budget, not a guarantee for a host call or total callback latency. Limited owned-private-profile probes observed about 20 ms for five zero-delay awaitable callbacks, and 20 subprocess samples observed 0.49–1.68 ms synchronous launch cost and 150–208 ms total process time. Those observations are not a general overhead benchmark or an end-to-end guarantee. A single SDK call, other callback work, or OS preemption can still exceed 50 ms; zero-delay continuations do not guarantee indefinite uninterrupted polling.

Reloads and newly opened windows create independent source identities; old incarnations and closed windows become **Offline** at a monotonic freshness age of **at least five seconds**, rather than being silently merged into a new window. The native control accept loop checks expiry on its existing 100 ms tick, independently of serial Herdr polling or client I/O. Multiple windows remain separate. The **64-source budget is shared by Herdr and Tern**, not 64 Tern windows in addition to Herdr. Registration can reclaim only expired, offline Tern sources, after finalizing any pending operation; it never evicts live Tern or Herdr sources, and source IDs are never reused. Each plugin snapshot contains at most 128 local agents. Tern changes or a daemon restart can invalidate outstanding prompts, so inspect the live card/status rather than assuming success from a prior window.

## Exchange limits and recovery

The exchange envelope is version 1 (the native app/update protocol remains 3). The request limit is **256 KiB of serialized JSON**; an optional transport LF or CRLF does not count toward that JSON limit. The independent reply limit is **512 KiB of complete stdout, including its trailing LF**. These are byte limits, not character counts or raw prompt lengths. Native admission checks the actual serialized host response before creating a pending operation or offering a command; an escaped payload that cannot fit produces a definite `prompt_too_large`/`TooLarge` outcome with no offer, not an uncertain send. It does not estimate a Herdr allowance by subtracting guessed framing headroom.

The first unbound full snapshot has `instance_id: null` and empty `results`; a successful registration reply has `command: null`. Failure replies may include a structured `error_code` from exactly this set:

| `error_code` | Plugin recovery |
| --- | --- |
| `binding_required` | Reset the source identity and register a fresh, result-free snapshot on the next ordinary poll. This also recovers a lost first registration reply without a special retry loop. |
| `instance_changed` | A different returned native instance ID invalidates the old binding and reports; reset and register on the next ordinary poll. Pending delivery remains unknown. |
| `source_retired` | Reset and register a new source on the next ordinary poll; do not replay the retired source's ask. |
| `receipt_rejected` | Only for an exactly bound reply from the captured instance, drop the captured result reports; retain the source binding and any newer reports. An unbound/mismatched rejection does not authorize that drop. |
| `rejected` | Surface the failure; do not infer successful delivery, reset the binding merely from this code, or replay the ask. |

After an accepted or failed command report, the plugin **immediately starts the ordinary fresh full-inventory exchange** to send the receipt instead of waiting for the next 1.2-second poll. This collects a new full snapshot; it does not use a cached snapshot as stale proof, replay `agents:ask`, add a new receipt protocol, or increase a timeout. Recovery exchanges also refresh inventory and **never replay an uncertain `agents:ask`**. A successful submission receipt is still only acceptance/maybe-queued delivery, not model completion.

## Historical production-code Luau regression evidence

The previous monolithic harness invocation is retired; use the current small-loader/module instructions above. The following **44/44 Tern 0.6.1** result is preserved only as historical evidence for the earlier awaitable revision, not as a current run or a current harness command.

Each case was scheduled on a real Tern timer callback with the real JSON codec, but used a **controlled SDK boundary** for inventory, KV, prompts, inventory-continuation scheduling, subprocess results, and agent asks; no real KV write, subprocess, prompt, or `agents:ask` escaped the harness. **Historical awaitable-callback repair evidence was 44/44 passed in an actual Tern 0.6.1 window Luau VM**, executing the then-production source, not a standalone model. Coverage included the original 35 cases, profile/identity/pane/local-host stage fences, latest local membership and pane identity checks, the 12 ms-per-inventory-API/50 ms callback-budget case, and awaitable failure/busy cleanup and command cancellation without replay. The scheduling case modeled **1 second of timer delay versus 10 ms per microtask continuation** and confirmed an accepted receipt before the native **5-second deadline** using a controlled receipt consumer, not a real native subprocess. The earlier 43/43 timer-chunk run is also historical. Controlled SDK regressions are not measured host-latency guarantees or a **full live-agent/model-delivery smoke test**; do not substitute them for transcript-level verification or confuse them with the earlier live-agent observation above.

Separate earlier window evidence showed continuous source observation before and after seven seconds and a timely semantic `agents:ask` receipt. A later timer-chunk run nevertheless hit the 50 ms callback limit after about 16 minutes, motivating the awaitable cutover. These earlier observations and the private-profile timing probes are not an indefinite callback-budget guarantee.

With the final awaitable revision in the actual configured window, the current profile showed one fresh source after a 6.25-second old-source grace period. A real native `sessions.prompt` operation then returned exit code 0 with `prompt_accepted`, `committed: false`, `native_applied: false`, and delivery `accepted_may_be_queued`. Before the subsequent GUI profile cutover, five status samples spaced three seconds apart each showed one connected source. The actual GUI configuration flow then completed **A → B**: after a further 6.25-second grace period, the canonical connection's config/state paths were both B, old profile A reported `connected: false`, and new profile B reported `connected: true`. No new production callback-budget failure appeared in the inspected log range. These are finite observed checkpoints, not an indefinite 50 ms-budget or host-latency guarantee. This confirms accepted semantic delivery and the completed configuration cutover, not the native updater's full GUI Apply flow.

**Historical specific transcript-level delivery proof:** the owned actual Tern session JSONL subsequently contained an assistant-role message with the exact text `TERN_MICROTASK_SMOKE_OK`. This independently confirms that particular requested model reply was delivered. The native accepted receipt alone did not establish it; this observation is not a general guarantee of model completion or of final-answer delivery for future receipts.

</details>

## Licensing

The code in **this plugin repository** is MIT licensed under [LICENSE.txt](LICENSE.txt). The native app and bundled character artwork remain in the separate app checkout, under their own applicable notices; the plugin's MIT license does **not** relicense or bundle Rubelia or other artwork. No artwork was copied here.
