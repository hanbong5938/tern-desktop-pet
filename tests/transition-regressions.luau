-- Run inside a Tern window VM (including Carly's documented loadstring VM).
-- Wrapper reference: https://docs.stencil.so/tern/reference/api-window.html#carlys-lua-tool
-- local suite = assert(loadstring(tern.fs.read(TEST_PATH)))()
-- suite.run(tern, tern.fs.read(WINDOW_PATH))
-- Later: suite.get_results(). Each case runs in its own real Tern timer callback.
-- Only boundary tables are controlled; production runs unchanged as function(tern),
-- with the real Tern JSON codec. No subprocess, KV write, prompt, or agent ask escapes.
local suite = {}
local results = { done = true, passed = 0, cases = {} }
local LIMIT = 512 * 1024

local function expect(value, message)
	if not value then
		error(message or "expectation failed", 2)
	end
end

local function profile(suffix)
	return { version = 1, executable = "/bin/pet-" .. suffix,
		config_dir = "/config/" .. suffix, state_dir = "/state/" .. suffix }
end

local function same_profile(a, b)
	return a.version == b.version and a.executable == b.executable
		and a.config_dir == b.config_dir and a.state_dir == b.state_dir
end

local function fixture(entry, real, initial)
	local f = { clock = 1000, requests = {}, asks = {}, prompts = {}, writes = {}, logs = {}, toasts = {},
		stages = {}, inventory_reads = {}, callback_samples = {}, disabled_hooks = 0 }
	local function clone(value)
		if value == nil then
			return nil
		end
		return real.json.decode(real.json.encode(value))
	end
	f.kv = clone(initial or { connection = profile("old") })
	f.inventory = {
		hosts = { { kind = "local", panes = { 1 } }, { kind = "remote", panes = { 2 } } },
		panes = { { pane = 1, title = "local", tab = 10 }, { pane = 2, title = "remote", tab = 20 } },
		tabs = { { id = 10, name = "local tab" }, { id = 20, name = "remote tab" } },
		sessions = { { id = 100, name = "local session", tabs = { 10 } }, { id = 200, name = "remote session", tabs = { 20 } } },
		agents = { { pane = 1, cwd = "/local", state = "idle" }, { pane = 2, cwd = "/remote", state = "working" } },
	}
	local function fresh_context()
		local live = true
		local function check()
			expect(live, "production retained an expired callback context")
		end
		local function inventory(name)
			check()
			f.callback_cost += f.inventory_cost_ms or 0
			f.clock += f.inventory_cost_ms or 0
			table.insert(f.inventory_reads, name)
			if name == "agents" and f.inventory_hook then f.inventory_hook() end
			return clone(f.inventory[name])
		end
		local cx = {
			hosts = { list = function() return inventory("hosts") end },
			session = {
				panes = function() return inventory("panes") end,
				tabs = function() return inventory("tabs") end,
				sessions = function() return inventory("sessions") end,
			},
			agents = {
				list = function() return inventory("agents") end,
				get = function(_, id) check(); expect(id == 1, "looked up nonlocal agent") end,
				ask = function(_, id, text)
					check()
					table.insert(f.asks, { id = id, text = text })
					if f.ask_error then error("ask delivery uncertain") end
				end,
			},
			toast = function(_, level, title, message)
				check()
				table.insert(f.toasts, { level = level, title = title, message = message })
			end,
			prompt = function(_, options)
				check()
				local pending = { value = options.value }
				table.insert(f.prompts, pending)
				return { next = function(_, callback) pending.callback = callback end }
			end,
		}
		return cx, function() live = false end
	end
	function f:invoke(callback, origin)
		local cx, expire = fresh_context()
		self.callback_cost = 0
		local ok, err = pcall(callback, cx)
		expire()
		table.insert(self.callback_samples, { origin = origin, cost_ms = self.callback_cost })
		-- Tern disables an over-budget hook after it returns; production cannot
		-- catch that disablement with pcall around an individual SDK operation.
		if self.budget_ms and self.callback_cost > self.budget_ms then
			self.disabled_hooks += 1
			self.timers_disabled = true
		end
		expect(ok, tostring(err))
	end
	local initializing = true
	local commands = {}
	local api = {
		json = real.json,
		now = function() f.clock += 1; return f.clock end,
		getenv = function(key) return key == "HOME" and "/home/test" or nil end,
		log = { warn = function(message) table.insert(f.logs, message) end },
		kv = {
			get = function(key)
				if f.read_error then error("injected KV read failure") end
				return clone(f.kv[key])
			end,
			set = function(key, value)
				if key == "connection" and f.save_error then error("injected atomic save failure") end
				if key ~= "connection" and f.cleanup_error then error("injected cleanup failure") end
				f.kv[key] = clone(value)
				table.insert(f.writes, { key = key, value = clone(value) })
			end,
		},
		timer = function(ms, callback)
			local handle = { callback = callback, delay_ms = ms }
			if initializing or ms >= 1200 then
				f.poll_timer = handle
			else
				table.insert(f.stages, handle)
			end
			return handle
		end,
		sleep = function(ms)
			if f.sleep_start_error then error("injected sleep registration failure") end
			return { next = function(_, callback)
				if f.sleep_next_error then error("injected sleep continuation failure") end
				table.insert(f.stages, { callback = callback, delay_ms = ms, microtask = true })
			end }
		end,
		on = function() end,
		command = function(definition) commands[definition.id] = definition.run end,
		process = { run = function(argv, options, callback)
			expect(#options.stdin <= 256 * 1024, "request exceeded its independent JSON cap")
			table.insert(f.requests, { argv = argv, options = options, callback = callback,
				body = real.json.decode(options.stdin), at_ms = f.clock })
		end },
	}
	entry(api)
	initializing = false
	function f:step()
		if self.timers_disabled then return false end
		local timer = table.remove(self.stages, 1)
		if timer == nil then return false end
		if timer.microtask then
			self.clock += self.microtask_delay_ms or timer.delay_ms
			local err = self.microtask_error
			self.microtask_error = nil
			self:invoke(function(cx) timer.callback(nil, err, cx) end, "inventory microtask")
		else
			self.clock += self.scheduler_delay_ms or timer.delay_ms
			self:invoke(timer.callback, "inventory timer")
		end
		return true
	end
	function f:drain()
		local callbacks = 0
		while not self.hold_stages and self:step() do
			callbacks += 1
			expect(callbacks <= 100, "asynchronous inventory chain did not settle")
		end
	end
	function f:hold() self.hold_stages = true end
	function f:release() self.hold_stages = false; self:drain() end
	function f:through_inventory(name)
		local callbacks = 0
		while self.inventory_reads[#self.inventory_reads] ~= name do
			expect(self:step(), "inventory did not reach " .. name)
			callbacks += 1
			expect(callbacks <= 100, "inventory boundary did not settle")
		end
	end
	function f:poll()
		self.clock += 1200 + (self.scheduler_delay_ms or 0)
		if not self.timers_disabled then
			local timer = self.poll_timer
			expect(timer ~= nil, "continuous polling timer was lost")
			self.poll_timer = nil
			self:invoke(timer.callback, "poll timer")
			self:drain()
		end
		return self.requests[#self.requests]
	end
	function f:connect()
		self:invoke(commands.connect, "connect")
		self:drain()
		return self.requests[#self.requests]
	end
	function f:configure() self:invoke(commands.configure, "configure"); self:drain() end
	function f:answer(value, err)
		local pending = table.remove(self.prompts, 1)
		expect(pending ~= nil, "no pending configuration prompt")
		self:invoke(function(cx) pending.callback(value, err, cx) end, "prompt completion")
		self:drain()
	end
	function f:save(candidate)
		self:configure()
		self:answer(candidate.executable)
		self:answer(candidate.config_dir)
		self:answer(candidate.state_dir)
	end
	function f:deliver(request, response, options)
		options = options or {}
		self:invoke(function(cx)
			request.callback({ status = options.status or 0, timed_out = options.timed_out or false,
				stdout = options.stdout or real.json.encode(response) .. "\n", stderr = "injected helper" }, cx)
		end, "process completion")
		self:drain()
	end
	function f:ok(request, command, daemon)
		self:deliver(request, { ok = true, instance_id = daemon or "daemon-a", generation = 7,
			command = command or real.json.null })
	end
	function f:reject(request, code, daemon, message)
		self:deliver(request, { ok = false, instance_id = daemon or "daemon-a", generation = 0,
			command = real.json.null, error_code = code, error = message or "diagnostic wording is not a protocol" }, { status = 1 })
	end
	function f:bind()
		local request = self:poll()
		expect(request.body.instance_id == nil and #request.body.results == 0, "initial registration was bound or carried receipts")
		self:ok(request)
		return request
	end
	function f:offer(text, operation)
		local request = self:poll()
		self:ok(request, { operation_id = operation or "op-one", pane = "1", text = text or "hello" })
		return request
	end
	function f:connection_writes()
		local count = 0
		for _, write in ipairs(self.writes) do if write.key == "connection" then count += 1 end end
		return count
	end
	return f
end

local function unchanged_source(a, b)
	expect(a.body.window == b.body.window and a.body.epoch == b.body.epoch, "source identity unexpectedly changed")
end

local function fresh_source(a, b)
	expect(a.body.window ~= b.body.window and b.body.sequence == 1, "source did not register with fresh identity")
	expect(b.body.instance_id == nil and #b.body.results == 0, "fresh registration retained binding or receipts")
end

local cases = {}
local function case(name, run) table.insert(cases, { name = name, run = run }) end

case("lost initial reply rebinds on ordinary poll", function(f)
	local first = f:poll()
	f:deliver(first, {}, { timed_out = true })
	local orphan = f:poll()
	unchanged_source(first, orphan)
	f:reject(orphan, "binding_required")
	expect(#f.requests == 2, "recovery immediately retried")
	local registered = f:poll()
	fresh_source(orphan, registered)
	f:ok(registered)
	expect(#f.asks == 0, "registration made a semantic ask")
end)

case("retired bound source without receipts recovers", function(f)
	f:bind()
	local old = f:poll()
	expect(old.body.instance_id == "daemon-a" and #old.body.results == 0, "fixture was not bound and result-free")
	f:reject(old, "source_retired")
	fresh_source(old, f:poll())
end)

case("retired receipt discarded without ask replay", function(f)
	f:bind(); f:offer()
	local receipt = f:poll()
	expect(#receipt.body.results == 1 and #f.asks == 1, "command receipt missing")
	f:reject(receipt, "source_retired")
	local fresh = f:poll()
	fresh_source(receipt, fresh)
	f:ok(fresh); f:ok(f:poll())
	expect(#f.asks == 1, "recovery duplicated an uncertain ask")
end)

case("receipt rejection keeps binding and clears captured reports only", function(f)
	f:bind(); f:offer()
	local captured = f:poll()
	f:reject(captured, "receipt_rejected")
	local next_request = f:poll()
	unchanged_source(captured, next_request)
	expect(next_request.body.instance_id == "daemon-a" and #next_request.body.results == 0, "receipt rejection reset binding or retained report")
	f:ok(next_request, { operation_id = "op-two", pane = "1", text = "second" })
	-- An obsolete completion cannot drop the reports created after its own table.
	f:reject(captured, "receipt_rejected")
	local newer = f:poll()
	expect(#newer.body.results == 1 and newer.body.results[1].operation_id == "op-two", "old callback cleared newer report table")
	expect(#f.asks == 2, "receipt recovery repeated a command")
end)

case("generic rejection preserves source and report", function(f)
	f:bind(); f:offer()
	local receipt = f:poll()
	f:reject(receipt, "rejected", nil, "stale epoch or sequence")
	local next_request = f:poll()
	unchanged_source(receipt, next_request)
	expect(#next_request.body.results == 1 and next_request.body.instance_id == "daemon-a", "generic rejection mutated recoverable state")
end)

case("error prose is not a receipt-recovery alias", function(f)
	f:bind(); f:offer()
	local receipt = f:poll()
	f:reject(receipt, nil, nil, "stale or unrecognized Tern command result")
	local next_request = f:poll()
	unchanged_source(receipt, next_request)
	expect(#next_request.body.results == 1, "legacy prose cleared a receipt")
end)

case("daemon mismatch wins over receipt code", function(f)
	f:bind(); f:offer()
	local old = f:poll()
	f:reject(old, "receipt_rejected", "daemon-b")
	fresh_source(old, f:poll())
	expect(#f.asks == 1, "daemon restart replayed ask")
end)

case("instance_changed resets by daemon identity", function(f)
	f:bind()
	local old = f:poll()
	f:reject(old, "instance_changed", "daemon-b")
	fresh_source(old, f:poll())
end)

case("transport loss retains report and never repeats ask", function(f)
	f:bind(); f:offer()
	local old = f:poll()
	f:deliver(old, {}, { timed_out = true })
	local retried = f:poll()
	unchanged_source(old, retried)
	expect(#retried.body.results == 1 and #f.asks == 1, "transport failure lost report or repeated ask")
	f:ok(retried)
	expect(#f:poll().body.results == 0, "confirmed report was retransmitted")
end)

case("lost command response does not invent an ask retry", function(f)
	f:bind()
	local lost = f:poll()
	f:deliver(lost, {}, { stdout = "truncated command JSON" })
	local next_request = f:poll()
	unchanged_source(lost, next_request)
	f:ok(next_request)
	expect(#f.asks == 0 and #next_request.body.results == 0, "lost offer fabricated delivery")
end)

case("uncertain semantic ask is never replayed", function(f)
	f:bind(); f.ask_error = true; f:offer()
	local receipt = f:poll()
	expect(#f.asks == 1 and receipt.body.results[1].status == "failed", "ask failure was not reported")
	f:reject(receipt, "receipt_rejected")
	f:ok(f:poll())
	expect(#f.asks == 1, "uncertain semantic ask was retried")
end)

case("canonical save failure retains old tuple and source", function(f)
	f:bind(); f.save_error = true
	local before = f.requests[1]
	f:save(profile("new"))
	expect(same_profile(f.kv.connection, profile("old")) and f:connection_writes() == 0, "failed save partially committed")
	local after = f:poll()
	unchanged_source(before, after)
	expect(after.argv[1] == "/bin/pet-old" and after.argv[4] == "/config/old" and after.argv[6] == "/state/old", "failed save mixed profile fields")
end)

for stage = 1, 3 do
	local canceled_stage = stage
	case("cancel configuration prompt " .. stage, function(f)
		f:bind(); local before = f.requests[1]; f:configure()
		if canceled_stage > 1 then f:answer("/bin/pet-new") end
		if canceled_stage > 2 then f:answer("/config/new") end
		f:answer(nil)
		expect(#f.prompts == 0 and f:connection_writes() == 0, "cancel continued or saved prompts")
		local after = f:poll(); unchanged_source(before, after)
		expect(after.argv[6] == "/state/old", "cancel changed active profile")
	end)
end

case("whole candidate validation precedes canonical save", function(f)
	f:bind(); f:save({ executable = "/bin/new", config_dir = "relative", state_dir = "/state/new" })
	expect(f:connection_writes() == 0 and same_profile(f.kv.connection, profile("old")), "invalid candidate was committed")
	expect(f:poll().argv[4] == "/config/old", "invalid save changed live connection")
end)

case("successful save fences late success and preserves newer busy", function(f)
	f:bind(); local old = f:poll(); f:save(profile("new"))
	local fresh = f.requests[#f.requests]
	fresh_source(old, fresh)
	expect(f:connection_writes() == 1 and fresh.argv[1] == "/bin/pet-new" and fresh.argv[4] == "/config/new" and fresh.argv[6] == "/state/new", "save was not one whole-profile commit")
	f:ok(old, { operation_id = "obsolete", pane = "1", text = "must not ask" })
	f:connect()
	expect(#f.requests == 3 and #f.asks == 0, "late success executed ask or cleared newer busy")
	f:ok(fresh); expect(f:poll().body.instance_id == "daemon-a", "new callback could not bind")
end)

case("late recovery callback cannot reset newly saved connection", function(f)
	f:bind(); local old = f:poll(); f:save(profile("new"))
	local fresh = f.requests[#f.requests]
	f:reject(old, "source_retired")
	f:connect(); expect(#f.requests == 3, "old recovery cleared busy for new connection")
	f:ok(fresh); local bound = f:poll(); unchanged_source(fresh, bound)
end)

case("completed callback cannot clear newer same-incarnation busy", function(f)
	f:bind(); local old = f.requests[1]; local pending = f:poll()
	f:ok(old, { operation_id = "duplicate", pane = "1", text = "never" })
	f:connect(); expect(#f.requests == 2 and #f.asks == 0, "obsolete completion cleared busy or executed a command")
	f:ok(pending); expect(#f:poll().body.results == 0, "duplicate callback generated a report")
end)

case("external profile change before exchange supersedes old busy", function(f)
	f:bind(); local old = f:poll(); f.kv.connection = profile("external")
	local fresh = f:poll(); fresh_source(old, fresh)
	expect(fresh.argv[4] == "/config/external" and fresh.argv[6] == "/state/external", "external connection was mixed")
	f:reject(old, "binding_required"); f:connect()
	expect(#f.requests == 3, "old recovery reset newer external busy")
	f:ok(fresh)
end)

case("external profile change before callback drops old command", function(f)
	f:bind(); local old = f:poll(); f.kv.connection = profile("external")
	f:ok(old, { operation_id = "old-profile", pane = "1", text = "never" })
	expect(#f.asks == 0, "delayed command crossed profile boundary")
	fresh_source(old, f:poll())
end)

case("profile rechecked immediately before semantic ask", function(f)
	f:bind(); local old = f:poll()
	f.inventory_hook = function() f.kv.connection = profile("external"); f.inventory_hook = nil end
	f:ok(old, { operation_id = "old-profile", pane = "1", text = "never" })
	expect(#f.asks == 0, "profile change during revalidation reached ask")
	fresh_source(old, f:poll())
end)

case("external save fences old prompt chain", function(f)
	f:bind(); f:configure(); f:answer("/bin/pet-new")
	f.kv.connection = profile("external"); f:answer("/config/new")
	expect(#f.prompts == 0 and f:connection_writes() == 0 and same_profile(f.kv.connection, profile("external")), "old prompt overwrote other window")
	expect(f:poll().argv[6] == "/state/external", "external profile not adopted")
end)

case("KV read failure blocks old command without mixing profiles", function(f)
	f:bind(); local old = f:poll(); f.read_error = true
	f:ok(old, { operation_id = "old", pane = "1", text = "never" }); f:configure(); f:poll()
	expect(#f.asks == 0 and #f.requests == 2 and #f.prompts == 0, "failed read used fallback or delivered command")
	f.read_error = false; local next_request = f:poll(); unchanged_source(old, next_request)
	expect(next_request.argv[6] == "/state/old", "failed read mixed profile")
end)

case("malformed canonical never falls back to legacy", function(f)
	f.kv.connection = { version = 1, executable = "/bin/broken", config_dir = "/config/broken" }
	f.kv.executable = "/bin/legacy"; f.kv.config_dir = "/config/legacy"; f.kv.state_dir = "/state/legacy"
	f:poll(); expect(#f.requests == 0 and #f.writes == 0, "malformed canonical fell back or was replaced")
	f:configure(); expect(f.prompts[1].value == "herdr-desktop-pet", "malformed fields leaked into repair form")
	f:answer(nil); expect(#f.writes == 0, "cancel replaced malformed canonical")
end)

case("malformed canonical can be repaired by one complete commit", function(f)
	f:bind()
	f.kv.connection = { version = 2, executable = "/bin/broken", config_dir = "/config/broken", state_dir = "/state/broken" }
	f:save(profile("repaired"))
	local fresh = f.requests[#f.requests]
	expect(f:connection_writes() == 1 and same_profile(f.kv.connection, profile("repaired")), "repair did not commit whole canonical object")
	expect(fresh.body.instance_id == nil and fresh.argv[4] == "/config/repaired" and fresh.argv[6] == "/state/repaired", "repair retained broken fields or old binding")
end)

case("external malformed canonical blocks old command and fallback", function(f)
	f:bind(); local old = f:poll()
	f.kv.connection = { version = 1, executable = "/bin/broken", config_dir = "/config/broken" }
	f.kv.state_dir = "/state/legacy"
	f:ok(old, { operation_id = "old", pane = "1", text = "never" }); f:poll()
	expect(#f.asks == 0 and #f.requests == 2 and #f.writes == 0, "malformed external profile used active or legacy fallback")
end)

case("legacy tuple migrates once and cleans only after commit", function(f)
	f.kv = { executable = "/bin/legacy", config_dir = "/config/legacy", state_dir = "/state/legacy" }
	local migrated = f:poll()
	expect(f:connection_writes() == 1 and f.writes[1].key == "connection", "legacy adoption was not one initial commit")
	expect(f.kv.executable == nil and f.kv.config_dir == nil and f.kv.state_dir == nil, "legacy aliases remain")
	expect(migrated.argv[1] == "/bin/legacy" and migrated.argv[4] == "/config/legacy" and migrated.argv[6] == "/state/legacy", "migration mixed tuple")
	f:ok(migrated); f.kv.executable = "/bin/ignored"; f:poll()
	expect(f:connection_writes() == 1 and f.requests[2].argv[1] == "/bin/legacy", "canonical profile re-adopted legacy alias")
end)

case("failed migration leaves legacy tuple intact", function(f)
	f.kv = { executable = "/bin/legacy", config_dir = "/config/legacy", state_dir = "/state/legacy" }; f.save_error = true
	f:poll(); expect(#f.requests == 0 and #f.writes == 0 and f.kv.connection == nil and f.kv.state_dir == "/state/legacy", "failed adoption erased or partially saved legacy")
	f.save_error = false; expect(f:poll().argv[6] == "/state/legacy", "migration could not recover ordinary poll")
end)

case("cleanup failure cannot roll back committed connection", function(f)
	f:bind(); f.cleanup_error = true; f:save(profile("new"))
	expect(f:connection_writes() == 1 and same_profile(f.kv.connection, profile("new")) and f.requests[#f.requests].argv[6] == "/state/new", "cleanup failure rolled back live cutover")
end)

case("remote inventory and remote command stay excluded", function(f)
	f:bind(); local request = f:poll()
	expect(#request.body.agents == 1 and request.body.agents[1].pane == "1", "remote agent escaped local filtering")
	f:ok(request, { operation_id = "remote", pane = "2", text = "never" })
	local reported = f:poll()
	expect(#f.asks == 0 and reported.body.results[1].status == "failed", "remote command reached semantic ask")
end)

case("300 KiB command accepted unchanged", function(f)
	f:bind(); local text = string.rep("a", 300 * 1024); f:offer(text)
	expect(#f.asks == 1 and f.asks[1].text == text, "native-admitted large command was lost or changed")
end)

case("large Unicode and JSON escapes accepted unchanged", function(f)
	f:bind(); local text = string.rep('한🙂"\n\\', 30000); f:offer(text)
	expect(#f.asks == 1 and f.asks[1].text == text, "Unicode or escaped command was changed")
end)

local function boundary_response(real, delta)
	local response = { ok = true, instance_id = "daemon-a", generation = 7,
		command = { operation_id = "boundary", pane = "1", text = '🙂"\n\\' } }
	local overhead = #real.json.encode(response) + 1
	response.command.text ..= string.rep("a", LIMIT - overhead + delta)
	local stdout = real.json.encode(response) .. "\n"
	expect(#stdout == LIMIT + delta, "fixture did not construct exact encoded stdout boundary")
	return response.command.text, stdout
end

case("512 KiB stdout including LF accepted", function(f, real)
	f:bind(); local pending = f:poll(); local text, stdout = boundary_response(real, 0)
	f:deliver(pending, {}, { stdout = stdout })
	expect(#f.asks == 1 and f.asks[1].text == text, "exact response-byte boundary was rejected or changed")
end)

case("one byte over 512 KiB stdout rejected before ask", function(f, real)
	f:bind(); local pending = f:poll(); local _, stdout = boundary_response(real, 1)
	f:deliver(pending, {}, { stdout = stdout })
	expect(#f.asks == 0, "oversized stdout reached ask")
	local next_request = f:poll(); unchanged_source(pending, next_request)
	expect(#next_request.body.results == 0 and next_request.body.instance_id == "daemon-a", "oversized response reset binding or fabricated receipt")
end)

local function replace_local_observation(f, suffix)
	f.inventory.panes[1].title = "local " .. suffix
	f.inventory.agents[1].cwd = "/local/" .. suffix
	f.inventory.tabs[1].name = "tab " .. suffix
	f.inventory.sessions[1].name = "session " .. suffix
end

local function expect_local_observation(request, suffix)
	expect(#request.body.agents == 1, "snapshot was not a complete local-only inventory")
	local agent = request.body.agents[1]
	expect(agent.pane == "1" and agent.title == "local " .. suffix and agent.cwd == "/local/" .. suffix
		and agent.tab_id == "10" and agent.tab_label == "tab " .. suffix
		and agent.session_id == "100" and agent.session_label == "session " .. suffix,
		"snapshot mixed old and fresh inventory observations")
end

case("12ms inventory SDK boundaries preserve continuous polling and one accepted ask", function(f)
	f.inventory_cost_ms = 12
	f.budget_ms = 50
	expect(5 * f.inventory_cost_ms > f.budget_ms, "budget model cannot expose the old additive inventory burst")
	replace_local_observation(f, "budget")
	local registered = f:bind()
	expect_local_observation(registered, "budget")
	local offered = f:offer("budget semantic ask", "budget-one")
	expect_local_observation(offered, "budget")
	expect(#f.asks == 1 and f.asks[1].text == "budget semantic ask", "staged command did not reach semantic ask exactly once")
	local receipt = f:poll()
	expect(#receipt.body.results == 1 and receipt.body.results[1].operation_id == "budget-one"
		and receipt.body.results[1].status == "accepted", "accepted semantic delivery did not produce its receipt")
	f:ok(receipt)
	local previous = receipt
	for _ = 1, 5 do
		local count = #f.requests
		local current = f:poll()
		expect(#f.requests == count + 1 and current.body.sequence > previous.body.sequence,
			"timer hook stopped advancing full snapshots")
		expect(current.at_ms - previous.at_ms < 5000, "snapshot cadence exceeded native freshness")
		unchanged_source(registered, current)
		expect_local_observation(current, "budget")
		expect(current.body.instance_id == "daemon-a" and #current.body.results == 0, "healthy polling lost binding or replayed a receipt")
		f:ok(current)
		previous = current
	end
	expect(f.disabled_hooks == 0 and not f.timers_disabled, "inventory exceeded the callback budget and disabled continuous polling")
	for _, sample in ipairs(f.callback_samples) do
		expect(sample.cost_ms <= f.budget_ms, "SDK cost accumulated beyond one callback budget")
	end
	expect(#f.asks == 1, "continuous polling replayed the accepted semantic ask")
end)

case("profile cutover during snapshot inventory drops old work and observes the new profile", function(f)
	local bound = f:bind()
	local before = #f.requests
	f:hold(); f:poll(); f:through_inventory("sessions")
	f:connect()
	expect(#f.requests == before, "busy staged inventory spawned a second request")
	f.kv.connection = profile("external")
	replace_local_observation(f, "external")
	f:release()
	expect(#f.requests == before and #f.asks == 0, "old staged inventory crossed the profile boundary")
	local fresh = f:poll()
	fresh_source(bound, fresh)
	expect(fresh.argv[1] == "/bin/pet-external" and fresh.argv[4] == "/config/external"
		and fresh.argv[6] == "/state/external", "new snapshot mixed connection fields")
	expect_local_observation(fresh, "external")
	f:ok(fresh)
	expect(#f:poll().body.results == 0, "discarded snapshot leaked an old command receipt")
end)

case("invalid profile during snapshot inventory blocks stale work until a fresh complete profile", function(f)
	local bound = f:bind()
	local before = #f.requests
	f:hold(); f:poll(); f:through_inventory("sessions")
	f.kv.connection = { version = 1, executable = "/bin/broken", config_dir = "/config/broken" }
	f:release(); f:poll()
	expect(#f.requests == before and #f.asks == 0, "invalid mid-inventory profile used the old connection")
	f.kv.connection = profile("repaired")
	replace_local_observation(f, "repaired")
	local fresh = f:poll()
	fresh_source(bound, fresh)
	expect_local_observation(fresh, "repaired")
	expect(fresh.argv[6] == "/state/repaired", "repair did not resume with the complete new profile")
end)

case("same-profile identity reset during snapshot inventory fences obsolete work", function(f)
	local bound = f:bind()
	local before = #f.requests
	f:hold(); f:poll(); f:through_inventory("sessions")
	replace_local_observation(f, "reset")
	f:save(profile("old"))
	f:release()
	expect(#f.requests == before + 1 and #f.asks == 0, "identity reset spawned obsolete staged work")
	local fresh = f.requests[#f.requests]
	fresh_source(bound, fresh)
	expect_local_observation(fresh, "reset")
	f:connect()
	expect(#f.requests == before + 1, "obsolete inventory completion cleared newer busy work")
	f:ok(fresh)
	expect(#f:poll().body.results == 0, "identity-reset snapshot leaked receipts")
end)

case("profile cutover during command revalidation drops old ask and receipt", function(f)
	f:bind(); local old = f:poll()
	f:hold(); f:ok(old, { operation_id = "old-staged", pane = "1", text = "never" })
	f:through_inventory("sessions")
	f:connect()
	expect(#f.requests == 2 and #f.asks == 0, "held command revalidation released busy before semantic delivery")
	f.kv.connection = profile("external")
	replace_local_observation(f, "external")
	f:release()
	expect(#f.asks == 0, "old command reached ask after staged profile cutover")
	local fresh = f:poll()
	fresh_source(old, fresh)
	expect_local_observation(fresh, "external")
	f:ok(old, { operation_id = "old-staged", pane = "1", text = "never" })
	f:connect()
	expect(#f.requests == 3 and #f.asks == 0, "obsolete offered command escaped its fence or cleared newer busy")
	f:ok(fresh)
	expect(#f:poll().body.results == 0, "old command receipt leaked into the new profile")
end)

case("same-profile identity reset during command revalidation preserves newer work", function(f)
	f:bind(); local old = f:poll()
	f:hold(); f:ok(old, { operation_id = "old-reset", pane = "1", text = "never" })
	f:through_inventory("sessions")
	replace_local_observation(f, "reset")
	f:save(profile("old"))
	f:release()
	local fresh = f.requests[#f.requests]
	fresh_source(old, fresh)
	expect_local_observation(fresh, "reset")
	expect(#f.requests == 3 and #f.asks == 0, "old command survived a same-profile identity reset")
	f:ok(old, { operation_id = "old-reset", pane = "1", text = "never" }); f:connect()
	expect(#f.requests == 3 and #f.asks == 0, "late old command cleared newer busy or replayed ask")
	f:ok(fresh)
	local next_request = f:poll()
	expect(#next_request.body.results == 0, "identity-reset command leaked a receipt")
	f:ok(next_request, { operation_id = "new-reset", pane = "1", text = "new identity" })
	expect(#f.asks == 1 and f.asks[1].text == "new identity", "new identity could not deliver its own command exactly once")
end)

case("pane title and local-host changes between inventory chunks reject without ask replay", function(f)
	f:bind(); local old = f:poll()
	f:hold(); f:ok(old, { operation_id = "old-pane", pane = "1", text = "never" })
	f:through_inventory("agents")
	f:ok(old, { operation_id = "old-pane", pane = "1", text = "never" })
	-- Keep cwd, pane id, tab and session unchanged: title identity alone must fence.
	f.inventory.panes[1].title = "local replacement"
	f:release()
	expect(#f.asks == 0, "replacement pane received a command selected from old metadata")
	local reported = f:poll()
	expect(#reported.body.agents == 1 and reported.body.agents[1].title == "local replacement"
		and reported.body.agents[1].cwd == "/local", "fresh snapshot did not observe the replacement title")
	expect(#reported.body.results == 1 and reported.body.results[1].operation_id == "old-pane"
		and reported.body.results[1].status == "failed", "changed pane did not report its rejected one-shot command")
	f:ok(reported)
	f:ok(old, { operation_id = "old-pane", pane = "1", text = "never" })
	local next_request = f:poll()
	expect(#next_request.body.results == 0 and #f.asks == 0, "obsolete pane command replayed ask or receipt")
	f:ok(next_request, { operation_id = "replacement-pane", pane = "1", text = "new pane" })
	expect(#f.asks == 1 and f.asks[1].text == "new pane", "freshly observed replacement pane could not receive its own command")
	local accepted = f.requests[#f.requests]
	expect(accepted.body.results[1].status == "accepted", "replacement pane delivery was not reported")
	f:ok(accepted)
	local moved = f:poll()
	f:hold(); f:ok(moved, { operation_id = "host-move", pane = "1", text = "never remote" })
	f:through_inventory("agents")
	f.inventory.hosts[1].panes = {}
	f.inventory.hosts[2].panes = { 1, 2 }
	f:release()
	expect(#f.asks == 1, "pane moved out of the local host received the old command")
	local moved_receipt = f:poll()
	expect(#moved_receipt.body.agents == 0 and #moved_receipt.body.results == 1
		and moved_receipt.body.results[1].operation_id == "host-move"
		and moved_receipt.body.results[1].status == "failed", "current host membership did not exclude and reject the moved pane")
	f:ok(moved_receipt)
	f:ok(moved, { operation_id = "host-move", pane = "1", text = "never remote" })
	local after_move = f:poll()
	expect(#after_move.body.agents == 0 and #after_move.body.results == 0 and #f.asks == 1,
		"late moved-pane callback replayed an ask or leaked a receipt")
end)

case("1s scheduler jitter confirms accepted receipt before native 5s expiry", function(f)
	f.inventory_cost_ms = 12
	f.budget_ms = 50
	f.scheduler_delay_ms = 1000
	f.microtask_delay_ms = 10
	replace_local_observation(f, "jitter")
	local consumer = { accepted = 0, unknown_delivery = 0 }
	local function consume(request, command)
		expect_local_observation(request, "jitter")
		if consumer.window ~= nil then
			expect(request.body.window == consumer.window and request.body.epoch == consumer.epoch
				and request.body.instance_id == "daemon-a", "healthy receipt pipeline changed consumer binding")
			expect(request.at_ms - consumer.last_snapshot < 5000, "scheduler jitter expired native snapshot freshness")
		else
			consumer.window, consumer.epoch = request.body.window, request.body.epoch
		end
		consumer.last_snapshot = request.at_ms
		if #request.body.results > 0 then
			expect(#request.body.results == 1 and consumer.operation ~= nil, "consumer received an unsolicited or repeated receipt")
			local receipt = request.body.results[1]
			expect(receipt.operation_id == consumer.operation and receipt.status == "accepted",
				"semantic delivery did not report the accepted consumer operation")
			if f.clock >= consumer.deadline then
				consumer.unknown_delivery += 1
				f:reject(request, "receipt_rejected")
				return
			end
			consumer.accepted += 1
			consumer.operation = nil
		end
		if command ~= nil then
			expect(consumer.operation == nil, "consumer offered overlapping commands")
			consumer.operation = command.operation_id
			consumer.deadline = f.clock + 5000
		end
		f:ok(request, command)
	end
	local registered = f:poll()
	consume(registered)
	local offered = f:poll()
	local before = #f.requests
	local command = { operation_id = "jitter-one", pane = "1", text = "jitter semantic ask" }
	consume(offered, command)
	expect(#f.asks == 1 and f.asks[1].text == command.text, "jittered pipeline did not deliver exactly one semantic ask")
	expect(#f.requests == before + 1, "accepted delivery did not promptly produce a fresh full-snapshot receipt exchange")
	local receipt = f.requests[#f.requests]
	-- A delayed completion from the offered exchange cannot reopen its command
	-- or release the newer full-snapshot receipt exchange while it is busy.
	f:ok(offered, command); f:connect()
	expect(#f.requests == before + 1 and #f.asks == 1, "late offered callback replayed ask or released receipt-exchange busy")
	consume(receipt)
	expect(consumer.accepted == 1 and consumer.unknown_delivery == 0 and consumer.operation == nil,
		"native consumer could not confirm delivery before its five-second expiry")
	for _ = 1, 3 do
		local count = #f.requests
		local current = f:poll()
		expect(#f.requests == count + 1 and #current.body.results == 0, "normal polling stopped or retransmitted the accepted receipt")
		unchanged_source(registered, current)
		consume(current)
	end
	expect(consumer.accepted == 1 and consumer.unknown_delivery == 0 and #f.asks == 1,
		"healthy polling rejected a confirmed receipt or replayed semantic delivery")
	expect(f.disabled_hooks == 0 and not f.timers_disabled, "chunked inventory disabled the callback hook under the SDK budget")
	for _, sample in ipairs(f.callback_samples) do
		expect(sample.cost_ms <= f.budget_ms, "chunked SDK work exceeded the callback budget")
	end
end)

case("inventory awaitable failures release busy and canceled commands never replay", function(f)
	local bound = f:bind()
	for _, failure in ipairs({ "sleep_start_error", "sleep_next_error" }) do
		local before = #f.requests
		f[failure] = true
		f:poll()
		expect(#f.requests == before and #f.asks == 0, "failed awaitable registration submitted stale inventory")
		f[failure] = false
		local recovered = f:poll()
		expect(#f.requests == before + 1, "awaitable registration failure left normal polling permanently busy")
		unchanged_source(bound, recovered)
		f:ok(recovered)
	end
	local before = #f.requests
	f:hold(); f:poll(); f:through_inventory("agents")
	f.microtask_error = "inventory continuation canceled"
	f:release()
	expect(#f.requests == before and #f.asks == 0, "canceled snapshot continuation submitted partial inventory")
	local recovered = f:poll()
	expect(#f.requests == before + 1, "canceled snapshot continuation left normal polling busy")
	unchanged_source(bound, recovered)
	f:ok(recovered)
	local offered = f:poll()
	f:hold(); f:ok(offered, { operation_id = "canceled-one", pane = "1", text = "never canceled" })
	f:through_inventory("agents")
	f.microtask_error = "semantic revalidation canceled"
	f:release()
	expect(#f.asks == 0, "canceled semantic revalidation reached ask")
	local receipt = f.requests[#f.requests]
	expect(#receipt.body.results == 1 and receipt.body.results[1].operation_id == "canceled-one"
		and receipt.body.results[1].status == "failed", "canceled command did not produce its one failed receipt")
	f:ok(offered, { operation_id = "canceled-one", pane = "1", text = "never canceled" })
	f:connect()
	expect(f.requests[#f.requests] == receipt and #f.asks == 0, "late canceled callback replayed ask or released newer receipt work")
	f:ok(receipt)
	local current = f:poll()
	unchanged_source(bound, current)
	expect(#current.body.results == 0, "confirmed cancellation receipt leaked into normal polling")
	f:ok(current, { operation_id = "after-cancel", pane = "1", text = "after cancellation" })
	expect(#f.asks == 1 and f.asks[1].text == "after cancellation", "normal semantic delivery did not resume after cancellation")
end)

function suite.get_results()
	return results
end

function suite.run(real_tern, production_source, on_complete)
	expect(results.done, "regression run already active")
	-- Parameter shadowing is the documented loadstring wrapper, not a source rewrite.
	local compiled, err = loadstring("return function(tern)\n" .. production_source .. "\nend", "desktop-pet-production")
	expect(compiled ~= nil, tostring(err))
	local entry = compiled()
	results = { done = false, passed = 0, total = #cases, cases = {} }
	local index = 0
	local function next_case()
		index += 1
		local current = cases[index]
		if current == nil then
			results.done = true
			if on_complete then on_complete(results) end
			return
		end
		local ok, failure = pcall(function()
			current.run(fixture(entry, real_tern), real_tern)
		end)
		table.insert(results.cases, { name = current.name, ok = ok, error = not ok and tostring(failure) or nil })
		if ok then results.passed += 1 end
		real_tern.timer(1, next_case)
	end
	real_tern.timer(1, next_case)
	return { scheduled = #cases }
end

return suite
