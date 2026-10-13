--!optimize 0
-- Run in a Tern window VM, including Carly's documented loadstring VM:
-- https://docs.stencil.so/tern/reference/api-window.html#carlys-lua-tool
-- Invocation 1 (globals survive separate Carly lua calls; do not reload to poll):
-- desktop_pet_root = "/absolute/path/to/tern-desktop-pet"
-- desktop_pet_result = "/tmp/desktop-pet-regressions.json"
-- desktop_pet_suite = assert(loadstring(tern.fs.read(desktop_pet_root .. "/tests/transition-regressions.luau")))()
-- return "suite loaded"
-- Invocation 2 (the result directory must already exist):
-- local function persist(r) tern.fs.write(desktop_pet_result, tern.json.encode(r)) end
-- return desktop_pet_suite.run(tern, tern.fs.read(desktop_pet_root .. "/window.luau"), nil, persist, desktop_pet_root .. "/tests")
-- Later invocation 3: return tern.json.encode(desktop_pet_suite.get_results())
-- Or read desktop_pet_result from another call/process. Require done=true,
-- no fatal_error, and passed=total. Do not use a fixed sleep as a completion gate.
-- The checkpoint contains completed cases and active_case/stage/step before the
-- next work callback; a hard budget abort therefore leaves a useful last cursor.
-- Module reads, compilation, registration, fixture setup/checks, and individual
-- production callbacks run in separate real sleep continuations. Loading this
-- small module does not eagerly compile any fixture or behavioral case bodies.
-- Only SDK boundaries are controlled. Production source runs unchanged as
-- function(tern), with the real Tern JSON codec and normal callback budgets.
local suite = {}
local results = { done = true, passed = 0, cases = {} }
local modules = {
	"transition-fixture.luau",
	"transition-cases-core.luau",
	"transition-cases-installation.luau",
	"transition-cases-hosts.luau",
}

-- These yields are harness boundaries, never yields inside production work.
local function stage(name)
	coroutine.yield(name)
end

function suite.get_results()
	return results
end

-- test_directory defaults to the plugin's tests directory. Carly's VM has no
-- plugin root, so its documented invocation supplies the fifth argument.
-- Cases register asynchronously: scheduled=true is not a final count or pass.
function suite.run(real_tern, production_source, on_complete, on_checkpoint, test_directory)
	assert(results.done, "regression run already active")
	local plugin_directory = real_tern.plugin and real_tern.plugin.dir
	test_directory = test_directory or (plugin_directory and plugin_directory .. "/tests")
	assert(type(test_directory) == "string", "supply the absolute regression tests directory as suite.run's fifth argument")
	results = { done = false, passed = 0, total = 0, cases = {}, stage = "read module " .. modules[1], step = 0 }
	local worker = coroutine.create(function()
		local cases = {}
		-- Each ordinary module is a factory with this explicit shared contract.
		-- The fixture factory returns helper exports; case factories only register
		-- behavior. Helpers remain lexical locals inside each module's case bodies.
		local shared = {
			stage = stage,
			case = function(name, run)
				table.insert(cases, { name = name, run = run })
				results.total = #cases
			end,
		}
		for _, name in ipairs(modules) do
			local path = test_directory .. "/" .. name
			stage("read module " .. name)
			local module_source = real_tern.fs.read(path)
			stage("compile module " .. name)
			local compiled, err = loadstring(module_source, "@" .. path)
			assert(compiled ~= nil, tostring(err))
			module_source = nil
			stage("initialize module " .. name)
			local exported = compiled()(shared)
			if exported then
				for key, value in pairs(exported) do shared[key] = value end
			end
		end
		stage("compile production")
		-- Parameter shadowing is the documented wrapper, not a source rewrite.
		local compiled, err = loadstring("return function(tern)\n" .. production_source .. "\nend", "desktop-pet-production")
		assert(compiled ~= nil, tostring(err))
		local entry = compiled()
		production_source = nil
		for index, current in ipairs(cases) do
			results.active_case = current.name
			results.active_index = index
			stage("fixture setup")
			local ok, failure = pcall(function()
				current.run(shared.fixture(entry, real_tern), real_tern)
			end)
			stage("record case result")
			table.insert(results.cases, { name = current.name, ok = ok, error = not ok and tostring(failure) or nil })
			if ok then results.passed += 1 end
		end
		results.done = true
		results.active_case, results.active_index, results.stage = nil, nil, nil
	end)
	local advance
	local function schedule(callback)
		real_tern.sleep(0):next(function(_, err)
			if err ~= nil then
				results.done = true
				results.fatal_error = "harness scheduling failed: " .. tostring(err)
				if on_checkpoint then on_checkpoint(results) end
				if on_complete then on_complete(results) end
				return
			end
			callback()
		end)
	end
	local function checkpoint()
		-- Persistence runs separately and cannot consume the work stage's budget.
		if on_checkpoint then on_checkpoint(results) end
		schedule(advance)
	end
	advance = function()
		results.step += 1
		local ok, next_stage = coroutine.resume(worker)
		if not ok then
			results.done = true
			results.fatal_error = tostring(next_stage)
		end
		if results.done then
			schedule(function()
				if on_checkpoint then on_checkpoint(results) end
				if on_complete then schedule(function() on_complete(results) end) end
			end)
		else
			results.stage = next_stage
			schedule(checkpoint)
		end
	end
	schedule(checkpoint)
	return { scheduled = true }
end

return suite
