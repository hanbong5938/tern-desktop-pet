--!optimize 0
-- Loaded by transition-regressions.luau in a separate compile callback.
return function(shared)
	local stage = shared.stage

	local LIMIT = 512 * 1024

	-- Yield only at harness boundaries, never inside a production callback. Resuming
	-- this coroutine happens in a new real Tern callback with its own normal budget.

	local function encode_fixture(real, value, name)
		stage(name or "encode fixture")
		local encoded = real.json.encode(value)
		stage("fixture setup/checks")
		return encoded
	end

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

	local function host_inventory(request, id)
		for _, host in ipairs(request.body.hosts) do
			if host.host == (id or "0") then return host end
		end
		error("request omitted expected host " .. (id or "0"))
	end

	local function fixture(entry, real, initial)
		local f = { clock = 1000, requests = {}, asks = {}, gets = {}, prompts = {}, writes = {}, logs = {}, toasts = {},
			stages = {}, setup_requests = {}, setup_pending = {}, inventory_reads = {}, callback_samples = {}, disabled_hooks = 0,
			native_generations = { ["0"] = 7, ["1"] = 11 } }
		local function clone(value)
			if value == nil then
				return nil
			end
			return real.json.decode(real.json.encode(value))
		end
		f.kv = clone(initial or { connection = profile("old") })
		f.inventory = {
			hosts = {
				{ id = 0, name = "Local", kind = "local", state = "connected", panes = { 1 } },
				{ id = 1, name = "Remote A", kind = "remote", state = "connected", address = "a@studio", panes = { 2 } },
			},
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
				if f.inventory_errors and f.inventory_errors[name] then error("injected " .. name .. " API failure") end
				if f.inventory_nil and f.inventory_nil[name] then return nil end
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
					get = function(_, id)
						check()
						table.insert(f.gets, id)
						local is_local = false
						for _, host in ipairs(f.inventory.hosts) do
							if host.kind == "local" and host.state == "connected" and type(host.panes) == "table" then
								for _, pane in ipairs(host.panes) do
									if pane == id then is_local = true end
								end
							end
						end
						expect(is_local, "looked up nonlocal agent")
					end,
					ask = function(_, id, text)
						check()
						table.insert(f.asks, { id = id, text = text })
						if f.ask_hook then f.ask_hook() end
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
			stage(origin)
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
			stage("fixture setup/checks")
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
				if argv[2] == "tern-exchange" then
					expect(callback == nil, "exchange did not use the real process awaitable API")
					expect(#options.stdin <= 256 * 1024, "request exceeded its independent JSON cap")
					expect(options.env.DESKTOP_PET_CONFIG_DIR == argv[4] and options.env.DESKTOP_PET_STATE_DIR == argv[6], "neutral environment disagrees with explicit profile")
					expect(options.env.HERDR_PLUGIN_CONFIG_DIR == nil, "consumer injected old Herdr profile authority")
					local request = { argv = argv, options = options, body = real.json.decode(options.stdin), at_ms = f.clock }
					expect(request.body.version == 2 and type(request.body.hosts) == "table"
						and request.body.agents == nil and request.body.generation == nil, "exchange did not cut over to host-based v2")
					table.insert(f.requests, request)
					return { next = function(_, next_callback) request.callback = next_callback end }
				end
				expect(callback == nil and options.timeout_ms > 0, "setup did not use bounded awaitable subprocess")
				if f.setup_spawn_error then error("injected permission/spawn failure") end
				local pending = { argv = argv, options = options }
				table.insert(f.setup_requests, pending)
				return { next = function(_, next_callback)
					pending.callback = next_callback
					local function complete(_, _err, cx)
						local stage, value
						if argv[4] == "desktop-pet-discover" then
							stage = "discovery"
							value = f.discovery_stdout or "candidate\n" .. (argv[5] ~= "" and argv[5] or "/bin/desktop-pet") .. "\n"
						elseif argv[4] == "desktop-pet-verify" then
							stage = "proof"
							value = real.json.encode({ version = 1, executable = argv[5], kind = "source",
								protocol = 4, observation_mode = 2, integration_api = 1 })
						elseif argv[2] == "update-capabilities" then
							stage = "capability"
							value = real.json.encode({ integration_api = f.integration_api or 1, protocol = 4, observation_mode = 2, app_version = "0.4.0" })
						else
							expect(argv[2] == "profile" and argv[3] == "show" and argv[4] == "--json", "unsupported setup command")
							stage = "profile"
							value = real.json.encode({ version = 1, config_dir = argv[6] or "/config/default", state_dir = argv[8] or "/state/default" })
							if argv[6] then
								expect(options.env.DESKTOP_PET_CONFIG_DIR == argv[6] and options.env.DESKTOP_PET_STATE_DIR == argv[8], "profile proof env/args mismatch")
							end
						end
						if f.setup_json_error == stage then value = "not JSON" end
						if stage == "proof" and f.no_installation then value = "null" end
						pending.callback({ status = f.setup_failure == stage and 1 or 0,
							timed_out = f.setup_timeout == stage, stdout = value, stderr = "injected proof failure" }, nil, cx)
					end
					if f.hold_setup then
						table.insert(f.setup_pending, complete)
					else
						table.insert(f.stages, { callback = complete, delay_ms = 0, microtask = true })
					end
				end }
			end },
		}
		stage("production entry")
		entry(api)
		initializing = false
		stage("fixture setup/checks")
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
		function f:complete_setup()
			local pending = table.remove(self.setup_pending, 1)
			expect(pending ~= nil, "no delayed setup callback")
			self:invoke(function(cx) pending(nil, nil, cx) end, "delayed setup")
			self:drain()
		end
		function f:deliver(request, response, options)
			options = options or {}
			-- The native helper encodes before completion; don't charge fixture-side
			-- encoding and production decoding to the same real callback.
			local stdout = options.stdout or encode_fixture(real, response, "encode helper stdout") .. "\n"
			self:invoke(function(cx)
				request.callback({ status = options.status or 0, timed_out = options.timed_out or false,
					stdout = stdout, stderr = "injected helper" }, options.process_error, cx)
			end, "process completion")
			self:drain()
		end
		function f:response(request, command, daemon)
			local hosts = real.json.array()
			for _, snapshot in ipairs(request.body.hosts) do
				table.insert(hosts, { host = snapshot.host, observation_generation = snapshot.observation_generation,
					generation = self.native_generations[snapshot.host] or 13, error = real.json.null })
			end
			return { ok = true, instance_id = daemon or "daemon-a", hosts = hosts,
				command = command or real.json.null, error = real.json.null }
		end
		function f:ok(request, command, daemon)
			self:deliver(request, self:response(request, command, daemon))
		end
		function f:reject(request, code, daemon, message)
			self:deliver(request, { ok = false, instance_id = daemon or "daemon-a", hosts = real.json.array(),
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

	return {
		LIMIT = LIMIT,
		encode_fixture = encode_fixture,
		expect = expect,
		profile = profile,
		same_profile = same_profile,
		host_inventory = host_inventory,
		fixture = fixture,
		unchanged_source = unchanged_source,
		fresh_source = fresh_source,
	}
end
