# Tern Desktop Pet

**English** · [한국어](README.ko.md)

[`tern-desktop-pet`](https://github.com/hanbong5938/tern-desktop-pet) is a public, separate source Tern plugin repository. It connects agents in a local Tern window to the shared native Herdr Desktop Pet app; it does not contain, install, or build that app. Install the plugin from its public GitHub URL as shown below. No OMP extension, Herdr server, patched host, remote Tern agents, or Tern terminal/PTy injection is involved. The plugin contains no character artwork or screenshots.

## Requirements and installation

Use an Apple Silicon Mac running macOS 13+ with the separately installed [Herdr Desktop Pet native app](https://github.com/hanbong5938/herdr-desktop-pet) **0.3.6 or newer**. The primary path is the Homebrew prebuilt native app, then the public Tern plugin: two explicit installs. The plugin never silently downloads, executes an installer for, or builds the app. This binary path needs neither a native source checkout nor Rust/Cargo, Bun, or Node.js/npm. The native CLI must support `tern-exchange`, `--host tern`, and `update-capabilities` reporting **both** `protocol: 3` and `observation_mode: 1`; an older app with an unknown `tern-exchange` command cannot work.

[v0.3.6](https://github.com/hanbong5938/herdr-desktop-pet/releases/tag/v0.3.6) is the published latest stable release, with verified public arm64 assets/checksums and the updated stable Homebrew formula. The matched app/helper pair reports `protocol: 3` and `observation_mode: 1`. Historical v0.3.5 and beta assets remain unchanged. The public plugin install is separate from native installation; existing binaries must still be explicitly upgraded.

**Published consumer-route evidence:** the actual stable Brew upgrade from 0.3.5 to 0.3.6 succeeded, and the public pinned `--prebuilt` installer completed with only system tools on `PATH` (no Cargo, Bun, Node.js or npm). Both installed apps started in separate private Tern config/state profiles with `app_version: 0.3.6`, `observation_mode: tern` and `ui_ready: true` despite an absent configured Herdr socket parent; a valid empty exchange-v1 snapshot was accepted with `command: null`, followed by clean ordinary Stop. The real public plugin URL installed version 0.1.0 into an isolated Tern configuration and its catalog was ready without problems. This proves these consumer routes, not a connected GUI plugin window, populated sessions/model delivery, a full updater transaction or general certification. Existing user profiles were untouched.

Tern is currently a closed beta requiring a signed-in account. Install/open a compatible Tern build through your own authorized beta access and sign in normally; do not bypass authentication. A manifest link or empty signed-out window alone is not functional verification. No specific minimum Tern version or public distribution is promised here.

**Earlier local live-agent verification:** in an existing signed-in Tern 0.6.1 window, a local agent pane was observed through the window plugin and native pet using an isolated verification profile. A semantic ask to an agent in a disposable tab returned native `prompt_accepted` with delivery `accepted_may_be_queued`; Tern's actual agent transcript subsequently showed the requested `TERN_PET_SMOKE_OK` assistant reply, and its state became idle with a matching last message. The transcript independently confirms this particular reply was delivered; neither the accepted receipt nor idle state alone is an authoritative completion event. This historic observation is separate from the current repair regression evidence below. It was local verification of unpublished source, not a published release or a minimum-version guarantee.

Install the native app first, then the plugin. If the formula is already installed, replace the first command with `brew update && brew upgrade hanbong5938/tap/herdr-desktop-pet`. Keep the same isolated native config/state paths in every native command and in the Tern command-palette configuration: Existing native profiles/preferences are preserved.

```sh
brew install hanbong5938/tap/herdr-desktop-pet
tern plugin install https://github.com/hanbong5938/tern-desktop-pet

PET_BIN="$(command -v herdr-desktop-pet)"
PET_CONFIG="$HOME/.config/tern-desktop-pet/native"
PET_STATE="$HOME/.local/state/tern-desktop-pet/native"

"$PET_BIN" --version
"$PET_BIN" update-capabilities
# Continue only after confirming 0.3.6+, protocol: 3 and observation_mode: 1.
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" settings set exit_with_herdr off
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" start
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" status

tern plugin reload
tern plugin list
```

Confirm version **0.3.6+** and both capability fields **before** starting the app; the commands above are not a substitute for those checks. The shared native app defaults to Herdr mode, so retain explicit `--host tern`. Next open a signed-in Tern window and use **Configure desktop pet connection** (`configure`) in its command palette to save `PET_BIN` and the two expanded isolated paths as described below; shell variables do not configure the plugin.

### Source-development alternative

Optional native source development requires Rust/Cargo, Bun, Node.js/npm, Xcode Command Line Tools and `codesign`; builds can download dependencies. Set `PET_SOURCE` to an actual absolute checkout path, using an unused directory for a new clone. Build the published v0.3.6 tag below; no integration branch is required:

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

For an existing native checkout, skip only the clone command. The source installer packages the app into that checkout's `dist/HerdrDesktopPet.app`; it does not copy it into the plugin checkout. Then use the same isolated `PET_CONFIG`/`PET_STATE`, explicit `--host tern` settings/start/status commands and public plugin installation above, substituting this source-built `PET_BIN`.

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

Run these after substituting real paths; the `PET_*` shell variables are only conveniences, not persistent Tern settings. Inspect the capability JSON for **both** required fields, and inspect `status` for the running app executable and `observation_mode: tern`. `start` reuses an already-running daemon; if a different/older daemon owns this profile, stop it using the same config/state paths before starting the new one. Isolating both paths avoids disturbing an existing Herdr pet profile. The native `--socket` option points to a **Herdr** backend and is not needed for Tern-only operation. Explicit `--host tern` avoids relying on an inherited host-mode environment setting; `exit_with_herdr off` keeps this independently launched pet available without Herdr. If your shell exports `HERDR_PLUGIN_CONFIG_DIR` or `HERDR_PLUGIN_STATE_DIR`, unset them for these manual commands or ensure they match the displayed profile: injected plugin paths take precedence over CLI paths.

`status.herdr_socket` reports the configured Herdr socket path retained by the native app's update context, even in Tern-only mode; it is not evidence of a live Herdr endpoint. Tern-only operation needs neither a Herdr registration nor a socket at that path (nor its parent directory). The shared app supports `--host herdr|tern|both`; this plugin does not introduce a second native application. Tern/Both updates require the signed app and signed helper to support `observation_mode: 1` while retaining protocol 3, and the restarted app's status must match the requested mode.

`tern plugin link` uses this checkout in place (rather than publishing or copying it). `tern plugin reload` reloads installed plugins in the running daemon; `tern plugin list` reports loading/errors. Run `tern plugin reload` after editing `window.luau`. Open an actual Tern **window** after signing in, with a local agent pane. Plugin execution is window-local, not a daemon-side background poll when there is no window: a headless daemon's plugin catalog alone does not exercise the plugin runtime. Use Tern's command palette entry **Connect to desktop pet** (`connect`) to request an immediate exchange; the plugin also polls about every 1.2 seconds and observes relevant pane/tab/command changes.

## Configure the window plugin

In the actual Tern window, choose **Configure desktop pet connection** (`configure`) from the command palette. Its three prompts, in order, are:

1. **Desktop pet executable (path or command):** enter the full absolute path printed by `printf '%s\n' "$PET_BIN"` in the shell above (not the variable name or app bundle directory). For the source-development alternative, this is `/absolute/path/to/herdr-desktop-pet-source/dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet`.
2. **Absolute desktop pet config directory:** the same expanded absolute path as `PET_CONFIG`.
3. **Absolute desktop pet state directory:** the same expanded absolute path as `PET_STATE`.

The window plugin stores one canonical `tern.kv` key, `connection`, containing `{ version = 1, executable = "...", config_dir = "...", state_dir = "..." }`. It validates the entire candidate (version/fields, a nonempty executable, absolute config/state paths, and no NUL bytes), then saves it in **one KV write**, before switching the active profile, resetting the source incarnation, and immediately exchanging. Canceling any prompt, a prompt/validation error, or a failed save leaves the previous saved and active connection intact; no partially entered profile becomes active.

Only when `connection` is absent does the plugin adopt the old three keys `executable`, `config_dir`, and `state_dir` together, filling missing values from defaults. This one-time migration validates and commits the canonical object before attempting to remove the legacy keys. Cleanup failure is logged but does not undo the committed object. A malformed existing `connection` is an error, **never** a reason to fall back to old keys; use **Configure desktop pet connection** to repair it.

Defaults, if left unconfigured, are executable `herdr-desktop-pet`, config `${XDG_CONFIG_HOME}/herdr/plugins/config/desktop-pet` or `~/.config/herdr/plugins/config/desktop-pet`, and state `${XDG_STATE_HOME}/herdr/plugins/desktop-pet` or `~/.local/state/herdr/plugins/desktop-pet`. Those default profile paths are **not** the isolated paths above, and a `PATH` binary may be an older app, so explicitly configure all three. The native pet must already be running in that profile; the plugin invokes `tern-exchange` and does not start it.

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

## Production-code Luau regression harness

[`tests/transition-regressions.luau`](tests/transition-regressions.luau) executes the actual `window.luau` source, unchanged inside a `function(tern)` wrapper, in an actual Tern window Luau VM. For example, run this through the window's supported Luau execution facility ([Carly's Lua tool wrapper](https://docs.stencil.so/tern/reference/api-window.html#carlys-lua-tool)), after replacing the absolute paths:

```lua
local TEST_PATH = "/absolute/path/to/tern-desktop-pet/tests/transition-regressions.luau"
local WINDOW_PATH = "/absolute/path/to/tern-desktop-pet/window.luau"
local suite = assert(loadstring(tern.fs.read(TEST_PATH)))()
local source = tern.fs.read(WINDOW_PATH)
suite.run(tern, source, function(results)
    print(tern.json.encode(results))
end)
-- Asynchronous: suite.get_results() exposes done/passed/total/cases.
```

Each case is scheduled on a real Tern timer callback with the real JSON codec, but uses a **controlled SDK boundary** for inventory, KV, prompts, inventory-continuation scheduling, subprocess results, and agent asks; no real KV write, subprocess, prompt, or `agents:ask` escapes the harness. **Current awaitable-callback repair evidence is 44/44 passed in an actual Tern 0.6.1 window Luau VM**, executing the production source, not a standalone model. Coverage includes the original 35 cases, profile/identity/pane/local-host stage fences, latest local membership and pane identity checks, the 12 ms-per-inventory-API/50 ms callback-budget case, and awaitable failure/busy cleanup and command cancellation without replay. The scheduling case models **1 second of timer delay versus 10 ms per microtask continuation** and confirms an accepted receipt before the native **5-second deadline** using a controlled receipt consumer, not a real native subprocess. The earlier 43/43 timer-chunk run is historical, not the current revision's evidence. Controlled SDK regressions are not measured host-latency guarantees or a **full live-agent/model-delivery smoke test**; do not substitute them for transcript-level verification or confuse them with the earlier live-agent observation above.

Separate earlier window evidence showed continuous source observation before and after seven seconds and a timely semantic `agents:ask` receipt. A later timer-chunk run nevertheless hit the 50 ms callback limit after about 16 minutes, motivating the awaitable cutover. These earlier observations and the private-profile timing probes are not an indefinite callback-budget guarantee.

With the final awaitable revision in the actual configured window, the current profile showed one fresh source after a 6.25-second old-source grace period. A real native `sessions.prompt` operation then returned exit code 0 with `prompt_accepted`, `committed: false`, `native_applied: false`, and delivery `accepted_may_be_queued`. Before the subsequent GUI profile cutover, five status samples spaced three seconds apart each showed one connected source. The actual GUI configuration flow then completed **A → B**: after a further 6.25-second grace period, the canonical connection's config/state paths were both B, old profile A reported `connected: false`, and new profile B reported `connected: true`. No new production callback-budget failure appeared in the inspected log range. These are finite observed checkpoints, not an indefinite 50 ms-budget or host-latency guarantee. This confirms accepted semantic delivery and the completed configuration cutover, not the native updater's full GUI Apply flow.

**Current specific transcript-level delivery proof:** the owned actual Tern session JSONL subsequently contained an assistant-role message with the exact text `TERN_MICROTASK_SMOKE_OK`. This independently confirms that particular requested model reply was delivered. The native accepted receipt alone did not establish it; this observation is not a general guarantee of model completion or of final-answer delivery for future receipts.

## Licensing

The code in **this plugin repository** is MIT licensed under [LICENSE.txt](LICENSE.txt). The native app and bundled character artwork remain in the separate app checkout, under their own applicable notices; the plugin's MIT license does **not** relicense or bundle Rubelia or other artwork. No artwork was copied here.
