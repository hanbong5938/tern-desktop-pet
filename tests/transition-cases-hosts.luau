--!optimize 0
-- Loaded by transition-regressions.luau in a separate compile callback.
return function(shared)
	local case = shared.case
	local expect = shared.expect
	local host_inventory = shared.host_inventory
	local unchanged_source = shared.unchanged_source
	local fresh_source = shared.fresh_source
	local LIMIT = shared.LIMIT
	local encode_fixture = shared.encode_fixture

	local function add_remote_b(f)
		table.insert(f.inventory.hosts, { id = 2, name = "Remote B", kind = "remote",
			state = "connected", address = "b@mini", panes = { 3 } })
		table.insert(f.inventory.panes, { pane = 3, title = "remote b", tab = 30 })
		table.insert(f.inventory.tabs, { id = 30, name = "remote b tab" })
		table.insert(f.inventory.sessions, { id = 300, name = "remote b session", tabs = { 30 } })
		table.insert(f.inventory.agents, { pane = 3, cwd = "/remote/b", state = "waiting_input" })
		f.native_generations["2"] = 17
	end

	case("all connected SDK hosts are observed in one helper with exact locality and labels", function(f)
		add_remote_b(f)
		local first = f:bind()
		expect(#f.requests == 1 and #first.body.hosts == 3, "collection split hosts into helpers or omitted a host")
		for index, id in ipairs({ "0", "1", "2" }) do
			local host = host_inventory(first, id)
			expect(host.observation_generation == 1 and host.status == "available" and #host.agents == 1,
				"connected host did not start with one complete generation-1 inventory")
			expect(host.is_local == (index == 1), "host locality did not follow SDK kind")
		end
		expect(host_inventory(first).label == "Local" and host_inventory(first, "1").label == "Remote A"
			and host_inventory(first, "2").label == "Remote B", "host labels were conflated")
		expect(table.concat(f.inventory_reads, ",") == "tabs,sessions,agents,hosts,panes",
			"collection did not preserve the final authoritative membership stage")
		local before = #f.requests
		local next_request = f:poll()
		expect(#f.requests == before + 1 and #next_request.body.hosts == 3, "poll created a per-host helper")
	end)

	case("connected empty remote host is available rather than unavailable", function(f)
		f:bind()
		table.remove(f.inventory.agents, 2)
		local empty = f:poll()
		expect(host_inventory(empty, "1").status == "available" and #host_inventory(empty, "1").agents == 0
			and host_inventory(empty, "1").observation_generation == 1, "empty connected host was treated as observation loss")
		expect(#host_inventory(empty).agents == 1, "empty remote host altered local inventory")
		f:ok(empty)
		table.insert(f.inventory.agents, { pane = 2, cwd = "/remote", state = "idle" })
		expect(host_inventory(f:poll(), "1").observation_generation == 1, "normal empty snapshot retired the host generation")
	end)

	for _, state in ipairs({ "connecting", "stalled", "verify", "reconnecting", "failed" }) do
		local disconnected_state = state
		case("remote SDK " .. state .. " preserves local pending and increments only on recovery", function(f)
			add_remote_b(f); local bound = f:bind()
			f:offer("local survives", "local-pending")
			local pending = f.requests[#f.requests]
			f:reject(pending, "rejected")
			f.inventory.hosts[2].state = disconnected_state
			local lost = f:poll()
			unchanged_source(bound, lost)
			expect(host_inventory(lost, "1").status == "disconnected" and #host_inventory(lost, "1").agents == 0
				and host_inventory(lost, "1").observation_generation == 1, "nonconnected host advertised stale agents or advanced on loss")
			expect(host_inventory(lost).observation_generation == 1 and host_inventory(lost, "2").observation_generation == 1
				and #lost.body.results == 1 and #f.asks == 1 and #f.gets == 1, "remote disconnect discarded or repeated local delivery")
			f:ok(lost)
			f.inventory.hosts[2].state = "connected"
			local recovered = f:poll()
			expect(host_inventory(recovered, "1").observation_generation == 2
				and host_inventory(recovered).observation_generation == 1
				and host_inventory(recovered, "2").observation_generation == 1
				and #recovered.body.results == 0, "remote recovery changed unrelated generations or replayed receipt")
		end)
	end

	local metadata_failures = {
		{ name = "missing cwd", break_inventory = function(f) f.inventory.agents[2].cwd = nil end },
		{ name = "missing pane", break_inventory = function(f) table.remove(f.inventory.panes, 2) end },
		{ name = "invalid title", break_inventory = function(f) f.inventory.panes[2].title = false end },
		{ name = "unknown agent state", break_inventory = function(f) f.inventory.agents[2].state = "invented" end },
		{ name = "invalid delivery metadata", break_inventory = function(f) f.inventory.agents[2].delivery_error = {} end },
		{ name = "duplicate agent", break_inventory = function(f) table.insert(f.inventory.agents, { pane = 2, cwd = "/remote", state = "idle" }) end },
		{ name = "duplicate pane", break_inventory = function(f) table.insert(f.inventory.panes, { pane = 2, title = "duplicate", tab = 20 }) end },
		{ name = "duplicate tab", break_inventory = function(f) table.insert(f.inventory.tabs, { id = 20, name = "duplicate" }) end },
		{ name = "ambiguous session", break_inventory = function(f) table.insert(f.inventory.sessions, { id = 400, name = "conflict", tabs = { 20 } }) end },
		{ name = "invalid name", break_inventory = function(f) f.inventory.hosts[2].name = false end },
		{ name = "invalid state", break_inventory = function(f) f.inventory.hosts[2].state = "invented" end },
		{ name = "missing membership", break_inventory = function(f) f.inventory.hosts[2].panes = nil end },
		{ name = "missing session membership", break_inventory = function(f) f.inventory.sessions[2].tabs = nil end },
		{ name = "invalid session membership", break_inventory = function(f) f.inventory.sessions[2].tabs = { 20, "invalid" } end },
		{ name = "duplicate session ID", break_inventory = function(f) table.insert(f.inventory.sessions, { id = 200, name = "duplicate", tabs = { 20 } }) end },
		{ name = "invalid host membership array", break_inventory = function(f) f.inventory.hosts[2].panes = { pane = 2 } end },
	}
	for _, item in ipairs(metadata_failures) do
		local failure = item
		case("remote " .. item.name .. " makes only that host unavailable and keeps local asks", function(f, real)
			add_remote_b(f); f:bind()
			local original = real.json.decode(real.json.encode(f.inventory))
			failure.break_inventory(f)
			local request = f:poll()
			expect(host_inventory(request, "1").status == "unavailable" and #host_inventory(request, "1").agents == 0,
				"partial remote metadata was published as a complete or truncated snapshot")
			expect(host_inventory(request).status == "available" and host_inventory(request, "2").status == "available",
				"remote metadata failure suppressed coherent hosts")
			f:ok(request, { operation_id = "local-during-unavailable", pane = "1", text = "local only" })
			expect(#f.gets == 1 and #f.asks == 1, "unrelated remote metadata failure blocked local semantic delivery")
			local receipt = f.requests[#f.requests]
			expect(#receipt.body.results == 1 and host_inventory(receipt, "1").status == "unavailable",
				"immediate report concealed remote failure or lost its local receipt")
			f:ok(receipt)
			f.inventory = original
			local recovered = f:poll()
			expect(host_inventory(recovered, "1").observation_generation == 2
				and host_inventory(recovered).observation_generation == 1
				and host_inventory(recovered, "2").observation_generation == 1, "partial loss recovery did not isolate its generation")
		end)
	end

	case("ambiguous pane ownership marks both remote hosts unavailable without assigning it local", function(f)
		add_remote_b(f); f:bind()
		f.inventory.hosts[3].panes = { 2, 3 }
		local request = f:poll()
		expect(host_inventory(request).status == "available" and #host_inventory(request).agents == 1
			and host_inventory(request, "1").status == "unavailable" and #host_inventory(request, "1").agents == 0
			and host_inventory(request, "2").status == "unavailable" and #host_inventory(request, "2").agents == 0,
			"ambiguous pane membership leaked or suppressed the unrelated local host")
		f:ok(request, { operation_id = "ambiguous-remote", pane = "2", text = "never" })
		expect(#f.gets == 0 and #f.asks == 0, "ambiguous remote pane reached semantic delivery")
	end)

	case("remote host disappearance retains high-water and local receipt through repeated omissions", function(f)
		add_remote_b(f); local bound = f:bind()
		f:offer("local once", "disappearance-local")
		f:reject(f.requests[#f.requests], "rejected")
		local removed = table.remove(f.inventory.hosts, 2)
		for _ = 1, 3 do
			local request = f:poll()
			unchanged_source(bound, request)
			expect(#request.body.hosts == 2 and host_inventory(request).observation_generation == 1
				and host_inventory(request, "2").observation_generation == 1, "host disappearance reset the window or surviving hosts")
			if #request.body.results > 0 then expect(request.body.results[1].operation_id == "disappearance-local", "unrelated disappearance changed receipt") end
			f:ok(request)
		end
		table.insert(f.inventory.hosts, 2, removed)
		local recovered = f:poll()
		expect(host_inventory(recovered, "1").observation_generation == 2 and #host_inventory(recovered, "1").agents == 1
			and #f.asks == 1 and #f.gets == 1, "reappearing host reused its retired high-water or replayed local delivery")
	end)

	case("remote pane disappears between agent and membership stages without becoming local", function(f)
		add_remote_b(f); f:bind()
		f:hold(); f:poll(); f:through_inventory("agents")
		f.inventory.hosts[2].panes = {}
		table.remove(f.inventory.panes, 2)
		f:release()
		local request = f.requests[#f.requests]
		expect(host_inventory(request, "1").status == "unavailable" and #host_inventory(request, "1").agents == 0
			and #host_inventory(request).agents == 1 and host_inventory(request, "2").status == "available",
			"mid-stage remote disappearance was reclassified or published as an empty complete host")
		f:ok(request, { operation_id = "vanished-remote", pane = "2", text = "never" })
		expect(#f.gets == 0 and #f.asks == 0, "vanished remote pane reached get or ask")
	end)

	case("host rename and empty-name fallback keep generation while address changes advance only that host", function(f)
		add_remote_b(f); local bound = f:bind()
		f.inventory.hosts[2].name = "Renamed Studio"
		local renamed = f:poll()
		unchanged_source(bound, renamed)
		expect(host_inventory(renamed, "1").label == "Renamed Studio" and host_inventory(renamed, "1").observation_generation == 1,
			"rename retired the host or failed to publish its label")
		f:ok(renamed)
		f.inventory.hosts[2].name = ""
		local empty_name = f:poll()
		expect(host_inventory(empty_name, "1").label == "1" and host_inventory(empty_name, "1").observation_generation == 1,
			"empty SDK name lacked an ID fallback or changed generation")
		f:ok(empty_name)
		f.inventory.hosts[2].address = "a@replacement"
		local replacement = f:poll()
		expect(host_inventory(replacement, "1").observation_generation == 2
			and host_inventory(replacement).observation_generation == 1
			and host_inventory(replacement, "2").observation_generation == 1, "address replacement did not fence only its host")
	end)

	case("SDK host kind changes advance generation and fence an original local target before get", function(f)
		local bound = f:bind(); local offered = f:poll()
		f:hold(); f:ok(offered, { operation_id = "local-becomes-remote", pane = "1", text = "never" })
		f:through_inventory("agents")
		f.inventory.hosts[1].kind = "remote"
		f.inventory.hosts[2].kind = "local"
		f:release()
		local report = f.requests[#f.requests]
		unchanged_source(bound, report)
		expect(host_inventory(report, "0").observation_generation == 2 and not host_inventory(report, "0").is_local
			and host_inventory(report, "1").observation_generation == 2 and host_inventory(report, "1").is_local,
			"kind replacement did not publish new authority generations")
		expect(#f.gets == 0 and #f.asks == 0 and #report.body.results == 0,
			"local-to-remote target reached delivery or retained a retired local receipt")
		f:ok(report, { operation_id = "fresh-local-kind", pane = "2", text = "new local authority" })
		expect(#f.gets == 1 and f.gets[1] == 2 and #f.asks == 1 and f.asks[1].id == 2,
			"freshly observed local host was hardcoded to the original host or pane")
	end)

	case("local address replacement during revalidation discards only local pending without parent rebind", function(f)
		local bound = f:bind(); local offered = f:poll()
		f:hold(); f:ok(offered, { operation_id = "local-address-replaced", pane = "1", text = "never" })
		f:through_inventory("agents")
		f.inventory.hosts[1].address = "new-local-address"
		f:release()
		local report = f.requests[#f.requests]
		unchanged_source(bound, report)
		expect(report.body.instance_id == "daemon-a" and #report.body.results == 0
			and host_inventory(report).observation_generation == 2 and host_inventory(report, "1").observation_generation == 1
			and #f.gets == 0 and #f.asks == 0, "local observation replacement reset remote binding or delivered a stale target")
		f:ok(offered, { operation_id = "local-address-replaced", pane = "1", text = "never again" })
		expect(#f.gets == 0 and #f.asks == 0, "late replacement callback escaped its phase fence")
	end)

	case("local disconnect during revalidation forbids both get and ask and recovery clears retired report", function(f)
		local bound = f:bind(); local offered = f:poll()
		f:hold(); f:ok(offered, { operation_id = "local-disconnected", pane = "1", text = "never" })
		f:through_inventory("agents")
		f.inventory.hosts[1].state = "reconnecting"
		f:release()
		local report = f.requests[#f.requests]
		expect(host_inventory(report).status == "disconnected" and #f.gets == 0 and #f.asks == 0,
			"disconnected local host reached semantic delivery")
		f:reject(report, "rejected")
		f.inventory.hosts[1].state = "connected"
		local recovered = f:poll()
		unchanged_source(bound, recovered)
		expect(host_inventory(recovered).observation_generation == 2 and #recovered.body.results == 0,
			"local reconnect retransmitted a receipt from the retired observation lifetime")
	end)

	case("native remote generation changes and remote admission errors preserve local command and ACK", function(f)
		add_remote_b(f); local bound = f:bind()
		local offered = f:poll()
		f.native_generations["1"] = 12
		local response = f:response(offered, { operation_id = "partial-admission", pane = "1", text = "local once" })
		response.hosts[3].generation = 0
		response.hosts[3].error = "shared source limit"
		response.hosts[3].error_code = "rejected"
		f:deliver(offered, response)
		expect(#f.gets == 1 and #f.asks == 1, "unrelated remote generation or admission rejection blocked local command")
		local receipt = f.requests[#f.requests]
		unchanged_source(bound, receipt)
		expect(#receipt.body.results == 1 and receipt.body.results[1].status == "accepted",
			"partial remote admission reset the parent binding or lost local delivery")
		local ack = f:response(receipt)
		ack.hosts[3].generation = 0; ack.hosts[3].error = "still full"; ack.hosts[3].error_code = "rejected"
		f:deliver(receipt, ack)
		local next_request = f:poll()
		unchanged_source(bound, next_request)
		expect(#next_request.body.results == 0 and #f.asks == 1 and #f.gets == 1,
			"remote admission rejection prevented local confirmation or repeated delivery")
		f:ok(next_request)
		expect(#f.requests == 4, "host admission invented an immediate retry policy")
	end)

	case("host replies are matched by host ID rather than position", function(f)
		add_remote_b(f); f:bind()
		local offered = f:poll()
		local response = f:response(offered, { operation_id = "reordered", pane = "1", text = "local once" })
		response.hosts[1], response.hosts[3] = response.hosts[3], response.hosts[1]
		f:deliver(offered, response)
		expect(#f.gets == 1 and #f.asks == 1 and f.requests[#f.requests].body.results[1].status == "accepted",
			"reordered unrelated native generations were confused with the local host")
	end)

	case("native-only local expiry changes generation without observation rebind or stale receipt replay", function(f)
		local bound = f:bind(); f:offer("before expiry", "old-local-generation")
		local old_receipt = f.requests[#f.requests]
		f.native_generations["0"] = 8
		f:ok(old_receipt, { operation_id = "captured-old-offer", pane = "1", text = "must not ask" })
		expect(#f.asks == 1 and #f.gets == 1, "changed native local generation executed a captured command")
		local fresh = f:poll()
		unchanged_source(bound, fresh)
		expect(fresh.body.instance_id == "daemon-a" and #fresh.body.results == 0
			and host_inventory(fresh).observation_generation == 1 and host_inventory(fresh, "1").observation_generation == 1,
			"native expiry reset the whole window or replayed its old local receipt")
		f:ok(fresh, { operation_id = "new-local-generation", pane = "1", text = "new lifetime" })
		local new_receipt = f.requests[#f.requests]
		f:ok(old_receipt, { operation_id = "captured-old-offer", pane = "1", text = "never again" })
		f:connect()
		expect(f.requests[#f.requests] == new_receipt and #new_receipt.body.results == 1
			and new_receipt.body.results[1].operation_id == "new-local-generation" and #f.asks == 2 and #f.gets == 2,
			"old generation completion cleared newer receipt work or repeated delivery")
	end)

	case("local host rejection preserves captured report while unrelated remote errors remain scoped", function(f)
		f:bind(); f:offer()
		local receipt = f.requests[#f.requests]
		local response = f:response(receipt)
		response.hosts[1].error = "local snapshot rejected"
		response.hosts[1].error_code = "rejected"
		f:deliver(receipt, response)
		local next_request = f:poll()
		unchanged_source(receipt, next_request)
		expect(#next_request.body.results == 1 and #f.asks == 1 and #f.gets == 1,
			"local host rejection falsely acknowledged or replayed delivery")
	end)

	case("accepted command immediately reports a fresh inventory including newly connected remote host", function(f)
		f:bind()
		f.ask_hook = function()
			f.ask_hook = nil
			add_remote_b(f)
			f.inventory.hosts[2].name = "Fresh Remote A"
		end
		local before = #f.requests
		f:offer("fresh full report", "fresh-report")
		local receipt = f.requests[#f.requests]
		expect(#f.requests == before + 2 and #receipt.body.hosts == 3
			and host_inventory(receipt, "1").label == "Fresh Remote A" and #host_inventory(receipt, "2").agents == 1
			and #receipt.body.results == 1 and #f.asks == 1 and #f.gets == 1,
			"receipt used cached inventory or scheduled an ask retry")
	end)

	for _, api in ipairs({ "tabs", "sessions", "agents", "hosts", "panes" }) do
		for _, mode in ipairs({ "exception", "nil" }) do
			local failing_api, failing_mode = api, mode
			case("whole " .. api .. " API " .. mode .. " skips exchange and preserves receipt and host generations", function(f)
				local bound = f:bind(); f:offer()
				f:reject(f.requests[#f.requests], "rejected")
				local before = #f.requests
				if failing_mode == "exception" then f.inventory_errors = { [failing_api] = true }
				else f.inventory_nil = { [failing_api] = true } end
				f:poll()
				expect(#f.requests == before and #f.asks == 1 and #f.gets == 1, "global API failure published an empty success or repeated delivery")
				f.inventory_errors, f.inventory_nil = nil, nil
				local recovered = f:poll()
				unchanged_source(bound, recovered)
				expect(#f.requests == before + 1 and #recovered.body.results == 1
					and host_inventory(recovered).observation_generation == 1
					and host_inventory(recovered, "1").observation_generation == 1,
					"global API recovery invented an observed loss, lost receipt, or left busy stuck")
			end)
		end
	end

	case("empty host list and missing sole local host never register an empty window", function(f)
		f.inventory.hosts = {}
		f:poll()
		expect(#f.requests == 0, "initial empty hosts registered an empty success")
		f.inventory.hosts = { { id = 1, name = "remote", kind = "remote", state = "connected", panes = { 2 } } }
		f:connect()
		expect(#f.requests == 0 and #f.asks == 0 and #f.gets == 0, "remote-only SDK inventory registered local authority")
		table.insert(f.inventory.hosts, 1, { id = 0, name = "local", kind = "local", state = "connected", panes = { 1 } })
		local recovered = f:connect()
		expect(#recovered.body.hosts == 2 and host_inventory(recovered).observation_generation == 1,
			"failed initial inventory permanently held busy or consumed first generation")
	end)

	case("unsafe host IDs and duplicate hosts fail without truncating or changing binding", function(f)
		local bound = f:bind()
		local before = #f.requests
		f.inventory.hosts[2].id = 9007199254740992
		f:poll()
		expect(#f.requests == before, "unsafe host ID was rounded or wrapped into an exchange")
		f.inventory.hosts[2].id = 0
		f:poll()
		expect(#f.requests == before, "duplicate host ID was published")
		f.inventory.hosts[2].id = 9007199254740991
		f.inventory.hosts[2].name = ""
		local recovered = f:poll()
		unchanged_source(bound, recovered)
		expect(host_inventory(recovered, "9007199254740991").label == "9007199254740991"
			and host_inventory(recovered, "9007199254740991").observation_generation == 1,
			"maximum exact SDK host ID was altered or lacked canonical fallback")
	end)

	case("128 agents is a per-host limit and oversized host is unavailable rather than truncated", function(f)
		f.inventory.hosts[2].panes = {}
		f.inventory.agents = { f.inventory.agents[1] }
		for index = 1, 128 do
			local pane = 1000 + index
			table.insert(f.inventory.hosts[2].panes, pane)
			table.insert(f.inventory.panes, { pane = pane, title = "remote " .. index })
			table.insert(f.inventory.agents, { pane = pane, cwd = "/remote", state = "working" })
		end
		local full = f:bind()
		expect(#host_inventory(full).agents == 1 and #host_inventory(full, "1").agents == 128,
			"per-host cap was incorrectly applied to the whole window")
		table.insert(f.inventory.hosts[2].panes, 2000)
		table.insert(f.inventory.panes, { pane = 2000, title = "overflow" })
		table.insert(f.inventory.agents, { pane = 2000, cwd = "/remote", state = "working" })
		local oversized = f:poll()
		expect(host_inventory(oversized, "1").status == "unavailable" and #host_inventory(oversized, "1").agents == 0
			and host_inventory(oversized).status == "available", "oversized host was truncated into a successful observation")
	end)

	local function fill_hosts(f, count)
		for id = 2, count - 1 do
			table.insert(f.inventory.hosts, { id = id, name = "Remote " .. id, kind = "remote",
				state = "connected", address = "host-" .. id, panes = {} })
		end
	end

	case("64 hosts share one exchange and a 65th fails without consuming loss generations", function(f)
		fill_hosts(f, 64)
		local full = f:bind()
		expect(#full.body.hosts == 64 and #f.requests == 1, "maximum hosts were truncated or split into helpers")
		table.insert(f.inventory.hosts, { id = 64, name = "overflow", kind = "remote", state = "connected", panes = {} })
		local before = #f.requests
		f:poll()
		expect(#f.requests == before, "65th host produced a truncated successful exchange")
		table.remove(f.inventory.hosts)
		local recovered = f:poll()
		unchanged_source(full, recovered)
		expect(#recovered.body.hosts == 64 and host_inventory(recovered, "1").observation_generation == 1,
			"oversized whole list consumed a host observation generation")
	end)

	for _, delta in ipairs({ 0, 1 }) do
		local boundary_delta = delta
		case("64 host replies and escaped Unicode prompt at LF-inclusive boundary plus " .. delta, function(f, real)
			fill_hosts(f, 64); f:bind()
			local offered = f:poll()
			local response = f:response(offered, { operation_id = "64-host-boundary", pane = "1", text = '한🙂"\n\\' })
			for index = 2, #response.hosts do
				response.hosts[index].error = string.rep("\0", 509) .. "한"
				response.hosts[index].error_code = "rejected"
			end
			local overhead = #encode_fixture(real, response, "measure 64-host escaped overhead") + 1
			response.command.text ..= string.rep("a", LIMIT - overhead + boundary_delta)
			local body = encode_fixture(real, response, "encode 64-host boundary HTTP body") .. "\n"
			expect(#body == LIMIT + boundary_delta, "64-host fixture did not hit the actual encoded boundary")
			f:deliver(offered, {}, { body = body })
			expect(#f.asks == (boundary_delta == 0 and 1 or 0) and #f.gets == (boundary_delta == 0 and 1 or 0),
				"64-host response boundary did not fence semantic delivery exactly")
			if boundary_delta == 0 then expect(f.asks[1].text == response.command.text, "escaped Unicode prompt was changed") end
		end)
	end

	local malformed_responses = {
		{ name = "v1 flat response", alter = function(response) response.hosts = nil; response.generation = 7 end },
		{ name = "duplicate host reply", alter = function(response) response.hosts[2] = response.hosts[1] end },
		{ name = "unknown host reply", alter = function(response) response.hosts[2].host = "42" end },
		{ name = "missing host reply", alter = function(response) table.remove(response.hosts) end },
		{ name = "lower observation generation", alter = function(response) response.hosts[2].observation_generation = 0 end },
		{ name = "different observation generation", alter = function(response) response.hosts[2].observation_generation = 2 end },
		{ name = "unsafe native generation", alter = function(response) response.hosts[2].generation = 9007199254740992 end },
		{ name = "oversized host error", alter = function(response) response.hosts[2].error = string.rep("a", 513) end },
	}
	for _, item in ipairs(malformed_responses) do
		local invalid = item
		case(invalid.name .. " rejects before get and preserves captured local report", function(f)
			f:bind(); f:offer()
			local receipt = f.requests[#f.requests]
			local response = f:response(receipt, { operation_id = "malformed", pane = "1", text = "never" })
			invalid.alter(response)
			f:deliver(receipt, response)
			expect(#f.asks == 1 and #f.gets == 1, "malformed response reached semantic delivery")
			local next_request = f:poll()
			unchanged_source(receipt, next_request)
			expect(next_request.body.instance_id == "daemon-a" and #next_request.body.results == 1,
				"protocol rejection reset binding, acknowledged receipt, or left busy held")
		end)
	end

	case("verified helper absence is advice rather than a saved route", function(f)
		f.no_installation = true
		f:poll()
		expect(#f.requests == 0 and #f.writes == 0, "null installation proof activated or saved a native route")
		expect(#f.toasts > 0 and f.toasts[#f.toasts].message:find("not installed", 1, true), "verified absence did not show installation advice")
		local probes = #f.setup_requests
		f:poll()
		expect(#f.setup_requests == probes, "verified absence repeated discovery on the polling timer")
	end)

	case("remote observation generation changes during local revalidation preserve one-shot delivery", function(f)
		add_remote_b(f); local bound = f:bind()
		local offered = f:poll()
		f:hold(); f:ok(offered, { operation_id = "remote-replaced-during-ask", pane = "1", text = "local still selected" })
		f:through_inventory("agents")
		f.inventory.hosts[2].address = "a@new-address"
		f:release()
		local receipt = f.requests[#f.requests]
		unchanged_source(bound, receipt)
		expect(host_inventory(receipt, "1").observation_generation == 2
			and host_inventory(receipt).observation_generation == 1 and host_inventory(receipt, "2").observation_generation == 1
			and #receipt.body.results == 1 and receipt.body.results[1].status == "accepted" and #f.gets == 1 and #f.asks == 1,
			"remote observation replacement discarded local pending or repeated semantic delivery")
	end)

	case("only local observation replacements discard retained receipts without resetting parent binding", function(f)
		local bound = f:bind(); f:offer()
		f:reject(f.requests[#f.requests], "rejected")
		f.inventory.hosts[2].address = "remote replacement"
		local remote_changed = f:poll()
		unchanged_source(bound, remote_changed)
		expect(#remote_changed.body.results == 1 and host_inventory(remote_changed, "1").observation_generation == 2,
			"unrelated remote observation replacement discarded local receipt")
		f:reject(remote_changed, "rejected")
		f.inventory.hosts[1].address = "local replacement"
		local local_changed = f:poll()
		unchanged_source(bound, local_changed)
		expect(local_changed.body.instance_id == "daemon-a" and #local_changed.body.results == 0
			and host_inventory(local_changed).observation_generation == 2
			and host_inventory(local_changed, "1").observation_generation == 2 and #f.gets == 1 and #f.asks == 1,
			"local observation replacement replayed retired delivery or reset unrelated hosts")
	end)

	case("host-scoped receipt rejection clears only captured local report and fences duplicate completion", function(f)
		f:bind(); f:offer()
		local old_receipt = f.requests[#f.requests]
		local response = f:response(old_receipt)
		response.hosts[1].error = "receipt rejected"
		response.hosts[1].error_code = "receipt_rejected"
		f:deliver(old_receipt, response)
		local next_request = f:poll()
		unchanged_source(old_receipt, next_request)
		expect(#next_request.body.results == 0 and next_request.body.instance_id == "daemon-a",
			"local receipt rejection retained a rejected report or reset parent binding")
		f:ok(next_request, { operation_id = "after-scoped-rejection", pane = "1", text = "new command" })
		local new_receipt = f.requests[#f.requests]
		f:deliver(old_receipt, response)
		f:connect()
		expect(f.requests[#f.requests] == new_receipt and #new_receipt.body.results == 1
			and new_receipt.body.results[1].operation_id == "after-scoped-rejection" and #f.gets == 2 and #f.asks == 2,
			"late host receipt rejection cleared newer result table or repeated delivery")
	end)

	case("parent instance_changed code retires identity even if daemon string is unchanged", function(f)
		f:bind(); f:offer()
		local receipt = f.requests[#f.requests]
		f:reject(receipt, "instance_changed", "daemon-a")
		fresh_source(receipt, f:poll())
		expect(#f.gets == 1 and #f.asks == 1, "parent rebinding repeated an uncertain semantic ask")
	end)

	case("unassignable agent metadata is a whole-poll failure rather than empty remote success", function(f)
		local bound = f:bind()
		local before = #f.requests
		table.insert(f.inventory.agents, { pane = 999, cwd = "/orphan", state = "working" })
		f:poll()
		expect(#f.requests == before and #f.gets == 0 and #f.asks == 0,
			"unassignable agent was guessed local or hidden by a successful empty inventory")
		table.remove(f.inventory.agents)
		local recovered = f:poll()
		unchanged_source(bound, recovered)
		expect(host_inventory(recovered).observation_generation == 1 and host_inventory(recovered, "1").observation_generation == 1,
			"failed whole poll consumed observation generations")
	end)

	case("request JSON byte cap rejects complete inventory without truncation and releases busy", function(f)
		f.inventory.hosts[2].panes = {}
		f.inventory.agents = { f.inventory.agents[1] }
		for index = 1, 33 do
			local pane = 1000 + index
			table.insert(f.inventory.hosts[2].panes, pane)
			table.insert(f.inventory.panes, { pane = pane, title = string.rep("t", 4096) })
			table.insert(f.inventory.agents, { pane = pane, cwd = string.rep("c", 4096), state = "working" })
		end
		f:poll()
		expect(#f.requests == 0 and #f.gets == 0 and #f.asks == 0, "oversized JSON inventory was truncated or submitted")
		for _, pane in ipairs(f.inventory.panes) do pane.title = "small" end
		for _, agent in ipairs(f.inventory.agents) do agent.cwd = "/small" end
		local recovered = f:connect()
		expect(#f.requests == 1 and #host_inventory(recovered, "1").agents == 33,
			"JSON cap left busy held or lost agents from the next complete inventory")
	end)

end
