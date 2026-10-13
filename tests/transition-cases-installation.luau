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

	case("legacy Herdr executable migration is proposed and saved only on consent", function(f)
		f.kv.connection = { version = 1, executable = "/old/herdr-desktop-pet", config_dir = "/old/config", state_dir = "/old/state" }
		f:poll()
		expect(#f.setup_requests == 0 and #f.requests == 0 and #f.writes == 0, "Connect treated legacy name as a neutral discovery alias")
		f:configure()
		expect(f.prompts[1].value == "/bin/desktop-pet", "Configure did not propose neutral executable")
		f:answer("/bin/desktop-pet")
		expect(f.prompts[1].value == "/old/config", "migration lost existing config")
		f:answer("/old/config")
		expect(f.prompts[1].value == "/old/state", "migration lost existing state")
		f:answer(nil)
		expect(f.kv.connection.executable == "/old/herdr-desktop-pet" and #f.writes == 0, "cancel committed migration")
		f:save({ executable = "/bin/desktop-pet", config_dir = "/old/config", state_dir = "/old/state" })
		expect(f:connection_writes() == 1 and f.kv.connection.config_dir == "/old/config" and f.kv.connection.state_dir == "/old/state", "consented migration was not one whole tuple")
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
