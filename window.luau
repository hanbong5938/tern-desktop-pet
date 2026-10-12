-- The window VM is the only source of Tern agent facts and semantic asks.
-- No host half, PTY writes, OMP extension, or agent-completion inference.
local MAX_AGENTS = 128
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
local generation = nil
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

local function home_dir()
	local home = tern.getenv("HOME")
	if type(home) ~= "string" or home:sub(1, 1) ~= "/" then
		error("HOME is not an absolute path; configure desktop pet paths explicitly")
	end
	return home
end

local function default_dir(variable, suffix, home_suffix)
	local root = tern.getenv(variable)
	if type(root) == "string" and root ~= "" then
		if root:sub(1, 1) ~= "/" then
			error(variable .. " is not an absolute path")
		end
		return root .. suffix
	end
	return home_dir() .. home_suffix
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
	if type(executable) ~= "string" or executable == "" or executable:find("%z") then
		error("configure a nonempty desktop pet executable")
	end
	if type(config_dir) ~= "string" or config_dir:sub(1, 1) ~= "/" or config_dir:find("%z") then
		error("configure an absolute desktop pet config directory")
	end
	if type(state_dir) ~= "string" or state_dir:sub(1, 1) ~= "/" or state_dir:find("%z") then
		error("configure an absolute desktop pet state directory")
	end
	return { version = 1, executable = executable, config_dir = config_dir, state_dir = state_dir }
end

local function default_connection()
	return validate_connection({
		version = 1,
		executable = "herdr-desktop-pet",
		config_dir = default_dir("XDG_CONFIG_HOME", "/herdr/plugins/config/desktop-pet", "/.config/herdr/plugins/config/desktop-pet"),
		state_dir = default_dir("XDG_STATE_HOME", "/herdr/plugins/desktop-pet", "/.local/state/herdr/plugins/desktop-pet"),
	})
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

local function settings()
	local connection = tern.kv.get("connection")
	if connection ~= nil then
		-- A malformed canonical object is not permission to resurrect old keys.
		return validate_connection(connection)
	end
	local executable = tern.kv.get("executable")
	local config_dir = tern.kv.get("config_dir")
	local state_dir = tern.kv.get("state_dir")
	connection = validate_connection({
		version = 1,
		executable = executable == nil and "herdr-desktop-pet" or executable,
		config_dir = config_dir == nil and default_dir("XDG_CONFIG_HOME", "/herdr/plugins/config/desktop-pet", "/.config/herdr/plugins/config/desktop-pet") or config_dir,
		state_dir = state_dir == nil and default_dir("XDG_STATE_HOME", "/herdr/plugins/desktop-pet", "/.local/state/herdr/plugins/desktop-pet") or state_dir,
	})
	-- Another window may have completed adoption while the old keys were read.
	local adopted = tern.kv.get("connection")
	if adopted ~= nil then
		return validate_connection(adopted)
	end
	-- All three legacy values are adopted together, before any live cutover.
	tern.kv.set("connection", connection)
	cleanup_legacy()
	return connection
end

local function build_inventory(hosts, panes, tabs, sessions, agents)
	if type(hosts) ~= "table" or type(panes) ~= "table" or type(tabs) ~= "table"
		or type(sessions) ~= "table" or type(agents) ~= "table" then
		error("Tern agent inventory is unavailable")
	end
	local local_panes = {}
	local local_hosts = 0
	for _, host in ipairs(hosts) do
		if host.kind == "local" then
			local_hosts += 1
			if type(host.panes) ~= "table" then
				error("local host pane membership is unavailable")
			end
			for _, id in ipairs(host.panes) do
				local key = id_string(id)
				if local_panes[key] then
					error("duplicate local pane membership")
				end
				local_panes[key] = true
			end
		end
	end
	if local_hosts ~= 1 then
		error("expected exactly one local Tern host")
	end
	local pane_info = {}
	for _, pane in ipairs(panes) do
		local key = id_string(pane.pane)
		if pane_info[key] then
			error("duplicate Tern pane id")
		end
		pane_info[key] = pane
	end
	local tab_info = {}
	for _, tab in ipairs(tabs) do
		local key = id_string(tab.id)
		if tab_info[key] then
			error("duplicate Tern tab id")
		end
		tab_info[key] = tab
	end
	local tab_session = {}
	for _, session in ipairs(sessions) do
		local sid = id_string(session.id)
		if type(session.tabs) ~= "table" then
			error("Tern session tab membership is unavailable")
		end
		for _, tid in ipairs(session.tabs) do
			local key = id_string(tid)
			if tab_session[key] then
				error("ambiguous Tern tab session")
			end
			tab_session[key] = { id = sid, label = session.name }
		end
	end
	local rows = tern.json.array()
	local by_pane = {}
	for _, agent in ipairs(agents) do
		local key = id_string(agent.pane)
		if local_panes[key] then
			if #rows >= MAX_AGENTS or by_pane[key] then
				error("local agent inventory is too large or contains duplicate panes")
			end
			local pane = pane_info[key]
			if pane == nil or type(pane.title) ~= "string" or type(agent.cwd) ~= "string" then
				error("local agent is missing pane metadata")
			end
			if #pane.title > MAX_FIELD_BYTES or #agent.cwd > MAX_FIELD_BYTES then
				error("local agent metadata exceeds the exchange limit")
			end
			local state = agent.state
			if state ~= "idle" and state ~= "working" and state ~= "waiting_input" and state ~= "exited" then
				error("Tern returned an unknown agent state")
			end
			local tab_id = optional_id(pane.tab)
			local tab = pane.tab ~= nil and tab_info[id_string(pane.tab)] or nil
			local session = pane.tab ~= nil and tab_session[id_string(pane.tab)] or nil
			if pane.tab ~= nil and (tab == nil or session == nil) then
				error("agent tab is missing from Tern inventory")
			end
			local row = {
				pane = key,
				title = pane.title,
				cwd = agent.cwd,
				session_id = session ~= nil and session.id or NULL,
				session_label = session ~= nil and optional_string(session.label) or NULL,
				tab_id = tab_id,
				tab_label = tab ~= nil and optional_string(tab.name) or NULL,
				state = state,
				delivery_error = optional_string(agent.delivery_error),
			}
			table.insert(rows, row)
			by_pane[key] = { id = agent.pane, row = row }
		end
	end
	return rows, by_pane
end

local function same_target(a, b)
	return a ~= nil and b ~= nil and a.row.pane == b.row.pane
		and a.row.session_id == b.row.session_id and a.row.tab_id == b.row.tab_id
		and a.row.title == b.row.title and a.row.cwd == b.row.cwd
end

local function reset_identity()
	incarnation += 1
	window, epoch = new_identity()
	sequence = 0
	instance_id = nil
	generation = nil
	results = tern.json.array()
	busy = false
	active_exchange = nil
	last_error = nil
end

local function refresh_connection()
	local connection = settings()
	if active_connection == nil then
		active_connection = connection
	elseif not same_connection(active_connection, connection) then
		active_connection = connection
		reset_identity()
	end
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
				local rows, by_pane = build_inventory(hosts, panes, tabs, sessions, agents)
				ready(fresh_cx, rows, by_pane)
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
	if not current_exchange(data, cx) then
		return
	end
	finish_exchange(data)
	if #failure > MAX_FIELD_BYTES then
		failure = "Tern semantic ask failed (error details exceed the exchange limit)"
	end
	table.insert(results, { operation_id = command.operation_id, pane = command.pane,
		status = accepted and "accepted" or "failed", error = accepted and NULL or failure })
	-- Flush the receipt through an ordinary fresh full snapshot, not a cached
	-- inventory or an ask retry. The old work cannot clear this new collection.
	exchange(cx)
	if not accepted then
		show_error(cx, failure)
	end
end

local function revalidate_command(data, command, cx)
	local target = data.by_pane[command.pane]
	local failure = "agent is no longer the selected local pane"
	if target == nil or cx == nil or type(cx.agents.ask) ~= "function" then
		if cx ~= nil and type(cx.agents.ask) ~= "function" then
			failure = "this Tern window does not support semantic agent asks"
		end
		report_command(data, command, false, failure, cx)
		return false
	end
	data.phase = "revalidate"
	collect_inventory(data, cx, function(fresh_cx, _rows, fresh)
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
			if not ask_ok then
				failure = tostring(ask_error)
			end
		end
		report_command(data, command, accepted, failure, fresh_cx)
	end, function(fresh_cx, message)
		report_command(data, command, false, "Tern inventory could not be revalidated: " .. message, fresh_cx)
	end)
	return true
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
	local data = { incarnation = incarnation,
		instance_id = instance_id, generation = generation, phase = "inventory" }
	-- Inventory is already work: event bursts must not start another collection.
	busy = true
	active_exchange = data
	collect_inventory(data, cx, function(fresh_cx, agents, by_pane)
		if sequence >= MAX_SAFE_ID then
			error("desktop pet sequence is exhausted")
		end
		sequence += 1
		data.reports = results
		data.by_pane = by_pane
		local request = tern.json.encode({
			version = 1,
			kind = "tern",
			window = window,
			epoch = epoch,
			sequence = sequence,
			instance_id = instance_id or NULL,
			agents = agents,
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
			-- Explicit profile paths win over inherited Herdr plugin variables.
			env = { HERDR_PLUGIN_CONFIG_DIR = connection.config_dir, HERDR_PLUGIN_STATE_DIR = connection.state_dir },
		}, function(result, response_cx)
			if data.phase ~= "process" or not current_exchange(data, response_cx) then
				return
			end
			-- Consume this completion before staging a one-shot command. A repeated
			-- callback cannot schedule another ask while revalidation is pending.
			data.phase = "response"
			local succeeded, pending = pcall(function()
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
				if type(response.instance_id) == "string" and response.instance_id ~= ""
					and data.instance_id ~= nil and response.instance_id ~= data.instance_id then
					-- A daemon restart invalidates reports and all old source identities.
					reset_identity()
					show_error(response_cx, "desktop pet restarted; pending replies have unknown delivery")
					return
				end
				if response.ok == false and type(response.instance_id) == "string" and response.instance_id ~= "" then
					if response.error_code == "binding_required" or response.error_code == "source_retired" then
						-- Do not replay an uncertain ask. A fresh result-free source registers
						-- on the next ordinary full-snapshot poll.
						reset_identity()
						show_error(response_cx, "desktop pet source must reconnect; pending replies have unknown delivery")
						return
					elseif response.error_code == "receipt_rejected" and data.instance_id ~= nil
						and response.instance_id == data.instance_id and data.generation ~= nil then
						if results == data.reports then
							results = tern.json.array()
						end
						error("desktop pet could not confirm a previous command result")
					end
				end
				if result.status ~= 0 or response.ok ~= true or type(response.instance_id) ~= "string"
					or response.instance_id == "" or not valid_id(response.generation) then
					error(type(response.error) == "string" and response.error or "invalid native response")
				end
				if data.generation ~= nil and response.generation ~= data.generation then
					reset_identity()
					show_error(response_cx, "desktop pet source generation changed")
					return
				end
				instance_id = response.instance_id
				generation = response.generation
				-- A matching response confirms the reports in this request; never resend them.
				if results == data.reports then
					results = tern.json.array()
				end
				local command = response.command
				show_connected(response_cx)
				if command ~= nil and command ~= NULL then
					if type(command) ~= "table" or type(command.operation_id) ~= "string"
						or command.operation_id == "" or type(command.pane) ~= "string"
						or type(command.text) ~= "string" then
						error("invalid desktop pet command")
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

local function tick(cx)
	timer = tern.timer(INTERVAL_MS, tick)
	exchange(cx)
end

-- Register before polling. window_start is not guaranteed to fire again on reload.
tern.on("window_start", function(cx)
	exchange(cx)
end)
for _, event in ipairs({ "pane_created", "pane_closed", "tab_created", "tab_closed",
	"command_started", "command_finished", "cwd", "title" }) do
	tern.on(event, function(_event, cx)
		exchange(cx)
	end)
end

tern.command({
	id = "connect",
	title = "Connect to desktop pet",
	run = function(cx)
		exchange(cx)
	end,
})

tern.command({
	id = "configure",
	title = "Configure desktop pet connection",
	run = function(cx)
		local ok, connection = pcall(refresh_connection)
		if not ok then
			-- Allow repairing an invalid stored object, but never mix its fields
			-- with legacy keys or mutate the last successfully active connection.
			local defaults_ok, defaults = pcall(default_connection)
			connection = active_connection or (defaults_ok and defaults or nil)
			if connection == nil then
				show_error(cx, tostring(defaults))
				return
			end
		end
		local captured, stored_connection = pcall(function()
			return tern.json.encode(tern.kv.get("connection"))
		end)
		if not captured then
			show_error(cx, tostring(stored_connection))
			return
		end
		local current = incarnation
		local function current_configuration(fresh_cx)
			if current ~= incarnation then
				return false
			end
			local checked, stored = pcall(function()
				return tern.json.encode(tern.kv.get("connection"))
			end)
			if not checked then
				show_error(fresh_cx, tostring(stored))
				return false
			end
			if stored ~= stored_connection then
				-- A second window won the save. Do not overwrite it from an old
				-- prompt chain, even if its new object is malformed.
				local refreshed, err = pcall(refresh_connection)
				if not refreshed then
					show_error(fresh_cx, tostring(err))
				end
				return false
			end
			return true
		end
		cx:prompt({ value = connection.executable, placeholder = "Desktop pet executable (path or command)" }):next(function(new_executable, err, fresh_cx)
			if not current_configuration(fresh_cx) or err ~= nil or new_executable == nil or fresh_cx == nil then
				return
			end
			fresh_cx:prompt({ value = connection.config_dir, placeholder = "Absolute desktop pet config directory" }):next(function(new_config, config_err, config_cx)
				if not current_configuration(config_cx) or config_err ~= nil or new_config == nil or config_cx == nil then
					return
				end
				config_cx:prompt({ value = connection.state_dir, placeholder = "Absolute desktop pet state directory" }):next(function(new_state, state_err, state_cx)
					if not current_configuration(state_cx) or state_err ~= nil or new_state == nil or state_cx == nil then
						return
					end
					local valid, candidate = pcall(validate_connection, {
						version = 1, executable = new_executable, config_dir = new_config, state_dir = new_state,
					})
					if not valid then
						show_error(state_cx, tostring(candidate))
						return
					end
					local saved, save_err = pcall(function()
						tern.kv.set("connection", candidate)
					end)
					if not saved then
						show_error(state_cx, "could not save desktop pet connection: " .. tostring(save_err))
						return
					end
					active_connection = candidate
					cleanup_legacy()
					reset_identity()
					state_cx:toast("info", "Desktop pet connection saved")
					exchange(state_cx)
				end)
			end)
		end)
	end,
})

timer = tern.timer(1, tick)
