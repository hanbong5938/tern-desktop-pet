--!optimize 0
-- Loaded by transition-regressions.luau in a separate compile callback.
return function(shared)
	local case = shared.case
	local expect = shared.expect
	local profile = shared.profile
	local same_paths = shared.same_paths
	local same_profile = shared.same_profile
	local fresh_source = shared.fresh_source

	case("cold entry defers clock storage endpoint and process reads until startup", function(f)
		expect(#f.load_reads == 0 and #f.requests == 0 and #f.setup_requests == 0, "cold entry synchronously read live connection state")
		local request = f:poll()
		expect(type(request.body.window) == "string" and request.body.epoch > 0, "deferred startup failed to establish a fresh source")
	end)

	case("fresh defaults come only from verified readonly native profile", function(f)
		f.kv = {}
		local request = f:poll()
		expect(request.connection.config_dir == "/config/default"
			and request.connection.state_dir == "/state/default", "defaults were constructed by the plugin")
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
		expect(same_paths(f:poll().connection, profile("old")), "failed capability check changed active profile")
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
		expect(request ~= nil and #f.writes == 0, "locator route did not remain readonly")
	end)

	local function legacy_route()
		return { version = 1, executable = "/old/herdr-desktop-pet", config_dir = "/old/config", state_dir = "/old/state" }
	end

	local function approved_route()
		return { version = 1, kind = "legacy-migration-route", committed = true, original = legacy_route(),
			target = { version = 1, executable = "/bin/desktop-pet", config_dir = "/old/config", state_dir = "/old/state" } }
	end

	local function bind_handover(f)
		f.handover_protocol = 1; f.handover_available = true; f.migration_available = true
		local registration = f:poll()
		f:ok(registration)
		expect(#f.handover_requests == 0, "unbound registration or install ACK substituted for current-instance evidence")
		local bound = f:poll()
		f:ok(bound)
		return registration, bound
	end

	case("proof-bound handover requires loaded protocol SDK target and the actual same bound window", function(f)
		local original = legacy_route(); original.executable = "/opt/homebrew/bin/herdr-desktop-pet"
		f.kv.connection = original; f.missing_executables[original.executable] = true
		local registration, bound = bind_handover(f)
		expect(#f.handover_requests == 1 and #f.handover_receipts == 1
			and f:connection_writes() == 1 and #f.prompts == 0, "actual consumer handover was omitted or needed consent")
		local handover = f.handover_requests[1]
		expect(handover.body.loaded_protocol == 1 and handover.body.window_id == registration.body.window
			and handover.body.window_id == bound.body.window and bound.body.instance_id == handover.body.handover.target_instance_id,
			"handover borrowed another window/instance or omitted new-code protocol")
		expect(same_profile(handover.body.original, original) and same_profile(handover.body.target, f.kv.connection)
			and #f.missing_invocations == 0, "handover changed original profile or executed the missing alias")
	end)

	case("slow authenticated owner proof and handover still complete in the original window", function(f)
		local original = legacy_route(); original.executable = "/opt/homebrew/bin/herdr-desktop-pet"
		f.kv.connection = original; f.missing_executables[original.executable] = true
		f.setup_delays_ms = { migration = 16000 }; f.handover_delay_ms = 16000
		local registration, bound = bind_handover(f)
		expect(#f.handover_receipts == 1 and f:connection_writes() == 1 and #f.prompts == 0,
			"valid signed-owner validation was cut off before automatic handover")
		local receipt = f.handover_receipts[1]
		expect(receipt.window_id == registration.body.window and receipt.window_id == bound.body.window
			and receipt.handover.target_instance_id == bound.body.instance_id
			and same_profile(receipt.original, original) and same_profile(receipt.target, f.kv.connection),
			"slow approval borrowed another original route, window or native instance")
	end)

	case("native without handover capability never receives successor-only commands", function(f)
		f:bind()
		for _ = 1, 3 do f:ok(f:poll()) end
		expect(#f.handover_requests == 0 and f:route_queries() == 0, "published older native was probed through unsupported handover commands")
	end)

	case("no pending migration proof never interrupts a healthy current native binding", function(f)
		f.kv.connection = approved_route().target; f.handover_protocol = 1
		local first = f:bind(); f:ok(f:poll())
		local next_request = f:poll()
		expect(same_paths(next_request.connection, first.connection) and next_request.body.window == first.body.window
			and #f.handover_requests == 0 and #f.writes == 0 and #f.toasts == 0 and #f.logs > 0,
			"optional absence fabricated authority, changed healthy routing, or reported a false disconnect")
	end)

	case("unsaved verified defaults cannot be inferred as an approved handover route", function(f)
		f.kv = {}; f.handover_protocol = 1; f.handover_available = true; f.migration_available = true
		f:bind(); f:ok(f:poll())
		expect(f:route_queries() == 0 and #f.handover_requests == 0 and #f.writes == 0,
			"default discovery invented a captured saved route or silently saved a profile")
	end)

	case("bounded route probes discover a later handover on an already-current executable", function(f)
		f.kv.connection = approved_route().target; f.handover_protocol = 1; f.migration_available = true
		f:bind(); f:ok(f:poll())
		local probes = f:route_queries()
		expect(#f.handover_requests == 0, "absent handover authority was fabricated")
		f.handover_available = true; f:ok(f:poll())
		expect(f:route_queries() == probes, "optional authority polling ignored its bounded interval")
		f.clock += 10000; f:ok(f:poll())
		expect(f:route_queries() == probes + 1 and #f.handover_receipts == 1 and f:connection_writes() == 0,
			"later native Commit needed Configure or an unchanged canonical rewrite")
	end)

	case("already-current restart requires a result-free bound new-instance exchange before handover", function(f)
		f.kv.connection = approved_route().target; f.handover_protocol = 1; f.handover_available = true; f.migration_available = true
		f:bind()
		local old = f:poll(); f:reject(old, "instance_changed", "daemon-b"); f.native_instance = "daemon-b"
		local fresh = f:poll(); fresh_source(old, fresh); f:ok(fresh, nil, "daemon-b")
		expect(#f.handover_requests == 0, "restart registration was mistaken for a confirmed new-instance binding")
		f:ok(f:poll(), nil, "daemon-b")
		expect(#f.handover_receipts == 1 and f.handover_receipts[1].window_id == fresh.body.window
			and f.handover_receipts[1].handover.target_instance_id == "daemon-b" and f:connection_writes() == 0,
			"already-current restart did not prove its actual fresh instance/window")
	end)

	case("periodic exchanges never overlap a pending handover receipt", function(f)
		f.kv.connection = legacy_route(); f.hold_handover = true
		bind_handover(f)
		f.clock += 20000; f:ok(f:poll())
		expect(#f.handover_requests == 1, "ordinary exchanges overlapped a pending native handover")
		f:complete_handover()
		expect(#f.handover_receipts == 1, "pending same-window handover failed to settle once")
	end)

	case("malformed canonical change during handover never revives legacy settings", function(f)
		f.kv.connection = legacy_route(); f.hold_handover = true
		bind_handover(f)
		f.kv.connection = { version = 1, executable = "/custom/desktop-pet", config_dir = "/custom/config" }
		f.kv.executable = "herdr-desktop-pet"; f.kv.config_dir = "/old/config"; f.kv.state_dir = "/old/state"
		f:complete_handover()
		local probes = #f.setup_requests
		f:poll()
		expect(#f.handover_receipts == 0 and #f.setup_requests == probes
			and f:connection_writes() == 1 and f.kv.connection.state_dir == nil, "handover revived old keys or overwrote malformed canonical data")
	end)

	case("pending handover receipt cannot claim connection after custom settings win", function(f)
		f.kv.connection = legacy_route(); f.hold_handover = true
		bind_handover(f)
		local toasts = #f.toasts
		f.kv.connection = profile("external"); f:complete_handover()
		expect(#f.handover_receipts == 0 and #f.toasts == toasts and same_profile(f.kv.connection, profile("external")),
			"stale handover completion claimed connection or changed custom settings")
		expect(same_paths(f:poll().connection, profile("external")), "handover cancellation failed to honor the exact custom profile")
	end)

	for _, field in ipairs({ "operation_id", "plan_path", "plan_sha256", "token", "consumer_revision", "target_instance_id", "unknown", "missing" }) do
		local invalid_field = field
		case("optional handover strictly rejects malformed " .. field, function(f)
			f.kv.connection = legacy_route(); f.handover_protocol = 1; f.migration_available = true
			f.migration_proof = approved_route(); f.migration_proof.handover = f:handover_authority()
			if invalid_field == "unknown" then f.migration_proof.handover.extra = true
			elseif invalid_field == "missing" then f.migration_proof.handover.token = nil
			elseif invalid_field == "plan_path" then f.migration_proof.handover.plan_path = "relative"
			elseif invalid_field == "target_instance_id" then f.migration_proof.handover.target_instance_id = string.rep("x", 129)
			else f.migration_proof.handover[invalid_field] = "NOT-LOWERCASE-HEX" end
			f:poll()
			expect(#f.requests == 0 and #f.writes == 0 and #f.handover_requests == 0 and #f.toasts > 0,
				"malformed optional authority activated or saved a route")
		end)
	end

	case("handover waits until an uncertain receipt is consumed by a result-free bound snapshot", function(f)
		f.kv.connection = approved_route().target; f.handover_protocol = 1; f.migration_available = true
		f:bind(); f:ok(f:poll())
		-- Age the route-probe interval before creating the uncertain receipt:
		-- the next poll should query proof without expiring that new exchange.
		f.clock += 8000; f:offer()
		local receipt = f.requests[#f.requests]
		expect(#receipt.body.results == 1 and #f.asks == 1, "fixture lacks a real pending report")
		f.handover_available = true
		expect(f:poll() == receipt, "route proof polling replaced the pending exchange")
		f:ok(receipt)
		expect(#f.handover_requests == 0, "report-bearing snapshot substituted for result-free handover evidence")
		f:ok(f:poll())
		expect(#f.handover_receipts == 1 and #f.asks == 1, "fresh handover replayed an uncertain ask or never settled")
	end)

	for _, failure in ipairs({ "handover_denied", "handover_package_invalid", "handover_timeout", "handover_json_error" }) do
		local callback_failure = failure
		case("native " .. failure .. " remains visible and retries only after another bound exchange", function(f)
			f.kv.connection = legacy_route(); f[callback_failure] = true
			bind_handover(f)
			expect(#f.handover_requests == 1 and #f.toasts > 0 and f.toasts[#f.toasts].level == "error",
				"native handover failure became a fabricated success")
			local next_request = f:poll()
			expect(#f.handover_requests == 1, "handover retried without a later ordinary bound exchange")
			f:ok(next_request)
			expect(#f.handover_requests == 2 and f:connection_writes() == 1 and #f.prompts == 0,
				"bounded idempotent handover retry was lost or repeated consent/save")
			for _, query in ipairs(f.setup_requests) do
				expect(query.argv[2] ~= "start" and query.argv[2] ~= "resume" and query.argv[2] ~= "install",
					"handover defeated a native fence with a manager action")
			end
		end)
	end

	case("untrusted receipt echo cannot replace native same-window confirmation", function(f)
		f.kv.connection = legacy_route()
		f.handover_response = { version = 1, kind = "migration-integration-handover", confirmed = true,
			window_id = "unrelated-window", target_instance_id = "daemon-a" }
		bind_handover(f)
		expect(#f.toasts > 0 and f.toasts[#f.toasts].message:find("did not confirm", 1, true), "unrelated echo became confirmed handover")
		f:ok(f:poll())
		expect(f.toasts[#f.toasts].level == "error", "ordinary polling hid the unconfirmed handover")
	end)

	case("approved already-current old tuple canonicalizes then proves its post-save source", function(f)
		local target = approved_route().target
		f.kv = { executable = target.executable, config_dir = target.config_dir, state_dir = target.state_dir }
		local registration, bound = bind_handover(f)
		local fresh = f.requests[#f.requests]
		fresh_source(bound, fresh)
		expect(f:connection_writes() == 1 and same_profile(f.kv.connection, target) and #f.handover_requests == 0,
			"old tuple handover skipped its guarded SDK save or reused a pre-save binding")
		f:ok(fresh); f:ok(f:poll())
		expect(#f.handover_receipts == 1 and f.handover_receipts[1].window_id ~= registration.body.window,
			"canonicalized current route did not prove its post-save source")
	end)

	case("committed native approval migrates exact legacy route without prompts", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true
		local request = f:poll()
		expect(#f.prompts == 0 and #f.setup_requests == 5 and f:connection_writes() == 1, "approved migration required another acknowledgement or skipped proof")
		expect(same_paths(request.connection, legacy_route()), "migration mixed the original route pair")
		expect(same_profile(f.kv.connection, approved_route().target), "migration did not atomically save its verified target")
		expect(request.body.instance_id == nil and #request.body.results == 0 and request.body.sequence == 1, "migration replayed a binding or report")
		f:ok(request); f:ok(f:poll())
		expect(#f.setup_requests == 5 and f:connection_writes() == 1 and #f.prompts == 0, "migration repeated proof, save, or prompts after cutover")
	end)

	case("missing Brew alias automatically hands over the exact original profile tuple", function(f, real)
		local alias = "/opt/homebrew/bin/herdr-desktop-pet"
		f.kv = { executable = alias, config_dir = "/original/config", state_dir = "/original/state", unrelated = "keep" }
		f.missing_executables[alias] = true; f.migration_available = true
		f.native_instance = "committed-daemon"
		local request = f:poll()
		local original = real.json.decode(f.setup_requests[5].options.stdin)
		expect(original.executable == alias and original.config_dir == "/original/config"
			and original.state_dir == "/original/state", "missing alias proof lost the exact saved original")
		expect(#f.missing_invocations == 0 and #f.prompts == 0 and f:connection_writes() == 1,
			"missing alias was executed or required manual Configure")
		expect(request.connection.config_dir == "/original/config"
			and request.connection.state_dir == "/original/state" and f.kv.unrelated == "keep", "alias repair changed the original profile or unrelated settings")
		expect(request.body.instance_id == nil and #request.body.results == 0, "route save substituted for a fresh registration")
		expect(f:poll() == request and #f.requests == 1, "pending real exchange was mistaken for a completed binding")
		f:ok(request, nil, "committed-daemon")
		local bound = f:poll()
		expect(bound.body.instance_id == "committed-daemon" and bound.body.window == request.body.window,
			"actual current-daemon exchange did not establish the new binding")
	end)

	case("missing Brew alias without retained approval never borrows discovery authority", function(f)
		local original = legacy_route(); original.executable = "/opt/homebrew/bin/herdr-desktop-pet"
		f.kv.connection = original; f.missing_executables[original.executable] = true
		f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and #f.missing_invocations == 0
			and same_profile(f.kv.connection, original), "unapproved missing alias invoked or adopted a discovered route")
	end)

	case("reload timer and window startup share one pending approved handover", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true; f.hold_migration = true
		f:window_start(); f:poll(); f:poll()
		expect(#f.setup_requests == 5 and #f.requests == 0 and #f.writes == 0, "startup hooks overlapped native proof queries")
		f.hold_migration = false; f:complete_setup(); f:window_start()
		expect(#f.requests == 1 and #f.setup_requests == 5 and f:connection_writes() == 1, "startup restarted a completed handover")
	end)

	case("native Stop denial of delayed route proof cannot save or restart a profile", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true; f.hold_migration = true
		f:poll()
		-- Native rechecks its Stop fence when the read-only query completes.
		f.migration_available = false; f.hold_migration = false; f:complete_setup()
		f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and #f.prompts == 0 and same_profile(f.kv.connection, legacy_route()),
			"revoked native authority still cut over the saved profile")
		for _, query in ipairs(f.setup_requests) do
			expect(query.argv[2] ~= "start" and query.argv[2] ~= "ensure" and query.argv[2] ~= "stop"
				and query.argv[2] ~= "resume" and query.argv[2] ~= "install", "consumer defeated Stop with a native mutation")
		end
	end)

	case("legacy command name proof retains exact original spelling and paths", function(f, real)
		f.kv = { executable = "herdr-desktop-pet", config_dir = "/old/config", state_dir = "/old/state" }
		f.migration_available = true
		local request = f:poll()
		local original = real.json.decode(f.setup_requests[5].options.stdin)
		expect(original.executable == "herdr-desktop-pet", "legacy query invented an absolute source path")
		expect(f:connection_writes() == 1 and f.kv.executable == nil and f.kv.config_dir == nil and f.kv.state_dir == nil, "approved old tuple was not canonicalized as a whole")
		expect(request.connection.config_dir == "/old/config" and request.connection.state_dir == "/old/state", "old tuple migration changed native paths")
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
		expect(same_paths(request.connection, profile("external")), "next tick failed to validate the exact winning profile")
	end)

	case("malformed canonical change fences pending proof without reviving old keys", function(f)
		f.kv = { connection = legacy_route(), executable = "/old/herdr-desktop-pet",
			config_dir = "/old/config", state_dir = "/old/state" }
		f.migration_available = true; f.hold_migration = true; f:poll()
		f.kv.connection = { version = 1, executable = "/custom/desktop-pet", config_dir = "/custom/config" }
		f.hold_migration = false; f:complete_setup()
		local probes = #f.setup_requests
		f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and #f.setup_requests == probes
			and f.kv.connection.state_dir == nil and f.kv.executable == "/old/herdr-desktop-pet",
			"malformed canonical change was overwritten or fell back to legacy keys")
	end)

	case("superseded canonical save never activates or claims the discarded route", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true
		f.after_connection_save = function() f.kv.connection = profile("external") end
		f:poll()
		expect(f:connection_writes() == 1 and #f.requests == 0 and same_profile(f.kv.connection, profile("external")),
			"own-write verification activated a superseded route")
		for _, toast in ipairs(f.toasts) do expect(toast.title ~= "Desktop pet connected", "superseded route was reported connected") end
		f.after_connection_save = nil
		local request = f:poll()
		expect(same_paths(request.connection, profile("external")) and f:connection_writes() == 1, "winning custom profile was not validated unchanged")
	end)

	case("post-save read failure leaves the saved target inactive until exact revalidation", function(f)
		f.kv.connection = legacy_route(); f.migration_available = true
		f.after_connection_save = function() f.read_error = true end
		f:poll()
		expect(f:connection_writes() == 1 and #f.requests == 0 and same_profile(f.kv.connection, approved_route().target),
			"unreadable own-write was activated or discarded")
		local probes = #f.setup_requests
		f:poll(); f:poll()
		expect(#f.requests == 0 and #f.setup_requests == probes and f:connection_writes() == 1,
			"unreadable settings caused subprocess retries or activated an unverified route")
		f.after_connection_save = nil; f.read_error = false
		local request = f:poll()
		expect(same_paths(request.connection, legacy_route()) and f:connection_writes() == 1, "read recovery required another route rewrite or changed the profile")
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
		expect(same_paths(fresh.connection, profile("external")), "active window failed exact automatic reconnect")
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

	local function retained_neutral_route()
		return { version = 1,
			executable = "/opt/homebrew/Cellar/desktop-pet/0.4.8/libexec/DesktopPet.app/Contents/MacOS/desktop-pet",
			config_dir = "/old/config", state_dir = "/old/state" }
	end

	case("retained neutral canonical route migrates through exact native owner proof before old invocation", function(f, real)
		f.kv.connection = retained_neutral_route(); f.migration_available = true
		local request = f:poll()
		local query = f.setup_requests[5]
		expect(query.argv[2] == "legacy-migration-route"
			and real.json.decode(query.options.stdin).executable == retained_neutral_route().executable, "neutral repair lost exact old canonical executable")
		expect(#f.setup_requests == 5 and f:connection_writes() == 1 and #f.prompts == 0, "neutral migration invoked old route or required another approval")
		expect(same_paths(request.connection, retained_neutral_route()), "neutral repair substituted a different profile pair")
		expect(request.body.instance_id == nil and request.body.sequence == 1 and #request.body.results == 0, "neutral repair reused an old source or reports")
	end)

	case("missing retained neutral executable waits for later exact committed proof", function(f)
		f.kv.connection = retained_neutral_route()
		f.setup_failure = "proof"; f.setup_failure_route = retained_neutral_route().executable
		f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and #f.toasts > 0
			and same_profile(f.kv.connection, retained_neutral_route()), "missing neutral route was replaced without approval")
		f.migration_available = true
		local request = f:poll()
		expect(request ~= nil and same_profile(f.kv.connection, approved_route().target) and f:connection_writes() == 1
			and #f.prompts == 0, "later owner proof failed to reconnect missing canonical route automatically")
	end)

	case("removed neutral keg hands over before any obsolete executable invocation", function(f)
		f.kv.connection = retained_neutral_route()
		f.missing_executables[f.kv.connection.executable] = true; f.migration_available = true
		local request = f:poll()
		expect(#f.setup_requests == 5 and #f.missing_invocations == 0 and f:connection_writes() == 1,
			"removed keg was executed before authenticated current-owner proof")
		expect(same_paths(request.connection, retained_neutral_route()) and #f.prompts == 0, "removed-keg repair changed profile or required Configure")
	end)

	case("unbound custom route cannot borrow another migration proof", function(f)
		f.migration_available = true; f.migration_proof = approved_route(); f.setup_failure = "proof"
		f:poll(); f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and same_profile(f.kv.connection, profile("old")), "unbound custom route silently substituted discovered target")
		for _, query in ipairs(f.setup_requests) do
			expect(query.argv[2] ~= "legacy-migration-route", "ordinary custom route became a migration alias")
		end
	end)

	case("healthy neutral route without migration proof retains saved route and polling identity", function(f)
		f.kv.connection = retained_neutral_route()
		local first = f:bind()
		local probes = #f.setup_requests
		local next_request = f:poll()
		expect(same_paths(next_request.connection, retained_neutral_route())
			and next_request.body.window == first.body.window and #f.writes == 0, "missing proof changed healthy original route or source")
		expect(#f.setup_requests == probes, "healthy neutral polling repeated transport discovery")
	end)

	case("failed neutral repair preserves pending result until exact proof cuts over without replay", function(f)
		f.kv.connection = retained_neutral_route()
		f:bind(); f:offer()
		local receipt = f.requests[#f.requests]
		f:deliver(receipt, {}, { timed_out = true })
		f.migration_available = true; f.migration_proof = approved_route()
		f.migration_proof.original = retained_neutral_route()
		f.migration_proof.original.state_dir = "/different/state"
		local retained = f:poll()
		expect(same_profile(f.kv.connection, retained_neutral_route()) and #f.writes == 0
			and same_paths(retained.connection, retained_neutral_route()), "stale proof changed active neutral route")
		expect(retained.body.window == receipt.body.window and #retained.body.results == 1 and #f.asks == 1,
			"failed proof reset binding, dropped uncertain report, or replayed ask")
		f:deliver(retained, {}, { timed_out = true })
		f.migration_proof = nil
		local fresh = f:poll()
		fresh_source(retained, fresh)
		expect(same_profile(f.kv.connection, approved_route().target) and f:connection_writes() == 1
			and #f.asks == 1 and #fresh.body.results == 0, "successful exact proof replayed old delivery or failed atomic cutover")
	end)

	case("neutral daemon identity change schedules authenticated route repair", function(f)
		f.kv.connection = retained_neutral_route(); f:bind()
		local old = f:poll()
		f:reject(old, "instance_changed", "daemon-b")
		f.migration_available = true
		local fresh = f:poll()
		fresh_source(old, fresh)
		expect(same_profile(f.kv.connection, approved_route().target) and f:connection_writes() == 1 and #f.prompts == 0,
			"daemon identity change kept stale canonical route without consulting committed proof")
	end)

	case("already-current executable rebinds a restarted instance without rewriting settings", function(f)
		f.kv.connection = approved_route().target; f.migration_available = true
		f:bind(); f:offer()
		local old = f.requests[#f.requests]
		expect(#old.body.results == 1 and #f.asks == 1, "fixture lacks an uncertain old-instance receipt")
		f:reject(old, "instance_changed", "daemon-b")
		f.native_instance = "daemon-b"
		local fresh = f:poll()
		fresh_source(old, fresh)
		expect(same_paths(fresh.connection, approved_route().target) and f:connection_writes() == 0 and #f.prompts == 0,
			"same executable restart rewrote settings or required Configure")
		f:ok(old, { operation_id = "stale-instance", pane = "1", text = "never" }, "daemon-a")
		expect(#f.asks == 1 and f:poll() == fresh, "stale instance callback replayed delivery or bypassed pending registration")
		f:ok(fresh, nil, "daemon-b")
		local bound = f:poll()
		expect(bound.body.instance_id == "daemon-b" and bound.body.window == fresh.body.window
			and #bound.body.results == 0 and #f.asks == 1, "fresh current-instance exchange did not establish a clean binding")
	end)

	case("custom neutral basename cannot borrow an unrelated approved route", function(f)
		local custom = { version = 1, executable = "/custom/desktop-pet", config_dir = "/custom/config", state_dir = "/custom/state" }
		f.kv.connection = custom; f.migration_available = true; f.migration_proof = approved_route()
		local request = f:poll()
		expect(same_paths(request.connection, custom) and #f.writes == 0 and same_profile(f.kv.connection, custom),
			"unrelated native proof overwrote a custom executable sharing the neutral basename")
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
		expect(same_paths(fresh.connection, profile("external")), "explicit reconnect did not validate the winning profile")
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
