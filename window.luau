-- The window VM is the only source of Tern agent facts and semantic asks.
-- No host half, PTY writes, OMP extension, or agent-completion inference.
local MAX_AGENTS = 128
local MAX_HOSTS = 64
local MAX_HOST_ERROR_BYTES = 512
local MAX_REQUEST_BYTES = 256 * 1024
local MAX_RESPONSE_BYTES = 512 * 1024
local MAX_FIELD_BYTES = 4096
local INTERVAL_MS = 1200
local PROCESS_TIMEOUT_MS = 2600
local ERROR_REPEAT_MS = 30000
local MAX_SAFE_ID = 9007199254740991
local NULL = tern.json.null

local function valid_id(id)
	return type(id) == "number" and id >= 0 and id <= MAX_SAFE_ID and id % 1 == 0
end

local function is_array(value)
	if type(value) ~= "table" then return false end
	local length, count = #value, 0
	for index in pairs(value) do
		if not valid_id(index) or index < 1 or index > length then return false end
		count += 1
	end
	return count == length
end

local function id_string(id)
	if not valid_id(id) then
		error("Tern returned an invalid pane, tab, session or host id")
	end
	return string.format("%.0f", id)
end

local function optional_id(id)
	return id == nil and NULL or id_string(id)
end

local function optional_string(value)
	if value == nil or value == NULL or value == "" then
		return NULL
	end
	if type(value) ~= "string" or #value > MAX_FIELD_BYTES then
		error("Tern returned invalid or oversized optional agent metadata")
	end
	return value
end

-- No public window-VM identifier is exposed. Each VM incarnation therefore owns
-- an independent source, and an older source expires instead of being merged.
local function new_identity()
	local now = tern.now()
	local first = math.random(1, 2147483647)
	local second = math.random(1, 2147483647)
	local epoch = (math.floor(now) % 4194304) * 2147483648 + first
	local window = string.format("vm-%d-%d-%d-%s", math.floor(now), first, second, tostring({}):gsub("[^%w]", ""))
	return window, epoch
end

local window, epoch = new_identity()
local incarnation = 1
local sequence = 0
local instance_id = nil
local observed_hosts = {}
local native_generations = {}
local local_identity = nil
local results_identity = nil
local busy = false
local results = tern.json.array()
local active_exchange = nil
local last_error = nil
local last_error_at = 0
local timer = nil
local active_connection = nil

local function show_error(cx, message)
	local now = tern.now()
	if message ~= last_error or now - last_error_at >= ERROR_REPEAT_MS then
		last_error = message
		last_error_at = now
		tern.log.warn("Desktop pet: " .. message)
		if cx ~= nil then
			cx:toast("error", "Desktop pet disconnected", message)
		end
	end
end

local function show_connected(cx)
	if last_error ~= nil then
		last_error = nil
		if cx ~= nil then
			cx:toast("info", "Desktop pet connected")
		end
	end
end

local SETUP_TIMEOUT_MS = 10000
local SETUP_RESPONSE_BYTES = 32 * 1024
local setup_serial = 0
local setup_pending = nil
local automatic_reconnect = false
local active_storage = nil
local INSTALL_ADVICE = "Approved saved legacy-route migration reconnects automatically when native is ready. Configure is for new/manual setup or repair with an absolute executable and both profile paths. Install Desktop Pet separately from https://github.com/hanbong5938/desktop-pet; the plugin never installs or starts the app."

local function absolute_path(value)
	return type(value) == "string" and value:sub(1, 1) == "/" and #value <= MAX_FIELD_BYTES
		and not value:find("[%z\r\n]")
end

local function legacy_executable(value)
	return type(value) == "string" and (value == "herdr-desktop-pet" or value:match("/herdr%-desktop%-pet$") ~= nil)
end

local function validate_connection(connection)
	if type(connection) ~= "table" or connection.version ~= 1 then
		error("desktop pet connection must be a version 1 object")
	end
	for key in pairs(connection) do
		if key ~= "version" and key ~= "executable" and key ~= "config_dir" and key ~= "state_dir" then
			error("desktop pet connection contains an unknown field")
		end
	end
	local executable, config_dir, state_dir = connection.executable, connection.config_dir, connection.state_dir
	if not absolute_path(executable) and not legacy_executable(executable) then
		error("configure an absolute Desktop Pet executable; command names are not saved routes")
	end
	if not absolute_path(config_dir) then
		error("configure an absolute desktop pet config directory")
	end
	if not absolute_path(state_dir) then
		error("configure an absolute desktop pet state directory")
	end
	return { version = 1, executable = executable, config_dir = config_dir, state_dir = state_dir }
end


local function same_connection(a, b)
	return a ~= nil and b ~= nil and a.version == b.version and a.executable == b.executable
		and a.config_dir == b.config_dir and a.state_dir == b.state_dir
end

local function cleanup_legacy()
	local ok, err = pcall(function()
		tern.kv.set("executable", nil)
		tern.kv.set("config_dir", nil)
		tern.kv.set("state_dir", nil)
	end)
	if not ok then
		tern.log.warn("Desktop pet: connection saved, but old settings could not be removed: " .. tostring(err))
	end
end

local function stored_identity()
	local connection = tern.kv.get("connection")
	if connection ~= nil then return tern.json.encode({ connection = connection }) end
	return tern.json.encode({
		connection = connection,
		executable = tern.kv.get("executable"),
		config_dir = tern.kv.get("config_dir"),
		state_dir = tern.kv.get("state_dir"),
	})
end

local function settings()
	local connection = tern.kv.get("connection")
	if connection ~= nil then
		-- Malformed canonical data never grants permission to revive old keys.
		return validate_connection(connection)
	end
	local executable, config_dir, state_dir = tern.kv.get("executable"), tern.kv.get("config_dir"), tern.kv.get("state_dir")
	if executable == nil and config_dir == nil and state_dir == nil then
		return nil
	end
	if executable == nil or config_dir == nil or state_dir == nil then
		error("old connection is incomplete; Configure all three values without mixing profiles")
	end
	return validate_connection({ version = 1, executable = executable, config_dir = config_dir, state_dir = state_dir })
end

-- Bootstrap only locates bytes. The signed paired helper makes the final
-- discovery/origin decision, including fail-closed explicit and locator paths.
-- HOME is deliberately not installation authority; obtain the OS account home.
local DISCOVER_SCRIPT = [[
set -eu
fail() { printf '%s\n' "$*" >&2; exit 1; }
explicit=$1
if [ -n "$explicit" ]; then printf 'candidate\n%s\n' "$explicit"; exit 0; fi
account=$(/usr/bin/id -un)
record=$(/usr/bin/dscl . -read "/Users/$account" NFSHomeDirectory)
home=${record#NFSHomeDirectory: }
case "$home" in /*) ;; *) fail "Cannot resolve OS account home";; esac
locator="$home/.local/share/desktop-pet/installation.json"
if [ -e "$locator" ] || [ -L "$locator" ]; then
  [ ! -L "$locator" ] && [ -f "$locator" ] || fail "Invalid installation locator"
  uid=$(/usr/bin/id -u)
  [ "$(/usr/bin/stat -f %u "$locator")" = "$uid" ] || fail "Installation locator is not owned by this account"
  mode=$(/usr/bin/stat -f %Lp "$locator")
  case "$mode" in 400|600) ;; *) fail "Installation locator is not private";; esac
  [ "$(/usr/bin/stat -f %z "$locator")" -le 32768 ] || fail "Installation locator is too large"
  printf 'locator\n'
  /bin/cat "$locator"
  exit 0
fi
signed_candidate() (
  candidate=$1
  case "$candidate" in /*) ;; *) exit 1;; esac
  count=0
  while [ -L "$candidate" ]; do
    count=$((count + 1)); [ "$count" -le 32 ] || exit 1
    target=$(/usr/bin/readlink "$candidate") || exit 1
    case "$target" in /*) candidate=$target;; *) candidate="${candidate%/*}/$target";; esac
  done
  case "$candidate" in */DesktopPet.app/Contents/MacOS/desktop-pet) ;; *) exit 1;; esac
  directory=$(CDPATH= cd -P "${candidate%/*}" && pwd) || exit 1
  app="${directory%/Contents/MacOS}"
  [ -f "$directory/desktop-pet" ] && [ -x "$directory/desktop-pet" ] || exit 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = io.github.hanbong5938.desktop-pet ] || exit 1
  /usr/bin/codesign --verify --deep --strict "$app" || exit 1
  [ -f "$directory/desktop-pet-update-coordinator" ] && [ -x "$directory/desktop-pet-update-coordinator" ] || exit 1
  printf 'candidate\n%s/desktop-pet\n' "$directory"
)
candidate=$(command -v desktop-pet || :)
if [ -n "$candidate" ] && signed_candidate "$candidate"; then exit 0; fi
brew=$(command -v brew || :)
case "$brew" in /opt/homebrew/bin/brew|/usr/local/bin/brew)
  prefix=$("$brew" --prefix desktop-pet 2>/dev/null || :)
  case "$prefix" in /*)
    if signed_candidate "$prefix/libexec/DesktopPet.app/Contents/MacOS/desktop-pet"; then exit 0; fi;;
  esac;;
esac
printf 'candidate\n%s/Applications/DesktopPet.app/Contents/MacOS/desktop-pet\n' "$home"
]]

local VERIFY_SCRIPT = [[
set -eu
fail() { printf '%s\n' "$*" >&2; exit 1; }
candidate=$1
helper_explicit=$2
case "$candidate" in /*) ;; *) fail "Executable must be absolute";; esac
# Follow a PATH symlink, but never execute a shell wrapper to discover the app.
count=0
while [ -L "$candidate" ]; do
  count=$((count + 1)); [ "$count" -le 32 ] || fail "Executable symlink loop"
  target=$(/usr/bin/readlink "$candidate")
  case "$target" in /*) candidate=$target;; *) candidate="${candidate%/*}/$target";; esac
done
case "$candidate" in */DesktopPet.app/Contents/MacOS/desktop-pet) ;;
  *) fail "Executable is not the signed Desktop Pet app; configure its absolute bundle executable";;
esac
directory=$(CDPATH= cd -P "${candidate%/*}" && pwd) || fail "Desktop Pet is absent or inaccessible"
candidate="$directory/desktop-pet"
app="${directory%/Contents/MacOS}"
[ -f "$candidate" ] && [ -x "$candidate" ] || fail "Desktop Pet executable is absent or inaccessible"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = io.github.hanbong5938.desktop-pet ] || fail "Not the neutral Desktop Pet bundle"
/usr/bin/codesign --verify --deep --strict "$app" || fail "Desktop Pet bundle signature is invalid"
helper="$directory/desktop-pet-update-coordinator"
[ -f "$helper" ] && [ -x "$helper" ] && [ ! -L "$helper" ] || fail "Missing paired Desktop Pet helper"
/usr/bin/codesign --verify --strict "$candidate" || fail "Invalid app signature"
/usr/bin/codesign --verify --strict "$helper" || fail "Invalid helper signature"
if [ -n "$helper_explicit" ]; then
  exec "$helper" discover --executable "$helper_explicit" --json
fi
exec "$helper" discover --json
]]

local function setup_process(argv, options, cx, current, ready)
	local started, message = pcall(function()
		tern.process.run(argv, options):next(function(result, err, fresh_cx)
			if not current(fresh_cx) then return end
			local ok, failure = pcall(function()
				if err ~= nil then error(tostring(err)) end
				if type(result) ~= "table" or result.timed_out then error("native discovery/profile query timed out") end
				if result.status ~= 0 then error("native discovery/profile query failed: " .. tostring(result.stderr):sub(1, 240)) end
				if type(result.stdout) ~= "string" or #result.stdout > SETUP_RESPONSE_BYTES then error("invalid or oversized native discovery/profile response") end
				ready(result.stdout, fresh_cx)
			end)
			if not ok then
				setup_pending = nil
				show_error(fresh_cx, tostring(failure) .. "\n" .. INSTALL_ADVICE)
			end
		end)
	end)
	if not started then
		setup_pending = nil
		show_error(cx, tostring(message) .. "\n" .. INSTALL_ADVICE)
	end
end

local function resolve_connection(explicit, paths, cx, current, ready)
	if explicit ~= nil and not absolute_path(explicit) then
		setup_pending = nil
		show_error(cx, "Executable must be absolute. " .. INSTALL_ADVICE)
		return
	end
	local options = { timeout_ms = SETUP_TIMEOUT_MS }
	setup_process({ "/bin/sh", "-c", DISCOVER_SCRIPT, "desktop-pet-discover", explicit or "" }, options, cx, current, function(stdout, discover_cx)
		local kind, payload = stdout:match("^([^\n]+)\n(.*)$")
		local candidate
		if kind == "locator" then
			local locator = tern.json.decode(payload)
			if type(locator) ~= "table" or locator.version ~= 1 or not absolute_path(locator.executable)
				or (locator.kind ~= "homebrew" and locator.kind ~= "standalone" and locator.kind ~= "source") then
				error("invalid installation locator; repair it rather than bypassing it")
			end
			for key in pairs(locator) do
				if key ~= "version" and key ~= "executable" and key ~= "kind" then error("unknown installation locator field") end
			end
			candidate = locator.executable
		elseif kind == "candidate" then
			candidate = payload:gsub("\n$", "")
		else error("invalid executable discovery response") end
		if not absolute_path(candidate) then error("invalid discovered executable") end
		-- Never execute a PATH wrapper. The helper rechecks the locator and
		-- discovery order itself unless the user explicitly chose an executable.
		setup_process({ "/bin/sh", "-c", VERIFY_SCRIPT, "desktop-pet-verify", candidate, explicit or "" }, options, discover_cx, current, function(proof_json, proof_cx)
			local proof = tern.json.decode(proof_json)
			if proof == nil or proof == NULL then error("Desktop Pet is not installed; install the common native app separately") end
			if type(proof) ~= "table" or proof.version ~= 1 or not absolute_path(proof.executable)
				or (proof.kind ~= "homebrew" and proof.kind ~= "standalone" and proof.kind ~= "source")
				or proof.integration_api ~= 1 then error("invalid native installation proof") end
			setup_process({ proof.executable, "update-capabilities" }, options, proof_cx, current, function(capability_json, capability_cx)
				local capability = tern.json.decode(capability_json)
				if type(capability) ~= "table" or capability.integration_api ~= 1 then
					error("native app does not support integration_api:1; upgrade Desktop Pet separately")
				end
				local argv = { proof.executable, "profile", "show", "--json" }
				local profile_options = { timeout_ms = SETUP_TIMEOUT_MS }
				if paths ~= nil then
					table.insert(argv, "--config-dir"); table.insert(argv, paths.config_dir)
					table.insert(argv, "--state-dir"); table.insert(argv, paths.state_dir)
					profile_options.env = { DESKTOP_PET_CONFIG_DIR = paths.config_dir, DESKTOP_PET_STATE_DIR = paths.state_dir }
				end
				setup_process(argv, profile_options, capability_cx, current, function(profile_json, profile_cx)
					local profile = tern.json.decode(profile_json)
					if type(profile) ~= "table" or profile.version ~= 1 then error("invalid native profile JSON") end
					for key in pairs(profile) do
						if key ~= "version" and key ~= "config_dir" and key ~= "state_dir" then error("unknown native profile field") end
					end
					local connection = validate_connection({ version = 1, executable = proof.executable,
						config_dir = profile.config_dir, state_dir = profile.state_dir })
					if paths ~= nil and (connection.config_dir ~= paths.config_dir or connection.state_dir ~= paths.state_dir) then
						error("native profile does not match both explicitly selected paths")
					end
					ready(connection, profile_cx)
				end)
			end)
		end)
	end)
end

local function resolve_migration(connection, cx, current, ready)
	-- Discovery locates the signed query transport, never grants route authority.
	-- Only native's authenticated committed approval may replace a legacy route.
	resolve_connection(nil, connection, cx, current, function(validated, proof_cx)
		setup_process({ validated.executable, "legacy-migration-route", "--config-dir", connection.config_dir,
			"--state-dir", connection.state_dir }, {
			timeout_ms = SETUP_TIMEOUT_MS,
			stdin = tern.json.encode({ version = 1, kind = "legacy-migration-route",
				executable = connection.executable, config_dir = connection.config_dir, state_dir = connection.state_dir }),
			env = { DESKTOP_PET_CONFIG_DIR = connection.config_dir, DESKTOP_PET_STATE_DIR = connection.state_dir },
		}, proof_cx, current, function(stdout, route_cx)
			local proof = tern.json.decode(stdout)
			if type(proof) ~= "table" or proof.version ~= 1 or proof.kind ~= "legacy-migration-route"
				or proof.committed ~= true then error("native migration route is not committed and approved") end
			for key in pairs(proof) do
				if key ~= "version" and key ~= "kind" and key ~= "committed" and key ~= "original" and key ~= "target" then
					error("unknown native migration route proof field")
				end
			end
			local original, target = validate_connection(proof.original), validate_connection(proof.target)
			if not same_connection(original, connection) then error("native migration proof does not match the exact saved original route") end
			if not same_connection(target, validated) then error("native migration proof does not match the verified target and original profile pair") end
			ready(target, route_cx)
		end)
	end)
end

local function build_inventory(hosts, panes, tabs, sessions, agents)
	if not is_array(hosts) or not is_array(panes) or not is_array(tabs)
		or not is_array(sessions) or not is_array(agents) then
		error("Tern agent inventory is unavailable")
	end
	if #hosts > MAX_HOSTS then error("Tern host inventory exceeds the exchange limit") end
	local inventory = tern.json.array()
	local records, pane_host = {}, {}
	local local_hosts, first_error = 0, nil
	local function unavailable(record, message)
		if record.snapshot.status ~= "disconnected" then record.snapshot.status = "unavailable" end
		first_error = first_error or ("Tern host " .. record.snapshot.label .. " inventory unavailable: " .. message)
	end
	for _, host in ipairs(hosts) do
		if type(host) ~= "table" or (host.kind ~= "local" and host.kind ~= "remote") then
			error("Tern returned invalid host identity or locality")
		end
		local key = id_string(host.id)
		if records[key] ~= nil then error("Tern returned duplicate host ids") end
		local is_local = host.kind == "local"
		if is_local then local_hosts += 1 end
		local label = type(host.name) == "string" and host.name ~= "" and host.name or key
		local record = {
			kind = host.kind, address = host.address, panes = {}, seen_agents = {},
			snapshot = { host = key, label = label, is_local = is_local,
				status = host.state == "connected" and "available" or "disconnected", agents = tern.json.array() },
		}
		records[key] = record
		table.insert(inventory, record.snapshot)
		if type(host.name) ~= "string" or #host.name > MAX_FIELD_BYTES then
			record.snapshot.label = key
			unavailable(record, "invalid host name")
		end
		if host.state ~= "connected" and host.state ~= "connecting" and host.state ~= "stalled"
			and host.state ~= "verify" and host.state ~= "reconnecting" and host.state ~= "failed" then
			record.snapshot.status = "unavailable"
			unavailable(record, "invalid host connection state")
		end
		if host.address ~= nil and (type(host.address) ~= "string" or #host.address > MAX_FIELD_BYTES) then
			error("Tern returned invalid host address")
		end
		if not is_array(host.panes) then
			unavailable(record, "host pane membership is unavailable")
		else
			for _, id in ipairs(host.panes) do
				if not valid_id(id) then
					unavailable(record, "invalid host pane membership")
				else
					local pane = id_string(id)
					if record.panes[pane] then unavailable(record, "duplicate host pane membership") end
					record.panes[pane] = true
					local previous = pane_host[pane]
					if previous ~= nil and previous ~= record then
						unavailable(record, "pane belongs to multiple hosts")
						if previous ~= false then unavailable(previous, "pane belongs to multiple hosts") end
						pane_host[pane] = false
					else
						pane_host[pane] = record
					end
				end
			end
		end
	end
	if local_hosts ~= 1 then error("expected exactly one local Tern host") end
	local pane_info = {}
	for _, pane in ipairs(panes) do
		if type(pane) ~= "table" then error("Tern returned invalid pane metadata") end
		local key = id_string(pane.pane)
		if pane_info[key] ~= nil then
			pane_info[key] = false
			if pane_host[key] then unavailable(pane_host[key], "duplicate Tern pane id") end
		else
			pane_info[key] = pane
		end
	end
	local tab_info = {}
	for _, tab in ipairs(tabs) do
		if type(tab) ~= "table" then error("Tern returned invalid tab metadata") end
		local key = id_string(tab.id)
		tab_info[key] = tab_info[key] == nil and tab or false
	end
	local tab_session, session_tabs = {}, {}
	for _, session in ipairs(sessions) do
		if type(session) ~= "table" then error("Tern returned invalid session metadata") end
		local sid = id_string(session.id)
		local previous = session_tabs[sid]
		if previous ~= nil then
			for _, key in ipairs(previous) do tab_session[key] = false end
		end
		local keys = {}
		local complete = is_array(session.tabs)
		if complete then
			for _, tid in ipairs(session.tabs) do
				if valid_id(tid) then table.insert(keys, id_string(tid))
				else complete = false end
			end
		end
		for _, key in ipairs(keys) do
			if not complete or previous ~= nil or tab_session[key] ~= nil then
				tab_session[key] = false
			else
				tab_session[key] = { id = sid, label = session.name }
			end
		end
		session_tabs[sid] = previous or keys
	end
	for _, agent in ipairs(agents) do
		if type(agent) ~= "table" then error("Tern returned invalid agent metadata") end
		local key = id_string(agent.pane)
		local record = pane_host[key]
		if record == nil then
			-- agents:list precedes final membership. A disappearing remote pane
			-- remains remote; never assign an orphan to the local host.
			local known = false
			for host, previous in pairs(observed_hosts) do
				if previous.panes[key] then
					known = true
					if records[host] ~= nil then unavailable(records[host], "agent pane disappeared during inventory") end
				end
			end
			if not known then error("Tern agent has no trustworthy host membership") end
		elseif record ~= false then
			if record.seen_agents[key] then unavailable(record, "duplicate agent pane") end
			record.seen_agents[key] = true
			if record.snapshot.status == "available" then
				local complete, row = pcall(function()
					if #record.snapshot.agents >= MAX_AGENTS then error("host agent inventory exceeds the exchange limit") end
					local pane = pane_info[key]
					if not pane or type(pane.title) ~= "string" or type(agent.cwd) ~= "string" then
						error("agent is missing pane metadata")
					end
					if #pane.title > MAX_FIELD_BYTES or #agent.cwd > MAX_FIELD_BYTES then
						error("agent metadata exceeds the exchange limit")
					end
					local state = agent.state
					if state ~= "idle" and state ~= "working" and state ~= "waiting_input" and state ~= "exited" then
						error("Tern returned an unknown agent state")
					end
					local tab_id = optional_id(pane.tab)
					local tab = pane.tab ~= nil and tab_info[id_string(pane.tab)] or nil
					local session = pane.tab ~= nil and tab_session[id_string(pane.tab)] or nil
					if pane.tab ~= nil and (not tab or not session) then
						error("agent tab or session membership is missing or ambiguous")
					end
					return {
						pane = key, title = pane.title, cwd = agent.cwd,
						session_id = session ~= nil and session.id or NULL,
						session_label = session ~= nil and optional_string(session.label) or NULL,
						tab_id = tab_id, tab_label = tab ~= nil and optional_string(tab.name) or NULL,
						state = state, delivery_error = optional_string(agent.delivery_error),
					}
				end)
				if complete then table.insert(record.snapshot.agents, row)
				else unavailable(record, tostring(row)) end
			end
		end
	end
	-- Validate all generations before committing high-water marks. A failed
	-- whole inventory cannot masquerade as a successfully observed loss.
	for _, snapshot in ipairs(inventory) do
		local record, previous = records[snapshot.host], observed_hosts[snapshot.host]
		local generation = previous ~= nil and previous.generation or 1
		if previous ~= nil and (previous.kind ~= record.kind or previous.address ~= record.address
			or (snapshot.status == "available" and not previous.available)) then
			if generation >= MAX_SAFE_ID then error("Tern host observation generation is exhausted") end
			generation += 1
		end
		snapshot.observation_generation = generation
		if snapshot.status ~= "available" then snapshot.agents = tern.json.array() end
	end
	for host, previous in pairs(observed_hosts) do
		if records[host] == nil then previous.available = false end
	end
	local reply_by_pane, current_local = {}, nil
	for _, snapshot in ipairs(inventory) do
		local record = records[snapshot.host]
		local previous = observed_hosts[snapshot.host]
		local known_panes = record.panes
		if snapshot.status ~= "available" and previous ~= nil then
			known_panes = previous.panes
			for pane in pairs(record.panes) do known_panes[pane] = true end
		end
		observed_hosts[snapshot.host] = { generation = snapshot.observation_generation,
			kind = record.kind, address = record.address, panes = known_panes,
			available = snapshot.status == "available" }
		if snapshot.is_local then
			current_local = { host = snapshot.host, observation_generation = snapshot.observation_generation }
			if snapshot.status == "available" then
				for _, row in ipairs(snapshot.agents) do
					reply_by_pane[row.pane] = { id = tonumber(row.pane), row = row,
						host = snapshot.host, observation_generation = snapshot.observation_generation,
						is_local = true, connected = true }
				end
			end
		end
	end
	if local_identity ~= nil and (local_identity.host ~= current_local.host
		or local_identity.observation_generation ~= current_local.observation_generation) then
		results = tern.json.array()
		results_identity = nil
	end
	local_identity = current_local
	return inventory, reply_by_pane, first_error
end

local function same_target(a, b)
	return a ~= nil and b ~= nil and a.is_local and b.is_local and a.connected and b.connected
		and a.host == b.host and a.observation_generation == b.observation_generation
		and a.row.pane == b.row.pane and a.row.session_id == b.row.session_id and a.row.tab_id == b.row.tab_id
		and a.row.title == b.row.title and a.row.cwd == b.row.cwd
end

local function reset_identity()
	incarnation += 1
	window, epoch = new_identity()
	sequence = 0
	instance_id = nil
	observed_hosts = {}
	native_generations = {}
	local_identity = nil
	results_identity = nil
	results = tern.json.array()
	busy = false
	active_exchange = nil
	last_error = nil
	setup_pending = nil
end

local function refresh_connection()
	local storage = stored_identity()
	if active_storage ~= nil and storage ~= active_storage then
		-- Retire old work before validating another window's atomic route save.
		-- The next tick validates that exact executable, never a substitute.
		reset_identity()
		active_connection = nil
		active_storage = nil
		setup_serial += 1
		automatic_reconnect = true
	end
	if active_connection == nil then error("Use Connect or Configure to validate the native connection. " .. INSTALL_ADVICE) end
	return active_connection
end

local function finish_exchange(data)
	if data.incarnation == incarnation and active_exchange == data then
		active_exchange = nil
		busy = false
	end
end

local function current_exchange(data, cx)
	if data.incarnation ~= incarnation or active_exchange ~= data then
		return false
	end
	local loaded, connection = pcall(refresh_connection)
	if data.incarnation ~= incarnation or active_exchange ~= data then
		return false
	end
	if not loaded then
		finish_exchange(data)
		show_error(cx, tostring(connection))
		return false
	end
	return true
end

-- Inventory calls synchronously cross to the window thread. Zero-delay
-- awaitables split that work without the coarse timer's scheduling delay.
-- Keep the potentially large agent payload separate; membership and panes last.
local function collect_inventory(data, cx, ready, failed)
	local tabs, sessions, agents
	local stage = 0
	local phase = data.phase
	local function fail(fresh_cx, message)
		if not current_exchange(data, fresh_cx) then
			return
		end
		local reported, report_error = pcall(function()
			if failed ~= nil then
				failed(fresh_cx, tostring(message))
			else
				show_error(fresh_cx, tostring(message))
			end
		end)
		finish_exchange(data)
		if not reported then
			show_error(fresh_cx, tostring(report_error))
		end
	end
	local function step(_value, err, fresh_cx)
		if data.phase ~= phase then
			return
		end
		local ok, message = pcall(function()
			if not current_exchange(data, fresh_cx) then
				return
			end
			if err ~= nil then
				error("Tern inventory continuation failed: " .. tostring(err))
			end
			if fresh_cx == nil then
				finish_exchange(data)
				return
			end
			stage += 1
			if stage == 1 then
				tabs = fresh_cx.session:tabs()
			elseif stage == 2 then
				sessions = fresh_cx.session:sessions()
			elseif stage == 3 then
				agents = fresh_cx.agents:list()
			else
				local hosts = fresh_cx.hosts:list()
				local panes = fresh_cx.session:panes()
				if not current_exchange(data, fresh_cx) then
					return
				end
				local inventory, reply_by_pane, inventory_error = build_inventory(hosts, panes, tabs, sessions, agents)
				ready(fresh_cx, inventory, reply_by_pane, inventory_error)
				return
			end
			if data.incarnation == incarnation and active_exchange == data then
				tern.sleep(0):next(step)
			end
		end)
		if not ok then
			fail(fresh_cx, message)
		end
	end
	local scheduled, message = pcall(function()
		tern.sleep(0):next(step)
	end)
	if not scheduled then
		fail(cx, message)
	end
end

local exchange

local function report_command(data, command, accepted, failure, cx)
	if not current_exchange(data, cx) then return end
	finish_exchange(data)
	if local_identity ~= nil and local_identity.host == data.local_host
		and local_identity.observation_generation == data.local_observation_generation then
		if #failure > MAX_FIELD_BYTES then
			failure = "Tern semantic ask failed (error details exceed the exchange limit)"
		end
		results_identity = { host = data.local_host, observation_generation = data.local_observation_generation,
			generation = data.local_generation }
		table.insert(results, { operation_id = command.operation_id, pane = command.pane,
			status = accepted and "accepted" or "failed", error = accepted and NULL or failure })
	else
		failure = "local Tern host generation changed; pending reply has unknown delivery"
		accepted = false
	end
	-- Always report through a fresh full-window inventory, never an ask retry.
	exchange(cx)
	if not accepted then show_error(cx, failure) end
end

local function revalidate_command(data, command, cx)
	local target = data.reply_by_pane[command.pane]
	local failure = "agent is no longer the selected local pane"
	if target == nil or not target.is_local or not target.connected
		or target.host ~= data.local_host or target.observation_generation ~= data.local_observation_generation
		or cx == nil or type(cx.agents.ask) ~= "function" then
		if cx ~= nil and type(cx.agents.ask) ~= "function" then
			failure = "this Tern window does not support semantic agent asks"
		end
		report_command(data, command, false, failure, cx)
		return false
	end
	data.phase = "revalidate"
	collect_inventory(data, cx, function(fresh_cx, _hosts, fresh)
		local current = fresh[command.pane]
		local accepted = false
		if type(fresh_cx.agents.ask) ~= "function" then
			failure = "this Tern window does not support semantic agent asks"
		elseif same_target(target, current) and current.row.state ~= "exited"
			and current.row.delivery_error == NULL then
			local ask_ok, ask_error = pcall(function()
				fresh_cx.agents:get(current.id)
				fresh_cx.agents:ask(current.id, command.text)
			end)
			accepted = ask_ok
			if not ask_ok then failure = tostring(ask_error) end
		end
		report_command(data, command, accepted, failure, fresh_cx)
	end, function(fresh_cx, message)
		report_command(data, command, false, "Tern inventory could not be revalidated: " .. message, fresh_cx)
	end)
	return true
end

local ERROR_CODES = {
	binding_required = true, instance_changed = true, source_retired = true,
	receipt_rejected = true, rejected = true,
}

local function validate_response(response, data)
	if type(response.ok) ~= "boolean" or type(response.instance_id) ~= "string"
		or response.instance_id == "" or #response.instance_id > MAX_FIELD_BYTES
		or not is_array(response.hosts) or response.generation ~= nil then
		error("invalid exchange v2 native response")
	end
	if response.error ~= nil and response.error ~= NULL
		and (type(response.error) ~= "string" or #response.error > MAX_FIELD_BYTES) then
		error("invalid native response error")
	end
	if response.error_code ~= nil and not ERROR_CODES[response.error_code] then
		error("invalid native response error code")
	end
	local expected = response.ok and #data.hosts or 0
	if #response.hosts ~= expected then error("native response host count does not match the request") end
	local requested, replies = {}, {}
	for _, host in ipairs(data.hosts) do requested[host.host] = host end
	for index, reply in pairs(response.hosts) do
		if not valid_id(index) or index < 1 or index > expected or type(reply) ~= "table"
			or type(reply.host) ~= "string" or requested[reply.host] == nil or replies[reply.host] ~= nil
			or not valid_id(reply.observation_generation) or reply.observation_generation < 1
			or reply.observation_generation ~= requested[reply.host].observation_generation
			or not valid_id(reply.generation) then
			error("invalid native host response identity or generation")
		end
		if reply.error ~= nil and reply.error ~= NULL
			and (type(reply.error) ~= "string" or #reply.error > MAX_HOST_ERROR_BYTES) then
			error("invalid native host response error")
		end
		if reply.error_code ~= nil and not ERROR_CODES[reply.error_code] then
			error("invalid native host response error code")
		end
		replies[reply.host] = reply
	end
	local command = response.command
	if command ~= nil and command ~= NULL then
		if not response.ok or type(command) ~= "table" or type(command.operation_id) ~= "string"
			or command.operation_id == "" or #command.operation_id > MAX_FIELD_BYTES
			or type(command.pane) ~= "string" or not valid_id(tonumber(command.pane))
			or id_string(tonumber(command.pane)) ~= command.pane or type(command.text) ~= "string" then
			error("invalid desktop pet command")
		end
	end
	return replies
end

exchange = function(cx)
	if cx == nil then
		return
	end
	-- Other windows share KV. Detect a whole-profile change even while old work
	-- is busy, so neither its snapshot nor its command can enter the new profile.
	local loaded, connection = pcall(refresh_connection)
	if not loaded then
		active_exchange = nil
		busy = false
		show_error(cx, tostring(connection))
		return
	end
	if busy then
		return
	end
	local data = { incarnation = incarnation, instance_id = instance_id, phase = "inventory" }
	-- Inventory is already work: event bursts must not start another collection.
	busy = true
	active_exchange = data
	collect_inventory(data, cx, function(fresh_cx, hosts, reply_by_pane, inventory_error)
		if sequence >= MAX_SAFE_ID then
			error("desktop pet sequence is exhausted")
		end
		sequence += 1
		if results_identity ~= nil and (results_identity.host ~= local_identity.host
			or results_identity.observation_generation ~= local_identity.observation_generation
			or results_identity.generation ~= native_generations[local_identity.host]) then
			results = tern.json.array()
			results_identity = nil
		end
		data.reports = results
		data.reply_by_pane = reply_by_pane
		data.hosts = hosts
		data.inventory_error = inventory_error
		data.local_host = local_identity.host
		data.local_observation_generation = local_identity.observation_generation
		data.local_generation = native_generations[data.local_host]
		local request = tern.json.encode({
			version = 2,
			kind = "tern",
			window = window,
			epoch = epoch,
			sequence = sequence,
			instance_id = instance_id or NULL,
			hosts = hosts,
			results = data.reports,
		})
		if #request > MAX_REQUEST_BYTES then
			error("desktop pet inventory exceeds the exchange limit")
		end
		local argv = { connection.executable, "tern-exchange", "--config-dir", connection.config_dir,
			"--state-dir", connection.state_dir }
		data.phase = "process"
		tern.process.run(argv, {
			stdin = request,
			timeout_ms = PROCESS_TIMEOUT_MS,
			-- Neutral environment and explicit arguments always select the same pair.
			env = { DESKTOP_PET_CONFIG_DIR = connection.config_dir, DESKTOP_PET_STATE_DIR = connection.state_dir },
		}):next(function(result, process_error, response_cx)
			if data.phase ~= "process" or not current_exchange(data, response_cx) then
				return
			end
			-- Consume this completion before staging a one-shot command. A repeated
			-- callback cannot schedule another ask while revalidation is pending.
			data.phase = "response"
			local succeeded, pending = pcall(function()
				if process_error ~= nil then error("native exchange failed: " .. tostring(process_error)) end
				if type(result) ~= "table" then error("invalid native exchange process result") end
				if result.timed_out then
					error("native exchange timed out")
				end
				if type(result.stdout) ~= "string" or #result.stdout > MAX_RESPONSE_BYTES then
					error("native exchange response is too large")
				end
				local decoded, response = pcall(tern.json.decode, result.stdout)
				if not decoded or type(response) ~= "table" then
					error("native exchange failed: " .. tostring(result.stderr):sub(1, 240))
				end
				local host_replies = validate_response(response, data)
				if type(response.instance_id) == "string" and response.instance_id ~= ""
					and data.instance_id ~= nil and response.instance_id ~= data.instance_id then
					-- A daemon restart invalidates reports and all old source identities.
					reset_identity()
					show_error(response_cx, "desktop pet restarted; pending replies have unknown delivery")
					return
				end
				if response.ok == false and type(response.instance_id) == "string" and response.instance_id ~= "" then
					if response.error_code == "binding_required" or response.error_code == "source_retired"
						or response.error_code == "instance_changed" then
						-- Do not replay an uncertain ask. A fresh result-free source registers
						-- on the next ordinary full-snapshot poll.
						reset_identity()
						show_error(response_cx, "desktop pet source must reconnect; pending replies have unknown delivery")
						return
					elseif response.error_code == "receipt_rejected" and data.instance_id ~= nil
						and response.instance_id == data.instance_id and data.local_generation ~= nil then
						if results == data.reports then
							results = tern.json.array()
							results_identity = nil
						end
						error("desktop pet could not confirm a previous command result")
					end
				end
				if result.status ~= 0 or response.ok ~= true then
					error(type(response.error) == "string" and response.error or "native exchange rejected")
				end
				instance_id = response.instance_id
				local local_reply = host_replies[data.local_host]
				local scoped_error = data.inventory_error
				local local_error = nil
				for _, host in ipairs(data.hosts) do
					local reply = host_replies[host.host]
					if reply.error ~= nil and reply.error ~= NULL then
						scoped_error = scoped_error or ("Tern host " .. host.label .. ": " .. reply.error)
						if host.is_local then local_error = reply.error end
					else
						native_generations[host.host] = reply.generation
					end
				end
				if data.local_generation ~= nil and local_reply.generation ~= data.local_generation then
					if results == data.reports then
						results = tern.json.array()
						results_identity = nil
					end
					show_error(response_cx, "local Tern host generation changed; pending replies have unknown delivery")
					return
				end
				data.local_generation = local_reply.generation
				-- Remote admission/errors are independent of the local receipt.
				if (local_error == nil or local_reply.error_code == "receipt_rejected") and results == data.reports then
					results = tern.json.array()
					results_identity = nil
				end
				if scoped_error ~= nil then show_error(response_cx, scoped_error)
				else show_connected(response_cx) end
				local command = response.command
				if command ~= nil and command ~= NULL then
					if local_error ~= nil or local_reply.generation == 0 then
						error("desktop pet offered a command for an unavailable local host")
					end
					return revalidate_command(data, command, response_cx)
				end
			end)
			if not succeeded then
				if data.incarnation == incarnation and active_exchange == data then
					finish_exchange(data)
					show_error(response_cx, tostring(pending))
				end
			elseif not pending then
				finish_exchange(data)
			end
		end)
	end)
end

local function setup_guard(cx)
	setup_serial += 1
	setup_pending = nil
	local serial, source = setup_serial, incarnation
	local captured, storage = pcall(stored_identity)
	if not captured then show_error(cx, tostring(storage)); return nil end
	setup_pending = serial
	return function(fresh_cx)
		if serial ~= setup_serial or source ~= incarnation then return false end
		if fresh_cx == nil then setup_pending = nil; return false end
		local checked, now = pcall(stored_identity)
		if not checked then setup_pending = nil; show_error(fresh_cx, tostring(now)); return false end
		if now ~= storage then
			-- Another window won. Fence prompts, discovery and offered commands.
			pcall(refresh_connection)
			setup_pending = nil
			automatic_reconnect = true
			return false
		end
		return true
	end, storage
end

local function save_connection(candidate, validated, cx, current)
	if not current(cx) then return end
	local saved, message = pcall(tern.kv.set, "connection", candidate)
	setup_pending = nil
	if not saved then show_error(cx, "could not save desktop pet connection: " .. tostring(message)); return end
	-- One atomic save is the cutover. Retire all old work and uncertain reports.
	reset_identity()
	setup_serial += 1
	active_connection = validated
	cleanup_legacy()
	active_storage = tern.json.encode({ connection = candidate })
	automatic_reconnect = false
	exchange(cx)
	return true
end

local function connect(cx)
	if cx == nil then return end
	if active_connection ~= nil then pcall(refresh_connection) end
	local current, storage = setup_guard(cx)
	if current == nil then return end
	local loaded, connection = pcall(settings)
	if not loaded then setup_pending = nil; show_error(cx, tostring(connection) .. "\n" .. INSTALL_ADVICE); return end
	if connection ~= nil and legacy_executable(connection.executable) then
		resolve_migration(connection, cx, current, function(target, fresh_cx)
			save_connection(target, target, fresh_cx, current)
		end)
		return
	end
	if active_connection ~= nil and active_storage == storage then setup_pending = nil; exchange(cx); return end
	resolve_connection(connection and connection.executable or nil, connection, cx, current, function(validated, fresh_cx)
		setup_pending = nil
		reset_identity()
		active_connection, active_storage = validated, storage
		automatic_reconnect = false
		exchange(fresh_cx)
	end)
end

local function configure(cx)
	if active_connection ~= nil then pcall(refresh_connection) end
	local current = setup_guard(cx)
	if current == nil then return end
	local loaded, connection = pcall(settings)
	if not loaded then connection = nil end
	-- Custom executables remain the proposal. Only legacy Herdr executables
	-- propose neutral discovery, preserving BOTH existing paths.
	local explicit = connection and not legacy_executable(connection.executable) and connection.executable or nil
	local function prompt_connection(proposal, proposal_cx)
		local function continuation(callback)
			return function(value, err, fresh_cx)
				if not current(fresh_cx) then return end
				if err ~= nil then setup_pending = nil; show_error(fresh_cx, tostring(err)); return end
				if value == nil then setup_pending = nil; return end
				local ok, message = pcall(callback, value, fresh_cx)
				if not ok then setup_pending = nil; show_error(fresh_cx, tostring(message) .. "\n" .. INSTALL_ADVICE) end
			end
		end
		proposal_cx:prompt({ value = proposal.executable, placeholder = "Absolute Desktop Pet executable" }):next(continuation(function(new_executable, executable_cx)
			executable_cx:prompt({ value = proposal.config_dir, placeholder = "Absolute desktop pet config directory" }):next(continuation(function(new_config, config_cx)
				config_cx:prompt({ value = proposal.state_dir, placeholder = "Absolute desktop pet state directory" }):next(continuation(function(new_state, state_cx)
					local candidate = validate_connection({ version = 1, executable = new_executable, config_dir = new_config, state_dir = new_state })
					resolve_connection(candidate.executable, candidate, state_cx, current, function(validated, save_cx)
						if save_connection(candidate, validated, save_cx, current) then
							save_cx:toast("info", "Desktop pet connection saved")
						end
					end)
				end))
			end))
		end))
	end
	if explicit ~= nil then
		-- Let a user repair an absent/invalid custom executable; never substitute
		-- a discovered executable for it. Final save still requires full proof.
		prompt_connection(connection, cx)
	else
		resolve_connection(nil, connection, cx, current, prompt_connection)
	end
end

local function tick(cx)
	timer = tern.timer(INTERVAL_MS, tick)
	if active_connection ~= nil then
		local loaded, message = pcall(refresh_connection)
		if loaded then exchange(cx); return end
		if active_connection ~= nil then show_error(cx, tostring(message)); return end
	end
	if setup_pending ~= nil then return end
	if automatic_reconnect then
		automatic_reconnect = false
		connect(cx)
		return
	end
	local loaded, connection = pcall(settings)
	if not loaded then show_error(cx, tostring(connection)); return end
	if connection ~= nil and legacy_executable(connection.executable) then connect(cx) end
end

-- Repeating discovery is limited to legacy routes awaiting committed native
-- approval. Saved-route changes validate the exact replacement before polling.
tern.on("window_start", connect)
for _, event in ipairs({ "pane_created", "pane_closed", "tab_created", "tab_closed",
	"command_started", "command_finished", "cwd", "title" }) do
	tern.on(event, function(_event, cx)
		if active_connection ~= nil then exchange(cx) end
	end)
end
tern.command({ id = "connect", title = "Connect to desktop pet", run = connect })
tern.command({ id = "configure", title = "Configure desktop pet connection", run = configure })
timer = tern.timer(1, function(cx)
	timer = tern.timer(INTERVAL_MS, tick)
	connect(cx)
end)
