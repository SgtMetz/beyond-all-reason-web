-- B2 unit-visibility probe: ?testwidget=units. From game frame START on, keeps
-- the camera close to the densest cluster of units (re-picked every REPICK
-- frames), so periodic ?capture=N frames show units instead of empty terrain.
-- Each pick logs what the engine reports about the target ([unittest] lines):
-- frustum visibility, the visible-unit count, the screen position, and the
-- framebuffer colour read back at that position after the world pass.
-- Only unsynced camera calls and reads are made; the simulation is untouched.
function widget:GetInfo()
	return { name = "Web unit probe", desc = "B2 unit-visibility checks", layer = 10000000, enabled = true }
end

local START, REPICK, DIST = 900, 300, 500
local target, pickedAt, probe = nil, -REPICK, false
local worldProbe = false -- set with probe; consumed by DrawWorld

-- a unit under construction (build progress nearest 50%) exercises the build-stage clip
-- planes; otherwise the densest cluster
local function pickBeingBuilt(all)
	local best, bestD = nil, 0.35
	for i = 1, #all do
		local _, _, _, _, progress = Spring.GetUnitHealth(all[i])
		if progress and progress > 0.05 and progress < 0.95 and math.abs(progress - 0.5) < bestD then
			best, bestD = all[i], math.abs(progress - 0.5)
		end
	end
	return best
end

local function pick()
	local best, bestN = nil, -1
	local all = Spring.GetAllUnits()
	local built = pickBeingBuilt(all)
	if built then
		local x, y, z = Spring.GetUnitPosition(built)
		local _, _, _, _, progress = Spring.GetUnitHealth(built)
		Spring.Echo(string.format("[unittest] under construction: %d at %.0f%%", built, (progress or 0) * 100))
		return built, #Spring.GetUnitsInSphere(x, y, z, 350), #all
	end
	for i = 1, #all, math.max(1, math.floor(#all / 200)) do
		local u = all[i]
		local x, y, z = Spring.GetUnitPosition(u)
		if x then
			local n = #Spring.GetUnitsInSphere(x, y, z, 350)
			if n > bestN then best, bestN = u, n end
		end
	end
	return best, bestN, #all
end

local function aim()
	local x, y, z = Spring.GetUnitPosition(target)
	if not x then return false end
	local cs = Spring.GetCameraState()
	cs.px, cs.py, cs.pz = x, y, z
	if cs.dist then cs.dist = DIST end
	if cs.height then cs.height = DIST end
	if cs.rx then cs.rx = 2.4 end -- spring camera pitch: looking down at ~45 degrees
	Spring.SetCameraState(cs, 0)
	return true
end

function widget:GameFrame(f)
	if f < START then return end
	if f - pickedAt >= REPICK or not (target and Spring.ValidUnitID(target)) then
		local n, total
		target, n, total = pick()
		pickedAt = f
		if target then
			local def = UnitDefs[Spring.GetUnitDefID(target)]
			Spring.Echo(string.format("[unittest] f=%d target=%d (%s) neighbours=%d units=%d",
				f, target, def and def.name or "?", n, total))
			probe = true
			worldProbe = true
		end
	end
end

function widget:Update()
	if target and not aim() then target = nil end
end

-- On probe frames, redraw the target with depth testing off and read the pixel back after
-- each draw: raw (fixed-function emulation, red) and with the engine's model state. This
-- separates geometry/transform problems from model-shader problems. Diagnostic only.
local function px(sx, sy)
	local r, g, b = gl.ReadPixels(math.floor(sx), math.floor(sy), 1, 1)
	return string.format("%.3f,%.3f,%.3f", r or -1, g or -1, b or -1)
end
function widget:DrawWorld()
	if not (worldProbe and target) then return end
	worldProbe = false
	local x, y, z = Spring.GetUnitPosition(target)
	if not x then return end
	local sx, sy = Spring.WorldToScreenCoords(x, y + 10, z)
	local before = px(sx, sy)
	-- engine-shaded first (it sets its own depth state), then the same with depth testing
	-- off beforehand, then raw (green) with depth testing on, then raw (red) with it off;
	-- the raw draws never write depth
	gl.Color(1, 1, 1, 1)
	gl.Unit(target, false)
	local shaded = px(sx, sy)
	gl.DepthTest(false); gl.Culling(false); gl.Blending(false)
	gl.Unit(target, false)
	local shadedNoDepth = px(sx, sy)
	gl.DepthTest(true); gl.DepthMask(false)
	gl.Color(0, 1, 0, 1)
	gl.Unit(target, true)
	local rawDepth = px(sx, sy)
	gl.DepthTest(false)
	gl.Color(1, 0, 0, 1)
	gl.Unit(target, true)
	local raw = px(sx, sy)
	gl.Color(1, 1, 1, 1)
	gl.DepthTest(true); gl.DepthMask(true); gl.Blending(true)
	Spring.Echo(string.format("[unittest] f=%d world pass at %.0f,%.0f: before=%s engineShaded=%s shadedNoDepth=%s rawGreenDepth=%s rawRed=%s",
		Spring.GetGameFrame(), sx, sy, before, shaded, shadedNoDepth, rawDepth, raw))
	-- the same for the nearest on-screen feature, to compare with a model that is visible
	local feats = Spring.GetFeaturesInSphere(x, y, z, 1500) or {}
	Spring.Echo(string.format("[unittest] features near target: %d of %d", #feats, #(Spring.GetAllFeatures() or {})))
	for _, fid in ipairs(feats) do
		local fx, fy, fz = Spring.GetFeaturePosition(fid)
		local fsx, fsy = Spring.WorldToScreenCoords(fx, fy + 5, fz)
		if fsx > 0 and fsy > 0 and fsx < 1280 and fsy < 720 then
			local fBefore = px(fsx, fsy)
			gl.Color(0, 1, 0, 1)
			gl.Feature(fid, false)
			local fShaded = px(fsx, fsy)
			gl.DepthTest(false); gl.DepthMask(false); gl.Blending(false)
			gl.Color(1, 0, 0, 1)
			gl.Feature(fid, true)
			local fRaw = px(fsx, fsy)
			gl.Color(1, 1, 1, 1)
			gl.DepthTest(true); gl.DepthMask(true); gl.Blending(true)
			local fdef = FeatureDefs[Spring.GetFeatureDefID(fid)]
			Spring.Echo(string.format("[unittest] feature %d (%s) at %.0f,%.0f: before=%s rawRed=%s engineShaded=%s",
				fid, fdef and fdef.name or "?", fsx, fsy, fBefore, fRaw, fShaded))
			break
		end
	end
end

function widget:DrawScreenPost()
	if not (probe and target) then return end
	probe = false
	local x, y, z = Spring.GetUnitPosition(target)
	if not x then return end
	local sx, sy, sz = Spring.WorldToScreenCoords(x, y + 10, z)
	local vis = Spring.GetVisibleUnits(-1, nil, false) or {}
	local r, g, b = gl.ReadPixels(math.floor(sx), math.floor(sy), 1, 1)
	Spring.Echo(string.format(
		"[unittest] f=%d inView=%s isVisible=%s visibleUnits=%d screen=%.0f,%.0f,%.3f pixel=%.3f,%.3f,%.3f cam=%s",
		Spring.GetGameFrame(), tostring(Spring.IsUnitInView(target)), tostring(Spring.IsUnitVisible(target)),
		#vis, sx, sy, sz, r or -1, g or -1, b or -1, Spring.GetCameraState().name or "?"))
end
