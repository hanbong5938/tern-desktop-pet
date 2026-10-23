--!optimize 0
-- Loaded by transition-regressions.luau in a separate compile callback.
return function(shared)
	local case = shared.case
	local expect = shared.expect
	local profile = shared.profile
	local same_profile = shared.same_profile
	local same_paths = shared.same_paths
	local host_inventory = shared.host_inventory
	local unchanged_source = shared.unchanged_source
	local fresh_source = shared.fresh_source
	local LIMIT = shared.LIMIT
	local encode_fixture = shared.encode_fixture

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
		f:deliver(lost, {}, { body = "truncated command JSON" })
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
		expect(same_paths(after.connection, profile("old")), "failed save mixed profile fields")
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
			expect(after.connection.state_dir == "/state/old", "cancel changed active profile")
		end)
	end

	case("whole candidate validation precedes canonical save", function(f)
		f:bind(); f:save({ executable = "/bin/new", config_dir = "relative", state_dir = "/state/new" })
		expect(f:connection_writes() == 0 and same_profile(f.kv.connection, profile("old")), "invalid candidate was committed")
		expect(f:poll().connection.config_dir == "/config/old", "invalid save changed live connection")
	end)

	case("successful save fences late success and preserves newer busy", function(f)
		f:bind(); local old = f:poll(); f:save(profile("new"))
		local fresh = f.requests[#f.requests]
		fresh_source(old, fresh)
		expect(f:connection_writes() == 1 and same_profile(f.kv.connection, profile("new"))
			and same_paths(fresh.connection, profile("new")), "save was not one whole-profile commit")
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
		f:poll(); local fresh = f:connect(); fresh_source(old, fresh)
		expect(same_paths(fresh.connection, profile("external")), "external connection was mixed")
		f:reject(old, "binding_required"); f:connect()
		expect(#f.requests == 3, "old recovery reset newer external busy")
		f:ok(fresh)
	end)

	case("external profile change before callback drops old command", function(f)
		f:bind(); local old = f:poll(); f.kv.connection = profile("external")
		f:ok(old, { operation_id = "old-profile", pane = "1", text = "never" })
		expect(#f.asks == 0, "delayed command crossed profile boundary")
		fresh_source(old, f:connect())
	end)

	case("profile rechecked immediately before semantic ask", function(f)
		f:bind(); local old = f:poll()
		f.inventory_hook = function() f.kv.connection = profile("external"); f.inventory_hook = nil end
		f:ok(old, { operation_id = "old-profile", pane = "1", text = "never" })
		expect(#f.asks == 0, "profile change during revalidation reached ask")
		fresh_source(old, f:connect())
	end)

	case("external save fences old prompt chain", function(f)
		f:bind(); f:configure(); f:answer("/bin/pet-new")
		f.kv.connection = profile("external"); f:answer("/config/new")
		expect(#f.prompts == 0 and f:connection_writes() == 0 and same_profile(f.kv.connection, profile("external")), "old prompt overwrote other window")
		expect(f:connect().connection.state_dir == "/state/external", "external profile was not explicitly validated")
	end)

	case("KV read failure blocks old command without mixing profiles", function(f)
		f:bind(); local old = f:poll(); f.read_error = true
		f:ok(old, { operation_id = "old", pane = "1", text = "never" }); f:configure(); f:poll()
		expect(#f.asks == 0 and #f.requests == 2 and #f.prompts == 0, "failed read used fallback or delivered command")
		f.read_error = false; local next_request = f:poll(); unchanged_source(old, next_request)
		expect(next_request.connection.state_dir == "/state/old", "failed read mixed profile")
	end)

	case("malformed canonical never falls back to legacy", function(f)
		f.kv.connection = { version = 1, executable = "/bin/broken", config_dir = "/config/broken" }
		f.kv.executable = "/bin/legacy"; f.kv.config_dir = "/config/legacy"; f.kv.state_dir = "/state/legacy"
		f:poll(); expect(#f.requests == 0 and #f.writes == 0, "malformed canonical fell back or was replaced")
		f:configure(); expect(f.prompts[1].value == "/bin/desktop-pet", "malformed fields leaked into repair form")
		f:answer(nil); expect(#f.writes == 0, "cancel replaced malformed canonical")
	end)

	case("malformed canonical can be repaired by one complete commit", function(f)
		f:bind()
		f.kv.connection = { version = 2, executable = "/bin/broken", config_dir = "/config/broken", state_dir = "/state/broken" }
		f:save(profile("repaired"))
		local fresh = f.requests[#f.requests]
		expect(f:connection_writes() == 1 and same_profile(f.kv.connection, profile("repaired")), "repair did not commit whole canonical object")
		expect(fresh.body.instance_id == nil and same_paths(fresh.connection, profile("repaired")), "repair retained broken fields or old binding")
	end)

	case("external malformed canonical blocks old command and fallback", function(f)
		f:bind(); local old = f:poll()
		f.kv.connection = { version = 1, executable = "/bin/broken", config_dir = "/config/broken" }
		f.kv.state_dir = "/state/legacy"
		f:ok(old, { operation_id = "old", pane = "1", text = "never" }); f:poll()
		expect(#f.asks == 0 and #f.requests == 2 and #f.writes == 0, "malformed external profile used active or legacy fallback")
	end)

	case("legacy custom tuple is not silently saved and commits only through Configure", function(f)
		f.kv = { executable = "/bin/legacy", config_dir = "/config/legacy", state_dir = "/state/legacy" }
		local connected = f:poll()
		expect(f:connection_writes() == 0 and f.kv.connection == nil, "Connect silently adopted old keys")
		expect(connected.connection.config_dir == "/config/legacy"
			and connected.connection.state_dir == "/state/legacy", "legacy custom route mixed tuple")
		f:ok(connected)
		f:save({ executable = "/bin/legacy", config_dir = "/config/legacy", state_dir = "/state/legacy" })
		expect(f:connection_writes() == 1 and f.writes[1].key == "connection", "legacy save was not one complete commit")
		expect(f.kv.executable == nil and f.kv.config_dir == nil and f.kv.state_dir == nil, "successful save did not clean old keys")
	end)

	case("failed explicit legacy save leaves every old key intact", function(f)
		f.kv = { executable = "/bin/legacy", config_dir = "/config/legacy", state_dir = "/state/legacy" }
		f:poll(); f.save_error = true
		f:save({ executable = "/bin/legacy", config_dir = "/config/legacy", state_dir = "/state/legacy" })
		expect(#f.writes == 0 and f.kv.connection == nil and f.kv.state_dir == "/state/legacy", "failed save erased or partially saved legacy keys")
	end)

	case("cleanup failure cannot roll back committed connection", function(f)
		f:bind(); f.cleanup_error = true; f:save(profile("new"))
		expect(f:connection_writes() == 1 and same_profile(f.kv.connection, profile("new"))
			and same_paths(f.requests[#f.requests].connection, profile("new")), "cleanup failure rolled back live cutover")
	end)

	case("remote inventory is observed but injected remote command calls neither get nor ask", function(f)
		f:bind(); local request = f:poll()
		expect(#request.body.hosts == 2 and #host_inventory(request).agents == 1
			and #host_inventory(request, "1").agents == 1
			and host_inventory(request, "1").agents[1].pane == "2", "remote agent was not independently observed")
		f:ok(request, { operation_id = "remote", pane = "2", text = "never" })
		local reported = f:poll()
		expect(#f.gets == 0 and #f.asks == 0 and reported.body.results[1].status == "failed", "remote command reached semantic get or ask")
	end)

	case("300 KiB command accepted unchanged", function(f)
		f:bind(); local text = string.rep("a", 300 * 1024); f:offer(text)
		expect(#f.asks == 1 and f.asks[1].text == text, "native-admitted large command was lost or changed")
	end)

	case("large Unicode and JSON escapes accepted unchanged", function(f)
		f:bind(); local text = string.rep('한🙂"\n\\', 30000); f:offer(text)
		expect(#f.asks == 1 and f.asks[1].text == text, "Unicode or escaped command was changed")
	end)

	local function boundary_response(f, real, request, delta)
		local response = f:response(request, { operation_id = "boundary", pane = "1", text = '🙂"\n\\' })
		local overhead = #encode_fixture(real, response, "measure response overhead") + 1
		response.command.text ..= string.rep("a", LIMIT - overhead + delta)
		local body = encode_fixture(real, response, "encode boundary HTTP body") .. "\n"
		expect(#body == LIMIT + delta, "fixture did not construct exact encoded HTTP body boundary")
		return response.command.text, body
	end

	case("512 KiB HTTP body including LF accepted", function(f, real)
		f:bind(); local pending = f:poll(); local text, body = boundary_response(f, real, pending, 0)
		f:deliver(pending, {}, { body = body })
		expect(#f.asks == 1 and f.asks[1].text == text, "exact response-byte boundary was rejected or changed")
	end)

	case("one byte over 512 KiB HTTP body rejected before ask", function(f, real)
		f:bind(); local pending = f:poll(); local _, body = boundary_response(f, real, pending, 1)
		f:deliver(pending, {}, { body = body })
		expect(#f.asks == 0, "oversized HTTP body reached ask")
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
		expect(#host_inventory(request).agents == 1, "snapshot omitted its complete local host inventory")
		local agent = host_inventory(request).agents[1]
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
		local fresh = f:connect()
		fresh_source(bound, fresh)
		expect(same_paths(fresh.connection, profile("external")), "new snapshot mixed connection fields")
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
		local fresh = f:connect()
		fresh_source(bound, fresh)
		expect_local_observation(fresh, "repaired")
		expect(fresh.connection.state_dir == "/state/repaired", "repair did not resume with the complete new profile")
	end)

	-- Configure now proves the installation asynchronously before its atomic
	-- save/reset. Complete that chain while the captured inventory stays held,
	-- so these cases exercise callbacks arriving after the identity cutover.
	local function save_before_releasing_inventory(f)
		local writes, setups, requests = f:connection_writes(), #f.setup_requests, #f.requests
		f.hold_setup = true
		f:save(profile("old"))
		expect(f:connection_writes() == writes, "same-profile save skipped installation proof")
		for _ = 1, 4 do f:complete_setup() end
		f.hold_setup = false
		expect(#f.setup_requests == setups + 4 and #f.setup_pending == 0
			and f:connection_writes() == writes + 1, "same-profile Configure did not complete its verified atomic save")
		expect(#f.requests == requests and f.hold_stages, "installation proof released captured inventory before cutover")
	end

	case("same-profile identity reset during snapshot inventory fences obsolete work", function(f)
		local bound = f:bind()
		local before = #f.requests
		f:hold(); f:poll(); f:through_inventory("sessions")
		replace_local_observation(f, "reset")
		save_before_releasing_inventory(f)
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
		local fresh = f:connect()
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
		save_before_releasing_inventory(f)
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
		expect(#f.gets == 0 and #f.asks == 0, "replacement pane received get or ask selected from old metadata")
		local reported = f:poll()
		expect(#host_inventory(reported).agents == 1 and host_inventory(reported).agents[1].title == "local replacement"
			and host_inventory(reported).agents[1].cwd == "/local", "fresh snapshot did not observe the replacement title")
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
		expect(#f.gets == 1 and #f.asks == 1, "pane moved out of the local host received get or ask for the old command")
		local moved_receipt = f:poll()
		expect(#host_inventory(moved_receipt).agents == 0 and #host_inventory(moved_receipt, "1").agents == 2
			and #moved_receipt.body.results == 1
			and moved_receipt.body.results[1].operation_id == "host-move"
			and moved_receipt.body.results[1].status == "failed", "current host membership did not exclude and reject the moved pane")
		f:ok(moved_receipt)
		f:ok(moved, { operation_id = "host-move", pane = "1", text = "never remote" })
		local after_move = f:poll()
		expect(#host_inventory(after_move).agents == 0 and #after_move.body.results == 0 and #f.asks == 1,
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

	case("dropped inventory continuation expires and late delivery cannot clear newer work", function(f)
		local bound = f:bind()
		f:hold(); f:poll(); f:through_inventory("sessions")
		local dropped = table.remove(f.stages, 1)
		expect(dropped ~= nil and dropped.microtask, "did not capture a real production continuation")
		f:release()
		expect(#f.requests == 1, "partial inventory submitted a request")
		f.clock += 10001
		local recovered = f:poll()
		fresh_source(bound, recovered)
		expect(#f.requests == 2, "dropped continuation left exchange ownership permanently busy")
		f:invoke(function(cx) dropped.callback(nil, nil, cx) end, "late inventory continuation")
		f:connect()
		expect(#f.requests == 2 and #f.asks == 0, "late continuation released newer exchange or delivered an ask")
		f:ok(recovered)
		expect(f:poll().body.instance_id == "daemon-a", "new source failed to resume polling")
	end)

	case("lost HTTP completion expires without replaying a delayed offered command", function(f)
		f:bind()
		local lost = f:poll()
		f.clock += 10001
		local recovered = f:poll()
		fresh_source(lost, recovered)
		f:ok(lost, { operation_id = "lost-completion", pane = "1", text = "never replay" })
		f:connect()
		expect(#f.requests == 3 and #f.asks == 0, "late HTTP completion crossed expired source or cleared newer work")
		f:ok(recovered)
		f:offer("new source only", "after-expiry")
		expect(#f.asks == 1 and f.asks[1].text == "new source only", "recovery did not preserve one-shot delivery")
	end)

	case("dropped command revalidation retires uncertain operation and never asks on late continuation", function(f)
		f:bind()
		local offered = f:poll()
		f:hold(); f:ok(offered, { operation_id = "lost-revalidation", pane = "1", text = "never replay" })
		f:through_inventory("agents")
		local dropped = table.remove(f.stages, 1)
		expect(dropped ~= nil, "revalidation had no production continuation to drop")
		f:release()
		f.clock += 10001
		local recovered = f:poll()
		fresh_source(offered, recovered)
		f:invoke(function(cx) dropped.callback(nil, nil, cx) end, "late revalidation continuation")
		f:ok(offered, { operation_id = "lost-revalidation", pane = "1", text = "never replay" })
		f:connect()
		expect(#f.asks == 0 and #f.requests == 3 and #recovered.body.results == 0,
			"expired revalidation replayed an ask, fabricated a receipt, or cleared newer work")
	end)

	case("explicit Connect expires lost work when timer lane is disabled", function(f)
		f:bind()
		local lost = f:poll()
		f.timers_disabled = true
		f.clock += 10001
		local recovered = f:connect()
		fresh_source(lost, recovered)
		f:ok(lost, { operation_id = "late-timer", pane = "1", text = "never" })
		f:connect()
		expect(#f.requests == 3 and #f.asks == 0, "Connect did not fence expired timer-owned work")
		f:ok(recovered)
	end)

	case("host-disabled await lane stays disabled and deadline reports reload requirement", function(f)
		f:bind()
		local lost = f:poll()
		local before = #f.requests
		f.awaits_disabled = true
		f.clock += 10001
		f:poll(); f:connect()
		f:ok(lost, { operation_id = "disabled-await", pane = "1", text = "never" })
		expect(#f.requests == before and #f.asks == 0 and f.awaits_disabled and not f.timers_disabled,
			"fixture silently revived a globally disabled await lane")
		local reported = false
		for _, message in ipairs(f.logs) do
			if message:find("reload the plugin", 1, true) then reported = true end
		end
		expect(reported, "lost progress concealed the host-level reload requirement")
	end)

	case("shared KV, SDK inventory and JSON encoding do not accumulate in one observation callback", function(f)
		f:bind()
		f.kv_cost_ms, f.inventory_cost_ms, f.json_cost_ms, f.budget_ms = 24, 30, 20, 50
		local request = f:poll()
		expect(#request.body.hosts == 2 and #f.requests == 2, "isolated inventory stages did not submit a complete snapshot")
		f:ok(request)
		local event_request = f:event("title")
		expect(#f.requests == 3 and event_request ~= request, "window event failed to schedule a fresh inventory")
		expect(f.disabled_hooks == 0, "shared KV, inventory or codec work accumulated beyond one callback budget")
		for _, sample in ipairs(f.callback_samples) do
			if sample.origin == "poll timer" or sample.origin == "event title" then
				expect(sample.cost_ms == 0, "timer/event synchronously accessed shared KV or inventory")
			end
		end
	end)

	case("large multi-host inventory completes CPU chunks without omitting host membership", function(f)
		f:bind()
		f.inventory = { hosts = {}, panes = {}, tabs = {}, sessions = {}, agents = {} }
		local count = 0
		for host_id = 0, 15 do
			local host = { id = host_id, name = "Host " .. host_id, kind = host_id == 0 and "local" or "remote",
				state = "connected", panes = {} }
			table.insert(f.inventory.hosts, host)
			for index = 1, 32 do
				count += 1
				table.insert(host.panes, count)
				table.insert(f.inventory.panes, { pane = count, title = "agent " .. count })
				table.insert(f.inventory.agents, { pane = count, cwd = "/work", state = "idle" })
			end
		end
		local request = f:poll()
		expect(#request.body.hosts == 16 and #f.requests == 2, "large production inventory failed to settle")
		local total = 0
		for _, host in ipairs(request.body.hosts) do
			expect(host.status == "available" and #host.agents == 32, "CPU chunk lost a complete host inventory")
			total += #host.agents
		end
		expect(total == count, "large inventory lost or duplicated agents across chunks")
		f:ok(request)
	end)

	case("profile cutover after transport validation blocks an old-route request", function(f)
		-- Observe the real SDK side-effect boundary once, then change KV immediately
		-- before that work callback in a second fixture. No source/closure inspection.
		local baseline = f:fork()
		baseline:bind(); baseline:hold(); baseline:poll()
		local steps = 0
		while #baseline.requests == 1 do
			expect(baseline:step(), "baseline snapshot stalled before HTTP submission")
			steps += 1
			expect(steps <= 128, "baseline snapshot did not settle")
		end
		f:bind(); f:hold(); f:poll()
		for _ = 1, steps - 1 do expect(f:step(), "snapshot stalled before transport gap") end
		expect(#f.requests == 1, "targeted cut was not before HTTP submission")
		f.kv.connection = profile("cutover")
		f:release()
		expect(#f.requests == 1 and #f.asks == 0,
			"profile changed after validation but an old-route request escaped")
	end)

	case("profile cutover after command validation blocks semantic ask", function(f)
		local command = { operation_id = "boundary-cut", pane = "1", text = "never cross profiles" }
		local baseline = f:fork()
		baseline:bind()
		local offered = baseline:poll()
		baseline:hold(); baseline:ok(offered, command)
		local steps = 0
		while #baseline.asks == 0 do
			expect(baseline:step(), "baseline command stalled before semantic ask")
			steps += 1
			expect(steps <= 128, "baseline command did not settle")
		end
		f:bind()
		offered = f:poll()
		f:hold(); f:ok(offered, command)
		for _ = 1, steps - 1 do expect(f:step(), "command stalled before ask gap") end
		expect(#f.asks == 0, "targeted cut was not before semantic ask")
		f.kv.connection = profile("cutover")
		f:release()
		expect(#f.asks == 0 and #f.requests == 2,
			"profile changed after validation but semantic ask escaped")
	end)

	for _, change in ipairs({
		{ name = "pane moved to another tab and session", apply = function(f)
			f.inventory.panes[1].tab = 99
			f.inventory.tabs[1] = { id = 99, name = "new tab" }
			f.inventory.sessions[1] = { id = 999, name = "new session", tabs = { 99 } }
		end },
		{ name = "whole tab moved to another session", apply = function(f)
			f.inventory.sessions[1] = { id = 999, name = "new session", tabs = { 10 } }
		end },
		{ name = "pane parked", apply = function(f)
			f.inventory.panes[1].tab = nil
		end },
		{ name = "pane renamed", apply = function(f)
			f.inventory.panes[1].title = "replacement"
		end },
		{ name = "pane closed", apply = function(f)
			table.remove(f.inventory.panes, 1)
		end },
		{ name = "session membership became ambiguous", apply = function(f)
			table.insert(f.inventory.sessions[2].tabs, 10)
		end },
		{ name = "pane lookup failed", apply = function(f)
			f.pane_lookup_error = true
		end },
	}) do
		case("final delivery rejects " .. change.name .. " after inventory capture", function(f)
			f:bind()
			local offered = f:poll()
			local command = { operation_id = "after-capture", pane = "1", text = "do not send stale target" }
			f:hold(); f:ok(offered, command)
			-- Ignore the preceding observation's final panes read.
			f.inventory_reads = {}
			f:through_inventory("panes")
			change.apply(f)
			f:release()
			expect(#f.gets == 0 and #f.asks == 0, "captured identity bypassed final target validation")
			local receipt = f.requests[#f.requests]
			expect(#receipt.body.results == 1 and receipt.body.results[1].operation_id == command.operation_id
				and receipt.body.results[1].status == "failed", "target change did not produce one failed receipt")
			f:ok(offered, command); f:connect()
			expect(f.requests[#f.requests] == receipt and #f.asks == 0, "late offer reopened rejected delivery")
			f:ok(receipt)
			expect(#f:poll().body.results == 0 and #f.asks == 0, "confirmed rejection replayed a receipt or ask")
		end)
	end

	case("unchanged parked pane retains one-shot semantic delivery", function(f)
		f.inventory.panes[1].tab = nil
		f:bind()
		local offered = f:offer("parked target", "parked-once")
		local receipt = f.requests[#f.requests]
		expect(#f.asks == 1 and f.asks[1].text == "parked target"
			and receipt.body.results[1].status == "accepted", "stable parked target was treated as a changed pane")
		f:ok(offered, { operation_id = "parked-once", pane = "1", text = "parked target" })
		expect(#f.asks == 1 and f.requests[#f.requests] == receipt, "duplicate offer replayed parked delivery")
	end)

	case("regular inventory polling never starts a process after signed setup", function(f)
		f:bind()
		local setup_launches = #f.process_launches
		for _ = 1, 3 do f:ok(f:poll()) end
		f:offer("HTTP semantic ask", "http-once")
		f:ok(f.requests[#f.requests])
		expect(#f.asks == 1 and #f.process_launches == setup_launches, "regular exchange launched a process or lost semantic delivery")
	end)

	for _, invalid in ipairs({
		{ name = "missing version", key = "version" },
		{ name = "future version", key = "version", value = 2 },
		{ name = "string version", key = "version", value = "1" },
		{ name = "wrong config", key = "config_dir", value = "/another/config" },
		{ name = "wrong state", key = "state_dir", value = "/another/state" },
		{ name = "missing token", key = "token" },
		{ name = "short token", key = "token", value = string.rep("a", 63) },
		{ name = "uppercase token", key = "token", value = string.rep("A", 64) },
		{ name = "nonhex token", key = "token", value = string.rep("g", 64) },
		{ name = "missing instance", key = "instance_id" },
		{ name = "empty instance", key = "instance_id", value = "" },
		{ name = "control instance", key = "instance_id", value = "daemon\nbad" },
		{ name = "long instance", key = "instance_id", value = string.rep("a", 129) },
		{ name = "unknown field", key = "extra", value = "ignored" },
	}) do
		case("endpoint rejects " .. invalid.name .. " without route mutation or subprocess fallback", function(f)
			f.endpoint_edit = function(endpoint) endpoint[invalid.key] = invalid.value end
			f:poll()
			expect(#f.requests == 0 and #f.writes == 0 and #f.asks == 0 and #f.toasts > 0, "invalid endpoint authorized a request or changed the profile")
		end)
	end

	for _, url in ipairs({
		"https://127.0.0.1:43127/extension", "http://localhost:43127/extension",
		"http://127.0.0.2:43127/extension", "http://[::1]:43127/extension",
		"http://127.0.0.1:0/extension", "http://127.0.0.1:65536/extension",
		"http://127.0.0.1:043127/extension", "http://127.0.0.1:43127/extension?profile=other",
		"http://127.0.0.1:43127/extension#fragment", "http://127.0.0.1:43127/extension/",
		"http://127.0.0.1:43127/stop", "http://user@127.0.0.1:43127/extension",
		"http://127.0.0.1:43127@evil.test/extension", "http://2130706433:43127/extension",
	}) do
		case("unsafe endpoint URL is rejected: " .. url, function(f)
			f.endpoint_edit = function(endpoint) endpoint.url = url end
			f:poll()
			expect(#f.requests == 0 and #f.writes == 0 and #f.asks == 0, "unsafe URL received private bearer or inventory")
		end)
	end

	for _, malformed in ipairs({ "not JSON", "[]", "null",
		'{"version":1,"version":1}', '{"version":1,"extra":null}',
		'{"version":1,"\\u0076ersion":1}' }) do
		case("malformed or ambiguous endpoint keys fail closed: " .. malformed, function(f)
			f.endpoint_bytes = malformed
			f:poll()
			expect(#f.requests == 0 and #f.writes == 0 and #f.asks == 0, "malformed descriptor granted endpoint authority")
		end)
	end

	case("complete duplicate and null unknown endpoint fields cannot disappear during decode", function(f, real)
		local bytes = encode_fixture(real, f:descriptor(profile("old")))
		for _, addition in ipairs({ ',"version":1}', ',"token":"' .. string.rep("b", 64) .. '"}', ',"extra":null}' }) do
			f.endpoint_bytes = bytes:sub(1, -2) .. addition
			f:poll()
			expect(#f.requests == 0 and #f.writes == 0, "decoder merged duplicate or dropped unknown endpoint authority")
		end
	end)

	for _, delta in ipairs({ 0, 1 }) do
		case("endpoint bounded read at 4096 bytes plus " .. delta, function(f, real)
			local bytes = encode_fixture(real, f:descriptor(profile("old")))
			f.endpoint_bytes = string.rep(" ", 4096 + delta - #bytes) .. bytes
			local request = f:poll()
			expect(#f.requests == (delta == 0 and 1 or 0), "descriptor byte cap was not enforced at the filesystem boundary")
			if delta == 0 then f:ok(request) end
		end)
	end

	case("missing endpoint is actionable unsupported-native failure with no subprocess fallback", function(f)
		f.endpoint_error = true
		f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and #f.toasts > 0, "unsupported native endpoint absence was hidden or retried through processes")
		f.endpoint_error = false
		expect(f:poll() ~= nil, "endpoint publication could not recover on an ordinary poll")
	end)

	case("missing Tern HTTP capability fails closed with actionable upgrade advice", function(f)
		f.api.fetch = nil
		f:poll()
		expect(#f.requests == 0 and #f.writes == 0 and #f.toasts > 0, "missing SDK capability fell back to a process")
	end)

	case("profile replacement during final descriptor read cannot send old inventory or bearer", function(f)
		f:bind()
		local reads = 0
		f.endpoint_read_hook = function()
			reads += 1
			if reads == 2 then f.kv.connection = profile("external") end
		end
		f:poll()
		expect(#f.requests == 1 and #f.asks == 0 and #f.writes == 0, "final descriptor read crossed a saved-profile fence")
		f.endpoint_read_hook = nil
		local fresh = f:poll()
		expect(same_paths(fresh.connection, profile("external")), "winning original profile was not revalidated")
	end)

	case("descriptor replacement between validation and HTTP side effect sends nothing and never retries", function(f)
		f:bind()
		local reads = 0
		f.endpoint_read_hook = function()
			reads += 1
			if reads == 1 then f.native_instance = "daemon-b" end
		end
		f:poll()
		expect(#f.requests == 1 and #f.asks == 0 and #f.writes == 0, "changed descriptor was used without validation or automatically retried")
		f.endpoint_read_hook = nil
		f:poll()
		expect(#f.requests == 1, "restart replayed inventory under the old binding")
		local fresh = f:poll()
		fresh_source(f.requests[1], fresh)
		f:ok(fresh)
	end)

	case("daemon descriptor restart discards uncertain reports before sending to the new instance", function(f)
		f:bind(); f:offer()
		local old = f.requests[#f.requests]
		f:deliver(old, {}, { error = "connection lost after sending" })
		f.native_instance = "daemon-b"; f.server_token = string.rep("b", 64)
		local before = #f.requests
		f:poll()
		expect(#f.requests == before and #f.asks == 1 and #f.writes == 0, "restart sent uncertain receipts to the new daemon or rewrote profile")
		local fresh = f:poll()
		fresh_source(old, fresh)
		f:ok(fresh)
		local bound = f:poll()
		expect(bound.body.instance_id == "daemon-b" and #bound.body.results == 0, "new instance did not establish a clean binding")
		f:ok(old, { operation_id = "late-old", pane = "1", text = "never" }, "daemon-a")
		expect(#f.asks == 1 and f:poll() == bound, "late old-instance response replayed an ask or cleared newer busy")
	end)

	case("old HTTP success after descriptor restart cannot deliver its offered ask", function(f)
		f:bind()
		local old = f:poll()
		f.native_instance = "daemon-b"
		f:ok(old, { operation_id = "stale-success", pane = "1", text = "never" }, "daemon-a")
		expect(#f.asks == 0 and #f.requests == 2 and #f.writes == 0, "queued old-instance success delivered after restart")
		local fresh = f:poll()
		fresh_source(old, fresh)
		f:ok(fresh)
	end)

	case("descriptor restart after command validation fences the final semantic ask", function(f)
		f:bind()
		local offered = f:poll()
		f:hold(); f:ok(offered, { operation_id = "restart-staged", pane = "1", text = "never" })
		f.inventory_reads = {}
		f:through_inventory("panes")
		f.native_instance = "daemon-b"
		f:release()
		expect(#f.asks == 0 and #f.requests == 2, "staged ask outlived its native descriptor")
		fresh_source(offered, f:poll())
	end)

	case("profile replacement during final endpoint read fences semantic delivery", function(f)
		f:bind()
		local offered = f:poll()
		f:hold(); f:ok(offered, { operation_id = "endpoint-profile-cut", pane = "1", text = "never cross profiles" })
		f.inventory_reads = {}
		f:through_inventory("panes")
		f.endpoint_read_hook = function() f.kv.connection = profile("external") end
		f:release()
		expect(#f.asks == 0 and #f.requests == 2, "endpoint read let an obsolete profile deliver an ask")
		f.endpoint_read_hook = nil
		local fresh = f:poll()
		fresh_source(offered, fresh)
		expect(same_paths(fresh.connection, profile("external")), "winning profile was not revalidated after endpoint read")
	end)

	case("wrong valid-shaped bearer receives HTTP401 without ask replay or automatic retry", function(f)
		f:bind(); f:offer()
		local receipt = f.requests[#f.requests]
		f:deliver(receipt, {}, { error = "response lost" })
		f.endpoint = f:descriptor(profile("old")); f.endpoint.token = string.rep("b", 64)
		local denied = f:poll()
		local count = #f.requests
		f:ok(denied, { operation_id = "unauthenticated", pane = "1", text = "never" })
		expect(#f.requests == count and #f.asks == 1 and #f.writes == 0, "authentication failure replayed or dispatched an ask")
		f.endpoint = nil
		local resumed = f:poll()
		unchanged_source(denied, resumed)
		expect(#resumed.body.results == 1 and #f.asks == 1, "authentication failure lost recoverable receipt or replayed delivery")
		f:ok(resumed)
	end)

	for _, failure in ipairs({ { status = 403 }, { status = 500 }, { status = 302 },
		{ status = 0, error = "private failure" }, { fetch_error = "private failure" }, { timed_out = true } }) do
		case("HTTP transport failure grants no command authority " .. tostring(failure.status or failure.fetch_error or failure.timed_out), function(f)
			f:bind()
			local offered = f:poll()
			local count = #f.requests
			f:deliver(offered, f:response(offered, { operation_id = "failure-body", pane = "1", text = "never" }), failure)
			expect(#f.asks == 0 and #f.requests == count and #f.writes == 0, "HTTP error body authorized command or triggered retry")
			for _, message in ipairs(f.logs) do expect(not message:find("private failure", 1, true), "SDK transport error leaked private data") end
		end)
	end

	case("fetch registration failure releases ownership without exposing request secrets", function(f)
		f:bind()
		f.fetch_start_error = true
		f:poll()
		expect(#f.requests == 1 and #f.asks == 0 and #f.writes == 0, "failed HTTP registration started or replayed work")
		for _, message in ipairs(f.logs) do expect(not message:find("private data", 1, true), "fetch registration error leaked SDK details") end
		f.fetch_start_error = false
		expect(#f:poll().body.results == 0, "registration failure kept exchange permanently busy")
	end)

	for index, environment in ipairs({
		{ HTTP_PROXY = "http://proxy.invalid" },
		{ all_proxy = "socks5://proxy.invalid", NO_PROXY = "localhost" },
		{ HTTPS_PROXY = "http://proxy.invalid", no_proxy = ".127.0.0.1" },
		{ http_proxy = "http://proxy.invalid", NO_PROXY = "127.0.0.1.evil" },
		{ ALL_PROXY = "http://proxy.invalid", NO_PROXY = "127.0.0.1", no_proxy = "" },
		{ HTTP_PROXY = "http://proxy.invalid", NO_PROXY = "", no_proxy = "*" },
	}) do
		case("proxy environment without unambiguous literal loopback exemption sends nothing " .. index, function(f)
			f.environment = environment
			f:poll()
			expect(#f.requests == 0 and #f.writes == 0 and #f.asks == 0, "private inventory or bearer could escape through a proxy")
			for _, message in ipairs(f.logs) do expect(not message:find("proxy.invalid", 1, true), "proxy settings leaked in diagnostics") end
		end)
	end

	for index, environment in ipairs({
		{ HTTP_PROXY = "http://proxy.invalid", NO_PROXY = "localhost, 127.0.0.1" },
		{ all_proxy = "socks5://proxy.invalid", no_proxy = "*" },
		{ HTTPS_PROXY = "http://proxy.invalid", NO_PROXY = "*", no_proxy = "127.0.0.1" },
	}) do
		case("explicit literal loopback proxy exemption preserves direct HTTP operation " .. index, function(f)
			f.environment = environment
			f:bind(); f:offer()
			expect(#f.asks == 1 and #f.writes == 0, "safe loopback exemption disabled regular semantic delivery")
		end)
	end

end
