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

	local function same_paths(a, b)
		return a.config_dir == b.config_dir and a.state_dir == b.state_dir
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
			missing_executables = {}, missing_invocations = {}, load_reads = {}, endpoint_reads = {}, selected_profiles = {}, process_launches = {},
			handover_requests = {}, handover_pending = {}, bound_windows = {}, issued_handovers = {}, handover_receipts = {},
			events = {}, native_generations = { ["0"] = 7, ["1"] = 11 } }
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
		function f:handover_authority()
			return { operation_id = string.rep("d", 32), plan_path = "/approved/migration-plan.json",
				plan_sha256 = string.rep("b", 64), token = string.rep("c", 64),
				consumer_revision = string.rep("a", 40), target_instance_id = self.native_instance or "daemon-a" }
		end
		function f:descriptor(connection)
			return { version = 1, instance_id = self.native_instance or "daemon-a",
				config_dir = connection.config_dir, state_dir = connection.state_dir,
				url = "http://127.0.0.1:43127/extension", token = self.server_token or string.rep("a", 64) }
		end
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
					pane = function(_, id)
						check()
						f.callback_cost += f.inventory_cost_ms or 0
						f.clock += f.inventory_cost_ms or 0
						if f.pane_lookup_error then error("injected pane lookup failure") end
						for _, pane in ipairs(f.inventory.panes) do
							if pane.pane == id then return clone(pane) end
						end
						return nil
					end,
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
				if origin == "poll timer" or origin == "inventory timer" then self.timers_disabled = true
				elseif origin == "inventory microtask" or origin == "HTTP completion"
					or origin == "prompt completion" or origin == "delayed setup" then self.awaits_disabled = true end
			end
			expect(ok, tostring(err))
			stage("fixture setup/checks")
		end
		local initializing = true
		local commands = {}
		local events = f.events
		local api = {
			json = {
				null = real.json.null, array = real.json.array,
				encode = function(value)
					f.callback_cost += f.json_cost_ms or 0
					f.clock += f.json_cost_ms or 0
					return real.json.encode(value)
				end,
				decode = function(value)
					f.callback_cost += f.json_cost_ms or 0
					f.clock += f.json_cost_ms or 0
					return real.json.decode(value)
				end,
			},
			now = function()
				if initializing then table.insert(f.load_reads, "clock") end
				f.clock += 1
				return f.clock
			end,
			getenv = function(key) return (f.environment or {})[key] or (key == "HOME" and "/home/test" or nil) end,
			log = { warn = function(message) table.insert(f.logs, message) end },
			kv = {
				get = function(key)
					if initializing then table.insert(f.load_reads, "KV") end
					f.callback_cost += f.kv_cost_ms or 0
					f.clock += f.kv_cost_ms or 0
					if f.read_error then error("injected KV read failure") end
					return clone(f.kv[key])
				end,
				set = function(key, value)
					if key == "connection" and f.save_error then error("injected atomic save failure") end
					if key ~= "connection" and f.cleanup_error then error("injected cleanup failure") end
					f.kv[key] = clone(value)
					table.insert(f.writes, { key = key, value = clone(value) })
					if key == "connection" and f.after_connection_save then f.after_connection_save() end
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
			on = function(event, callback) events[event] = callback end,
			command = function(definition) commands[definition.id] = definition.run end,
			fs = { read = function(path, max_bytes)
				if initializing then table.insert(f.load_reads, "endpoint") end
				table.insert(f.endpoint_reads, { path = path, max_bytes = max_bytes })
				expect(max_bytes == 4096, "endpoint read was not bounded independently of JSON response limits")
				if f.endpoint_error then error("injected inaccessible or nonregular endpoint") end
				local state_dir = path:match("^(.*)/extension%-http%.json$")
				local connection = state_dir and f.selected_profiles[state_dir]
				expect(connection ~= nil, "endpoint discovery escaped verified profile selection")
				local endpoint = f.endpoint or f:descriptor(connection)
				if f.endpoint_edit then f.endpoint_edit(endpoint) end
				local bytes = f.endpoint_bytes or real.json.encode(endpoint)
				if #bytes > max_bytes then error("endpoint exceeds bounded read") end
				if f.endpoint_read_hook then f.endpoint_read_hook() end
				return bytes
			end },
			fetch = function(url, options)
				if initializing then table.insert(f.load_reads, "HTTP") end
				if f.fetch_start_error then error("injected fetch registration failure containing private data") end
				expect(options.method == "POST" and options.headers["Content-Type"] == "application/json", "exchange did not use extension POST JSON semantics")
				expect(#options.body <= 256 * 1024, "request exceeded its independent JSON cap")
				local body = real.json.decode(options.body)
				local selected = f.endpoint_reads[#f.endpoint_reads]
				local state_dir = selected.path:match("^(.*)/extension%-http%.json$")
				local profile = f.selected_profiles[state_dir]
				local connection = { config_dir = profile.config_dir, state_dir = profile.state_dir }
				local request = { url = url, options = options, body = body, connection = connection, at_ms = f.clock,
					authenticated = options.headers.Authorization == "Bearer " .. (f.server_token or string.rep("a", 64)) }
				expect(body.version == 2 and type(body.hosts) == "table" and body.agents == nil and body.generation == nil,
					"exchange did not preserve host-based v2")
				table.insert(f.requests, request)
				return { next = function(_, callback) request.callback = callback end }
			end,
			process = { run = function(argv, options, callback)
				if initializing then table.insert(f.load_reads, "process") end
				table.insert(f.process_launches, { argv = argv, options = options })
				if f.missing_executables[argv[1]] then
					table.insert(f.missing_invocations, argv[1])
					error("injected missing executable: " .. argv[1])
				end
				expect(argv[2] ~= "tern-exchange", "regular inventory exchange launched a subprocess")
				if argv[2] == "migration-integration-handover" then
					expect(options.env.DESKTOP_PET_CONFIG_DIR == argv[4] and options.env.DESKTOP_PET_STATE_DIR == argv[6],
						"handover mixed profile environment and arguments")
					local request = { argv = argv, options = options, body = real.json.decode(options.stdin) }
					expect(request.body.version == 1 and request.body.kind == argv[2] and request.body.loaded_protocol == 1
						and type(request.body.window_id) == "string", "handover omitted loaded protocol or actual source window")
					table.insert(f.handover_requests, request)
					return { next = function(_, next_callback)
						local function complete(_, _err, cx)
							local binding = f.bound_windows[request.body.window_id]
							local issued = f.issued_handovers[request.body.handover.token]
							local valid = binding ~= nil and binding.result_free
								and request.body.target.executable == argv[1]
								and binding.config_dir == argv[4] and binding.state_dir == argv[6]
								and (f.native_instance == nil or f.native_instance == binding.instance_id)
								and issued ~= nil and type(f.kv.connection) == "table" and same_profile(f.kv.connection, request.body.target)
								and real.json.encode(request.body.handover) == real.json.encode(issued.handover)
								and same_profile(request.body.original, issued.original) and same_profile(request.body.target, issued.target)
							local response = f.handover_response or { version = 1, kind = "migration-integration-handover", confirmed = true,
								window_id = request.body.window_id, target_instance_id = binding and binding.instance_id or "missing" }
							local delay = f.handover_delay_ms or 0
							f.clock += delay
							local timed_out = f.handover_timeout or delay > options.timeout_ms
							local denied = not valid or f.handover_denied or f.handover_package_invalid
							if not denied and not timed_out then table.insert(f.handover_receipts, clone(request.body)) end
							if f.handover_json_error then response = nil end
							next_callback({ status = denied and 1 or 0, timed_out = timed_out,
								stdout = response and real.json.encode(response) or "not JSON", stderr = "native handover evidence rejected" }, nil, cx)
						end
						if f.hold_handover then table.insert(f.handover_pending, complete)
						else table.insert(f.stages, { callback = complete, delay_ms = 0, microtask = true }) end
					end }
				end
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
							value = real.json.encode({ integration_api = f.integration_api or 1, protocol = 4, observation_mode = 2,
								app_version = "0.4.0", migration_handover_protocol = f.handover_protocol })
						elseif argv[2] == "legacy-migration-route" then
							stage = "migration"
							local original = real.json.decode(options.stdin)
							expect(original.version == 1 and original.kind == "legacy-migration-route", "migration query omitted its protocol identity")
							expect(argv[4] == original.config_dir and argv[6] == original.state_dir
								and options.env.DESKTOP_PET_CONFIG_DIR == original.config_dir
								and options.env.DESKTOP_PET_STATE_DIR == original.state_dir, "migration proof changed the original profile pair")
							local proof = f.migration_proof or {
								version = 1, kind = "legacy-migration-route", committed = true,
								original = { version = 1, executable = original.executable, config_dir = original.config_dir, state_dir = original.state_dir },
								target = { version = 1, executable = argv[1], config_dir = original.config_dir, state_dir = original.state_dir },
								handover = f.handover_available and f:handover_authority() or nil,
							}
							if type(proof.handover) == "table" and type(proof.handover.token) == "string" then
								f.issued_handovers[proof.handover.token] = clone(proof)
							end
							value = real.json.encode(proof)
						else
							expect(argv[2] == "profile" and argv[3] == "show" and argv[4] == "--json", "unsupported setup command")
							stage = "profile"
							value = real.json.encode({ version = 1, config_dir = argv[6] or "/config/default", state_dir = argv[8] or "/state/default" })
							f.selected_profiles[argv[8] or "/state/default"] = { version = 1, executable = argv[1],
								config_dir = argv[6] or "/config/default", state_dir = argv[8] or "/state/default" }
							if argv[6] then
								expect(options.env.DESKTOP_PET_CONFIG_DIR == argv[6] and options.env.DESKTOP_PET_STATE_DIR == argv[8], "profile proof env/args mismatch")
							end
						end
						if f.setup_json_error == stage then value = "not JSON" end
						if stage == "proof" and f.no_installation then value = "null" end
						local setup_failed = f.setup_failure == stage
						if setup_failed and f.setup_failure_route ~= nil then
							local selected = (argv[4] == "desktop-pet-discover" or argv[4] == "desktop-pet-verify") and argv[5] or argv[1]
							setup_failed = selected == f.setup_failure_route
						end
						if stage == "proof" and f.missing_executables[argv[5]] then setup_failed = true end
						local delay = (f.setup_delays_ms or {})[stage] or 0
						f.clock += delay
						pending.callback({ status = (setup_failed or (stage == "migration" and not f.migration_available)) and 1 or 0,
							timed_out = f.setup_timeout == stage or delay > options.timeout_ms, stdout = value,
							stderr = stage == "migration" and "no committed approved route or Tern provider unavailable" or "injected proof failure" }, nil, cx)
					end
					if f.hold_setup or (argv[2] == "legacy-migration-route" and f.hold_migration) then
						table.insert(f.setup_pending, complete)
					else
						table.insert(f.stages, { callback = complete, delay_ms = 0, microtask = true })
					end
				end }
			end },
		}
		f.api = api
		stage("production entry")
		entry(api)
		initializing = false
		stage("fixture setup/checks")
		function f:step()
			if self.timers_disabled and self.awaits_disabled then return false end
			local timer = table.remove(self.stages, 1)
			if timer == nil then return false end
			if (timer.microtask and self.awaits_disabled) or (not timer.microtask and self.timers_disabled) then return true end
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
				expect(callbacks <= 10000, "asynchronous inventory chain did not settle")
			end
		end
		function f:hold() self.hold_stages = true end
		function f:release() self.hold_stages = false; self:drain() end
		function f:through_inventory(name)
			local callbacks = 0
			while self.inventory_reads[#self.inventory_reads] ~= name do
				expect(self:step(), "inventory did not reach " .. name)
				callbacks += 1
				expect(callbacks <= 10000, "inventory boundary did not settle")
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
		function f:window_start()
			self:invoke(events.window_start, "window_start")
			self:drain()
		end
		function f:connect()
			self:invoke(commands.connect, "connect")
			self:drain()
			return self.requests[#self.requests]
		end
		function f:event(name)
			local callback = self.events[name]
			expect(callback ~= nil, "production did not subscribe to " .. name)
			self:invoke(function(cx)
				if name == "window_start" then callback(cx) else callback({}, cx) end
			end, "event " .. name)
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
		function f:complete_handover()
			local pending = table.remove(self.handover_pending, 1)
			expect(pending ~= nil, "no delayed handover receipt")
			self:invoke(function(cx) pending(nil, nil, cx) end, "handover receipt")
			self:drain()
		end
		function f:route_queries()
			local count = 0
			for _, query in ipairs(self.setup_requests) do if query.argv[2] == "legacy-migration-route" then count += 1 end end
			return count
		end
		function f:deliver(request, response, options)
			options = options or {}
			if self.awaits_disabled then return end
			-- The HTTP server encodes before completion; don't charge fixture-side
			-- encoding and production decoding to the same real callback.
			local body = options.body or encode_fixture(real, response, "encode HTTP body") .. "\n"
			if request.authenticated and not options.error and not options.fetch_error and not options.timed_out
				and (options.status == nil or options.status == 200)
				and response.ok == true and request.body.instance_id == response.instance_id then
				self.bound_windows[request.body.window] = { instance_id = response.instance_id,
					config_dir = request.connection.config_dir, state_dir = request.connection.state_dir,
					epoch = request.body.epoch, sequence = request.body.sequence, result_free = #request.body.results == 0 }
			end
			self:invoke(function(cx)
				request.callback({ status = request.authenticated and (options.status or 200) or 401,
					timed_out = options.timed_out or false, body = body, headers = {},
					error = options.error }, options.fetch_error, cx)
			end, "HTTP completion")
			self:drain()
		end
		function f:response(request, command, daemon)
			local hosts = real.json.array()
			for _, snapshot in ipairs(request.body.hosts) do
				table.insert(hosts, { host = snapshot.host, observation_generation = snapshot.observation_generation,
					generation = self.native_generations[snapshot.host] or 13, error = real.json.null })
			end
			return { ok = true, instance_id = daemon or self.native_instance or "daemon-a", hosts = hosts,
				command = command or real.json.null, error = real.json.null }
		end
		function f:ok(request, command, daemon)
			self:deliver(request, self:response(request, command, daemon))
		end
		function f:reject(request, code, daemon, message)
			self:deliver(request, { ok = false, instance_id = daemon or "daemon-a", hosts = real.json.array(),
				command = real.json.null, error_code = code, error = message or "diagnostic wording is not a protocol" })
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
		function f:fork()
			return fixture(entry, real)
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
		same_paths = same_paths,
		host_inventory = host_inventory,
		fixture = fixture,
		unchanged_source = unchanged_source,
		fresh_source = fresh_source,
	}
end
