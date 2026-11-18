-- Diagnostic widget for the renderer build (render.html?testwidget=1): draws known shapes
-- and text, in and out of display lists, so a captured frame shows which paths work.
function widget:GetInfo()
	return { name = "Web render test", desc = "B2 renderer diagnostics", layer = -10000000, enabled = true, handler = true }
end

local listRect, listText, font
local frames = 0

function widget:Initialize()
	font = gl.LoadFont("fonts/FreeSansBold.otf", 40, 4, 3)
	listRect = gl.CreateList(function()
		gl.Color(0, 0, 1, 1)
		gl.Rect(320, 520, 520, 620)
	end)
	listText = gl.CreateList(function()
		font:Begin()
		font:SetTextColor(1, 1, 0, 1)
		font:Print("LIST TEXT", 560, 560, 40, "o")
		font:End()
	end)
	Spring.Echo("[webtest] init font=" .. tostring(font) .. " lists=" .. tostring(listRect) .. "," .. tostring(listText))
end

function widget:DrawScreen()
	frames = frames + 1
	-- direct immediate-mode rect (top left: red)
	gl.Color(1, 0, 0, 1)
	gl.Rect(320, 640, 520, 700)
	-- direct font text (white)
	if font then
		font:Begin()
		font:SetTextColor(1, 1, 1, 1)
		font:Print("DIRECT TEXT", 560, 660, 40, "o")
		font:End()
	end
	-- engine default font
	gl.Text("gl.Text", 560, 460, 30, "o")
	if listRect then gl.CallList(listRect) end
	if listText then gl.CallList(listText) end
	gl.Color(1, 1, 1, 1)
	if frames == 30 then Spring.Echo("[webtest] drew 30 frames") end
end

function widget:DrawScreenPost()
	gl.Color(0, 1, 0, 1)
	gl.Rect(100, 300, 250, 400)
	-- the same after resetting the state a draw could inherit (magenta)
	gl.Texture(0, false)
	gl.DepthTest(false)
	gl.Blending(false)
	gl.Culling(false)
	gl.AlphaTest(false)
	gl.Scissor(false)
	gl.ColorMask(true, true, true, true)
	gl.UseShader(0)
	gl.Color(1, 0, 1, 1)
	gl.Rect(100, 450, 250, 550)
	gl.Blending(true)
	gl.Color(1, 1, 1, 1)
	-- read back what the rects left in the framebuffer (green, magenta, red from DrawScreen)
	if frames % 30 == 1 then
		local function px(x, y)
			local r, g, b, a = gl.ReadPixels(x, y, 1, 1)
			return string.format("(%.2f %.2f %.2f %.2f)", r or -1, g or -1, b or -1, a or -1)
		end
		Spring.Echo("[webtest] frame " .. frames .. " readback green" .. px(175, 350) .. " magenta" .. px(175, 500) .. " red" .. px(420, 670))
	end
end

function widget:Shutdown()
	if listRect then gl.DeleteList(listRect) end
	if listText then gl.DeleteList(listText) end
	if font then gl.DeleteFont(font) end
end
