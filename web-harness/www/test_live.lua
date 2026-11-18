-- Live-play probe for ?testwidget=live (B4, B2 presets and frame time). Opt-in user widget.
-- It does not issue orders itself except where noted: selection, the build placement and
-- the move order come from the mouse/keyboard events the session script sends. It logs
-- what the engine did with them, as [live] lines the script waits for.
--   [live] cmdr ...     commander id, its position on the canvas (x from left, y from top)
--   [live] sel ...      the selection after each change
--   [live] active ...   the active command (build placement mode)
--   [live] built ...    a new unit of the player's team appeared (def, build progress)
--   [live] moved ...    the commander moved this far from where the move order was given
--   [perf] ...          draw-frame period statistics every 300 draw frames
-- Config: the page writes ?preset=low|medium|high|ultra and ?livespeed=N as the
-- Spring config strings WebPreset and WebLiveSpeed.
function widget:GetInfo()
	return { name = "Web Live Probe", desc = "browser live-play probe", author = "wasm-port", layer = 0, enabled = true }
end

local myTeam
local cmdrID, cmdrDef
local known = {}
local lastSel = ""
local lastActive = ""
local moveFrom, moveOrderedAt
local lastDraw, sum, max, n = nil, 0, 0, 0
local presetDone = false
local startedAt
local aiUnits = {}

local function screenOf(x, y, z)
	local sx, sy = Spring.WorldToScreenCoords(x, y, z)
	local vsx, vsy = Spring.GetViewGeometry()
	return math.floor(sx), math.floor(vsy - sy), vsx, vsy
end

local function findCommander()
	for _, id in ipairs(Spring.GetTeamUnits(myTeam)) do
		local def = UnitDefs[Spring.GetUnitDefID(id)]
		if def and def.customParams and def.customParams.iscommander then
			return id, Spring.GetUnitDefID(id)
		end
	end
end

function widget:Initialize()
	myTeam = Spring.GetMyTeamID()
	Spring.Echo("[live] probe loaded, team " .. tostring(myTeam))
end

function widget:GameStart()
	local speed = tonumber(Spring.GetConfigString("WebLiveSpeed", "1")) or 1
	if speed ~= 1 then
		Spring.SendCommands("setmaxspeed " .. speed, "setspeed " .. speed)
	end
end

function widget:GameFrame(f)
	if not startedAt then startedAt = f end
	if not cmdrID then
		cmdrID, cmdrDef = findCommander()
		if cmdrID then
			local x, y, z = Spring.GetUnitPosition(cmdrID)
			Spring.SetCameraTarget(x, y, z, 0)
		end
	end
	if f % 30 == 0 and cmdrID and Spring.ValidUnitID(cmdrID) then
		local x, y, z = Spring.GetUnitPosition(cmdrID)
		local sx, sy, vsx, vsy = screenOf(x, y, z)
		-- a ground point 160 elmos from the commander, for the build and move targets
		local tx, ty, tz = x + 160, Spring.GetGroundHeight(x + 160, z + 160), z + 160
		local bx, by = screenOf(tx, ty, tz)
		Spring.Echo(string.format("[live] cmdr id=%d def=%s pos=%.0f,%.0f screen=%d,%d target=%d,%d view=%dx%d frame=%d",
			cmdrID, UnitDefs[cmdrDef].name, x, z, sx, sy, bx, by, vsx, vsy, f))
		if moveFrom then
			local dx, dz = x - moveFrom[1], z - moveFrom[2]
			Spring.Echo(string.format("[live] moved %.0f elmos since the order (frame %d)", math.sqrt(dx * dx + dz * dz), f))
		end
	end

	-- a new unit of the player's team = the build order was placed and construction began
	if f % 15 == 0 then
		for _, id in ipairs(Spring.GetTeamUnits(myTeam)) do
			if not known[id] then
				known[id] = true
				local def = UnitDefs[Spring.GetUnitDefID(id)]
				local _, _, _, _, prog = Spring.GetUnitHealth(id)
				Spring.Echo(string.format("[live] built id=%d def=%s progress=%.2f frame=%d", id, def and def.name or "?", prog or -1, f))
			end
		end
	end

	-- selection and active command changes
	if f % 5 == 0 then
		local sel = Spring.GetSelectedUnits()
		local s = #sel .. ":" .. table.concat(sel, ",")
		if s ~= lastSel then
			lastSel = s
			local names = {}
			for _, id in ipairs(sel) do names[#names + 1] = UnitDefs[Spring.GetUnitDefID(id)].name end
			Spring.Echo("[live] sel n=" .. #sel .. " " .. table.concat(names, ","))
			if moveFrom == nil and #sel == 1 and sel[1] == cmdrID then
				-- the move order test starts from here once the script says so (see widget:TextCommand)
			end
		end
		local _, cmdID, _, cmdName = Spring.GetActiveCommand()
		local a = tostring(cmdID) .. ":" .. tostring(cmdName)
		if a ~= lastActive then
			lastActive = a
			Spring.Echo("[live] active " .. a)
		end
	end

	-- AI progress: unit counts of the other teams
	if f % 900 == 0 then
		local parts = {}
		for _, t in ipairs(Spring.GetTeamList()) do
			parts[#parts + 1] = t .. "=" .. #Spring.GetTeamUnits(t)
		end
		Spring.Echo("[live] units by team (frame " .. f .. "): " .. table.concat(parts, " "))
	end
end

-- "/luaui livemark" is not needed: the script starts the move test by right-clicking
-- the ground, and this notes where the commander stood at that moment
function widget:CommandNotify(cmdID, params, options)
	if cmdID == CMD.MOVE and cmdrID and Spring.ValidUnitID(cmdrID) then
		local sel = Spring.GetSelectedUnits()
		if #sel == 1 and sel[1] == cmdrID then
			local x, _, z = Spring.GetUnitPosition(cmdrID)
			moveFrom = { x, z }
			Spring.Echo(string.format("[live] move order to %.0f,%.0f from %.0f,%.0f", params[1] or 0, params[3] or 0, x, z))
		end
	end
	return false
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams)
	if unitID == cmdrID then
		Spring.Echo("[live] commander command " .. tostring(cmdID) .. (cmdID < 0 and (" (build " .. UnitDefs[-cmdID].name .. ")") or ""))
		if cmdID == CMD.MOVE and not moveFrom then
			local x, _, z = Spring.GetUnitPosition(cmdrID)
			moveFrom = { x, z }
		end
	end
end

function widget:DrawScreen()
	local now = Spring.GetTimer()
	if lastDraw then
		local dt = Spring.DiffTimers(now, lastDraw) * 1000
		sum, n = sum + dt, n + 1
		if dt > max then max = dt end
		if n >= 300 then
			Spring.Echo(string.format("[perf] draw period avg %.1f ms (%.1f fps) max %.1f ms over %d frames, engine fps %d, game frame %d",
				sum / n, 1000 * n / sum, max, n, Spring.GetFPS(), Spring.GetGameFrame()))
			sum, max, n = 0, 0, 0
		end
	end
	lastDraw = now
	if not presetDone and Spring.GetGameFrame() > 90 then
		presetDone = true
		local preset = Spring.GetConfigString("WebPreset", "")
		local idx = ({ low = 1, medium = 2, high = 3, ultra = 4 })[preset]
		if idx and WG.options and WG.options.applyOptionValue then
			Spring.Echo("[live] applying graphics preset " .. preset)
			WG.options.applyOptionValue("preset", idx)
		elseif idx then
			Spring.Echo("[live] cannot apply preset " .. preset .. ": WG.options missing")
		end
	end
end
