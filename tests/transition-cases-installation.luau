--!optimize 0
-- Loaded by transition-regressions.luau in a separate compile callback.
return function(shared)
	local case = shared.case
	local expect = shared.expect
	local profile = shared.profile
	local same_profile = shared.same_profile
	local fresh_source = shared.fresh_source

	case("fresh defaults come only from verified readonly native profile", function(f)
		f.kv = {}
		local request = f:poll()
		expect(request.argv[1] == "/bin/desktop-pet" and request.argv[4] == "/config/default" and request.argv[6] == "/state/default", "defaults were constructed by the plugin")
		expect(#f.writes == 0 and #f.setup_requests == 4, "Connect saved defaults or omitted readonly proof stages")
		for _, setup in ipairs(f.setup_requests) do
			expect(setup.argv[2] ~= "start" and setup.argv[2] ~= "ensure" and setup.argv[2] ~= "install", "consumer silently started or installed native")
		end
		f:ok(request)
		for _ = 1, 3 do f:ok(f:poll()) end
		expect(#f.setup_requests == 4, "polling repeated native discovery")
	end)

	case("plugin version is not native compatibility authority", function(f)
		local request = f:poll()
		expect(request ~= nil and #f.setup_requests == 4, "integration_api1 app 0.4.0 was rejected by plugin version")
	end)

	for _, stage in ipairs({ "discovery", "proof", "capability", "profile" }) do
		local failed_stage = stage
		for _, failure in ipairs({ "setup_failure", "setup_timeout", "setup_json_error" }) do
			local failed_kind = failure
			case("setup " .. failure .. " at " .. stage .. " never saves or polls a route", function(f)
				f[failed_kind] = failed_stage
				f:poll()
				expect(#f.requests == 0 and #f.writes == 0 and same_profile(f.kv.connection, profile("old")), "failed setup activated or saved a route")
				local probes = #f.setup_requests
				f:poll(); f:poll()
				expect(#f.setup_requests == probes, "failed discovery was repeated by the timer")
				expect(#f.toasts > 0 and f.toasts[#f.toasts].message:find("Configure", 1, true), "failure did not give install/configure advice")
			end)
		end
	end

	case("incompatible integration capability cannot commit configure candidate", function(f)
		f:bind(); f.integration_api = 2; f:save(profile("new"))
		expect(f:connection_writes() == 0 and same_profile(f.kv.connection, profile("old")), "incompatible native was saved")
		expect(f:poll().argv[1] == "/bin/pet-old", "failed capability check changed active executable")
	end)

	case("spawn permission failure leaves connection untouched", function(f)
		f.setup_spawn_error = true; f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and #f.toasts > 0, "permission failure silently activated a route")
	end)

	case("invalid locator is failclosed rather than PATH fallback", function(f, real)
		f.kv = {}
		f.discovery_stdout = "locator\n" .. real.json.encode({ version = 1, executable = "desktop-pet", kind = "source" })
		f:poll()
		expect(#f.setup_requests == 1 and #f.requests == 0 and #f.writes == 0, "invalid locator fell through to a different installation")
	end)

	case("private locator bootstrap delegates full discovery to signed helper", function(f, real)
		f.kv = {}
		f.discovery_stdout = "locator\n" .. real.json.encode({ version = 1, executable = "/app/DesktopPet.app/Contents/MacOS/desktop-pet", kind = "standalone" })
		local request = f:poll()
		local proof = f.setup_requests[2]
		expect(proof.argv[5] == "/app/DesktopPet.app/Contents/MacOS/desktop-pet" and proof.argv[6] == "", "locator bypassed helper-owned private locator proof")
		expect(request.argv[1] == "/app/DesktopPet.app/Contents/MacOS/desktop-pet" and #f.writes == 0, "locator route did not remain readonly")
	end)

	local function legacy_route()
		return { version = 1, executable = "/old/herdr-desktop-pet", config_dir = "/old/config", state_dir = "/old/state" }
	end

	local function approved_route()
		return { version = 1, kind = "legacy-migration-route", committed = true, original = legacy_route(),
			target = { version = 1, executable = "/bin/desktop-pet", config_dir = "/old/config", state_dir = "/old/state" } }
	end

	case("committed native approval migrates exact legacy route without prompts", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true
		local request = f:poll()
		expect(#f.prompts == 0 and #f.setup_requests == 5 and f:connection_writes() == 1, "approved migration required another acknowledgement or skipped proof")
		expect(request.argv[1] == "/bin/desktop-pet" and request.argv[4] == "/old/config" and request.argv[6] == "/old/state", "migration mixed the original route pair")
		expect(same_profile(f.kv.connection, approved_route().target), "migration did not atomically save its verified target")
		expect(request.body.instance_id == nil and #request.body.results == 0 and request.body.sequence == 1, "migration replayed a binding or report")
		f:ok(request); f:ok(f:poll())
		expect(#f.setup_requests == 5 and f:connection_writes() == 1 and #f.prompts == 0, "migration repeated proof, save, or prompts after cutover")
	end)

	case("legacy command name proof retains exact original spelling and paths", function(f, real)
		f.kv = { executable = "herdr-desktop-pet", config_dir = "/old/config", state_dir = "/old/state" }
		f.migration_available = true
		local request = f:poll()
		local original = real.json.decode(f.setup_requests[5].options.stdin)
		expect(original.executable == "herdr-desktop-pet", "legacy query invented an absolute source path")
		expect(f:connection_writes() == 1 and f.kv.executable == nil and f.kv.config_dir == nil and f.kv.state_dir == nil, "approved old tuple was not canonicalized as a whole")
		expect(request.argv[4] == "/old/config" and request.argv[6] == "/old/state", "old tuple migration changed native paths")
	end)

	case("unapproved legacy route stays unchanged and reconnects on later periodic proof", function(f)
		f.kv.connection = legacy_route()
		f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and #f.prompts == 0 and same_profile(f.kv.connection, legacy_route()), "discovered installation substituted for missing approval")
		expect(#f.toasts > 0 and f.toasts[#f.toasts].message:find("no committed approved route", 1, true), "missing native proof/provider was hidden as success")
		f.migration_available = true
		local request = f:poll()
		expect(request ~= nil and f:connection_writes() == 1 and #f.prompts == 0, "later native commit required manual Connect or Configure")
	end)

	for _, field in ipairs({ "executable", "config_dir", "state_dir" }) do
		local mismatched = field
		for _, side in ipairs({ "original", "target" }) do
			local route_side = side
			case("migration rejects mismatched " .. side .. " " .. field, function(f)
				f.kv.connection = legacy_route(); f.migration_available = true; f.migration_proof = approved_route()
				f.migration_proof[route_side][mismatched] = "/different/" .. mismatched
				f:poll()
				expect(#f.requests == 0 and #f.writes == 0 and #f.prompts == 0
					and same_profile(f.kv.connection, legacy_route()), "mismatched native proof committed a route")
			end)
		end
	end

	case("uncommitted migration cannot save a discovered route", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true; f.migration_proof = approved_route()
		f.migration_proof.committed = false; f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and same_profile(f.kv.connection, legacy_route()), "uncommitted route proof became installation authority")
	end)

	for _, failure in ipairs({ "setup_failure", "setup_timeout", "setup_json_error" }) do
		local failed_kind = failure
		case("migration " .. failure .. " preserves saved original and exposes failure", function(f)
			f.kv.connection = legacy_route(); f.migration_available = true; f[failed_kind] = "migration"
			f:poll()
			expect(#f.requests == 0 and #f.writes == 0 and #f.prompts == 0 and #f.toasts > 0
				and same_profile(f.kv.connection, legacy_route()), "failed migration proof changed the route or claimed success")
		end)
	end

	case("migration atomic save failure leaves original tuple intact", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true; f.save_error = true
		f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and same_profile(f.kv.connection, legacy_route()), "failed migration save partially cut over")
		f.save_error = false
		expect(f:poll() ~= nil and f:connection_writes() == 1, "atomic save failure required another approval")
	end)

	case("periodic migration does not overlap a pending native proof", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true; f.hold_migration = true
		f:poll(); f:poll(); f:poll()
		expect(#f.setup_requests == 5 and #f.requests == 0 and #f.writes == 0, "ticks overlapped a pending migration proof")
		f.hold_migration = false; f:complete_setup()
		expect(#f.requests == 1 and f:connection_writes() == 1, "pending migration proof did not cut over exactly once")
	end)

	case("stale migration proof cannot overwrite another window's route", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true; f.hold_migration = true
		f:poll()
		f.kv.connection = profile("external")
		f.hold_migration = false; f:complete_setup()
		expect(#f.requests == 0 and #f.writes == 0 and same_profile(f.kv.connection, profile("external")), "stale migration proof overwrote another window")
		local request = f:poll()
		expect(request.argv[1] == "/bin/pet-external" and request.argv[4] == "/config/external"
			and request.argv[6] == "/state/external", "next tick failed to validate the exact winning route")
	end)

	case("late migration proof is fenced by a newer cancelled Configure", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true; f.hold_migration = true
		f:poll(); f:configure(); f:answer(nil)
		f.hold_migration = false; f:complete_setup()
		expect(#f.requests == 0 and #f.writes == 0 and same_profile(f.kv.connection, legacy_route()), "obsolete migration proof survived newer setup")
		expect(f:poll() ~= nil and f:connection_writes() == 1, "cancelled manual proposal disabled native-approved automatic migration")
	end)

	case("active window automatically validates another window's atomic route without replay", function(f)
		f:bind(); f:offer()
		local old = f.requests[#f.requests]
		expect(#old.body.results == 1 and #f.asks == 1, "fixture lacks an uncertain pending result")
		f.kv.connection = profile("external")
		local fresh = f:poll()
		fresh_source(old, fresh)
		expect(fresh.argv[1] == "/bin/pet-external" and fresh.argv[4] == "/config/external"
			and fresh.argv[6] == "/state/external", "active window failed exact automatic reconnect")
		f:ok(old, { operation_id = "old-route", pane = "1", text = "never" })
		expect(#f.asks == 1 and #fresh.body.results == 0, "automatic reconnect replayed an old ask or result")
	end)

	case("active route replacement failure never falls back to discovery", function(f)
		f:bind(); f.kv.connection = profile("external"); f.setup_failure = "proof"
		f:poll()
		expect(#f.requests == 1 and #f.writes == 0 and #f.toasts > 0, "invalid replacement kept polling stale route or silently substituted")
		local probe = f.setup_requests[#f.setup_requests]
		expect(probe.argv[5] == "/bin/pet-external" and probe.argv[6] == "/bin/pet-external", "custom replacement became neutral discovery")
	end)

	case("custom executable is never replaced by discovered proposal", function(f)
		f:configure()
		expect(f.prompts[1].value == "/bin/pet-old" and #f.setup_requests == 0, "custom executable was replaced by discovery")
		f:answer(nil)
		expect(#f.writes == 0 and f.kv.connection.executable == "/bin/pet-old", "custom cancel changed saved executable")
	end)

	case("late discovery callback cannot overwrite another window or start exchange", function(f)
		f.hold_setup = true
		f:connect()
		f.kv.connection = profile("external")
		f.hold_setup = false
		f:complete_setup()
		expect(#f.requests == 0 and #f.writes == 0 and #f.setup_requests == 1, "late discovery crossed another window's profile boundary")
		local fresh = f:connect()
		expect(fresh.argv[1] == "/bin/pet-external", "explicit reconnect did not validate the winning object")
	end)

	case("late candidate verification cannot save after newer Configure cancels", function(f)
		f:bind()
		f:configure(); f:answer("/bin/pet-new"); f:answer("/config/new")
		f.hold_setup = true; f:answer("/state/new")
		f:configure(); f:answer(nil)
		f.hold_setup = false; f:complete_setup()
		expect(#f.writes == 0 and same_profile(f.kv.connection, profile("old")), "obsolete configure proof committed after cancellation")
		expect(#f.asks == 0, "obsolete configure generated replay")
	end)

end
