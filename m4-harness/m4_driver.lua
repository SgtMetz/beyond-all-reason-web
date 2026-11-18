-- M4 replay-recording driver: speeds the headless game up and quits cleanly
-- (so the demo file gets written) after END_FRAME sim frames.
function widget:GetInfo()
	return { name = "M4 Driver", desc = "headless recording driver", author = "wasm-port", layer = 0, enabled = true }
end
local END_FRAME = 27000 -- 15 minutes of game time
local SPEED = 20
function widget:Initialize() Spring.Echo("[M4] driver loaded") end
function widget:GameStart() Spring.SendCommands("setmaxspeed " .. SPEED, "setspeed " .. SPEED) end
function widget:GameFrame(f)
	if f % 900 == 0 then
		Spring.SendCommands("setspeed " .. SPEED)
		Spring.Echo("[M4] frame " .. f)
	end
	if f >= END_FRAME then
		Spring.Echo("[M4] end frame reached, quitting")
		Spring.SendCommands("quitforce")
	end
end
function widget:GameOver() Spring.Echo("[M4] game over") Spring.SendCommands("quitforce") end
