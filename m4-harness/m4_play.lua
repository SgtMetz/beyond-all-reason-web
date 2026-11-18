-- M4 replay-playback driver (unsynced): runs the replay as fast as the host
-- allows and quits cleanly at game over or when the demo stops producing frames.
function widget:GetInfo()
	return { name = "M4 Playback", desc = "headless replay driver", author = "wasm-port", layer = 0, enabled = true }
end
local SPEED = 1000
local lastFrame, lastAdvance, quitting = -1, nil, false
local function quit(why)
	if quitting then return end
	quitting = true
	Spring.Echo("[M4] quitting at frame " .. lastFrame .. ": " .. why)
	Spring.SendCommands("quitforce")
end
-- after the last demo frame the engine keeps simulating locally; the server drops
-- its demo reader at end of stream, after which Spring.GetReplayLength() is nil
-- (the header's length can't be used: it is 0 when the recording was quit early)
-- The server can close the reader a few frames before this client has simulated the
-- last demo frame (it reads ahead), so keep going for DRAIN more frames before quitting.
-- Frames past the end of the demo carry no checksums, so they don't change the result.
local DRAIN = 60
local hadDemo, closedAt = false, nil
function widget:Initialize()
	hadDemo = (Spring.GetReplayLength() ~= nil)
	Spring.Echo("[M4] playback driver loaded, demo reader open: " .. tostring(hadDemo))
end
function widget:GameStart() Spring.SendCommands("setmaxspeed " .. SPEED, "setspeed " .. SPEED) end
function widget:GameFrame(f)
	lastFrame, lastAdvance = f, Spring.GetTimer()
	if f % 300 == 0 then Spring.SendCommands("setspeed " .. SPEED) end
	if f % 1800 == 0 then Spring.Echo("[M4] playback frame " .. f) end
	if hadDemo and not closedAt and Spring.GetReplayLength() == nil then
		closedAt = f
		Spring.Echo("[M4] demo reader closed at frame " .. f .. ", draining " .. DRAIN .. " frames")
	end
	if closedAt and f >= closedAt + DRAIN then quit("end of demo stream") end
end
function widget:Update()
	if not lastAdvance then return end
	local idle = Spring.DiffTimers(Spring.GetTimer(), lastAdvance)
	if closedAt and idle > 5 then quit("end of demo stream (no new frames for 5 s)") end
	if idle > 30 then quit("no new frames for 30 s (end of demo)") end
end
function widget:GameOver() quit("game over") end
