-- WebGL2 shim checks: ?testwidget=gl. Pixel readbacks for
--  * glPolygonMode(GL_LINE): a triangle drawn in line mode leaves its interior
--    untouched and colours its edges; the same triangle filled colours the interior;
--  * depth gl.CopyToTexture: the screen depth (cleared to 0.25) copied into a
--    DEPTH_COMPONENT24 texture samples as 0.25.
-- Draws into a small corner of the screen every 100 draw frames.
function widget:GetInfo()
	return { name = "Web GL shim test", desc = "B2 polygon mode / depth copy checks", layer = 10000000, enabled = true }
end
local colorShader, depthShader, triVAO, quadVAO, depthTex
local buffers = {}
local frames, passes, fails = 0, 0, 0
local vsx, vsy = 0, 0

local function buffer(target, count, layout, data)
	local vbo = assert(gl.GetVBO(target, false))
	vbo:Define(count, layout)
	vbo:Upload(data)
	buffers[#buffers + 1] = vbo
	return vbo
end

local function makeDepthTex()
	if depthTex then gl.DeleteTexture(depthTex) end
	vsx, vsy = Spring.GetViewGeometry()
	depthTex = gl.CreateTexture(vsx, vsy, {
		border = false, format = 0x81A6, -- GL_DEPTH_COMPONENT24, as BAR's volumetric clouds
		min_filter = GL.NEAREST, mag_filter = GL.NEAREST, wrap_s = GL.CLAMP_TO_EDGE, wrap_t = GL.CLAMP_TO_EDGE,
	})
	assert(depthTex, "depth texture creation failed")
end

function widget:Initialize()
	colorShader = assert(gl.CreateShader({
		vertex = [[#version 330
		layout(location=0) in vec2 pos;
		void main() { gl_Position = vec4(pos, 0.0, 1.0); }]],
		fragment = [[#version 330
		uniform vec4 color;
		out vec4 fragColor;
		void main() { fragColor = color; }]],
	}), gl.GetShaderLog())
	depthShader = assert(gl.CreateShader({
		vertex = [[#version 330
		layout(location=0) in vec2 pos;
		out vec2 uv;
		void main() { uv = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }]],
		fragment = [[#version 330
		uniform sampler2D depthTex;
		in vec2 uv;
		out vec4 fragColor;
		void main() { float d = texture(depthTex, uv).r; fragColor = vec4(d, d, d, 1.0); }]],
		uniformInt = { depthTex = 0 },
	}), gl.GetShaderLog())
	-- triangle in the lower-left corner (NDC)
	triVAO = assert(gl.GetVAO())
	triVAO:AttachVertexBuffer(buffer(GL.ARRAY_BUFFER, 3, {{id=0, name="pos", size=2}}, {-0.95,-0.95, -0.55,-0.95, -0.75,-0.55}))
	-- full-screen quad as two triangles (the depth shader samples by screen position)
	quadVAO = assert(gl.GetVAO())
	quadVAO:AttachVertexBuffer(buffer(GL.ARRAY_BUFFER, 6, {{id=0, name="pos", size=2}}, {-1,-1, 1,-1, 1,1, -1,-1, 1,1, -1,1}))
	makeDepthTex()
	Spring.Echo("[gltest] initialized")
end

function widget:ViewResize()
	makeDepthTex()
end

local function px(nx, ny) return math.floor((nx * 0.5 + 0.5) * vsx), math.floor((ny * 0.5 + 0.5) * vsy) end
local function read(x, y) local r, g, b = gl.ReadPixels(x, y, 1, 1); return r or -1, g or -1, b or -1 end
local function check(ok, what)
	if ok then return true end
	fails = fails + 1
	Spring.Echo("[gltest] FAIL " .. what)
	return false
end

function widget:DrawScreenPost()
	frames = frames + 1
	if frames ~= 2 and frames % 100 ~= 0 then return end
	gl.DepthTest(false); gl.Blending(false); gl.Culling(false); gl.Scissor(false)
	gl.AlphaTest(false); gl.ColorMask(true, true, true, true)
	local ok = true

	-- 1. polygon mode
	gl.UseShader(colorShader)
	local color = gl.GetUniformLocation(colorShader, "color")
	gl.Uniform(color, 0, 0, 0, 1)
	triVAO:DrawArrays(GL.TRIANGLES, 3)               -- black backdrop (filled)
	gl.PolygonMode(GL.FRONT_AND_BACK, GL.LINE)
	gl.Uniform(color, 1, 0, 0, 1)
	triVAO:DrawArrays(GL.TRIANGLES, 3)               -- red outline
	gl.PolygonMode(GL.FRONT_AND_BACK, GL.FILL)
	local cx, cy = px(-0.75, -0.82)                  -- inside, away from the edges
	local r, g, b = read(cx, cy)
	ok = check(r < 0.1 and g < 0.1 and b < 0.1, string.format("line-mode interior at %d,%d is %.2f %.2f %.2f (expected black)", cx, cy, r, g, b)) and ok
	local ex, ey = px(-0.75, -0.95)                  -- bottom edge: some pixel in a small column must be red
	local edge = false
	for dy = -2, 3 do
		local er, eg = read(ex, ey + dy)
		if er > 0.9 and eg < 0.1 then edge = true end
	end
	ok = check(edge, string.format("no red edge pixel near %d,%d", ex, ey)) and ok
	triVAO:DrawArrays(GL.TRIANGLES, 3)               -- filled red
	r, g, b = read(cx, cy)
	ok = check(r > 0.9 and g < 0.1, string.format("filled interior at %d,%d is %.2f %.2f %.2f (expected red)", cx, cy, r, g, b)) and ok
	gl.UseShader(0)

	-- 2. depth copy: clear the screen's depth to 0.25, copy it, draw it back as grey
	gl.DepthMask(true)
	gl.Clear(GL.DEPTH_BUFFER_BIT, 0.25)
	gl.DepthMask(false)
	gl.CopyToTexture(depthTex, 0, 0, 0, 0, vsx, vsy)
	gl.UseShader(depthShader)
	gl.Texture(0, depthTex)
	gl.Scissor(0, 0, 40, 40)
	quadVAO:DrawArrays(GL.TRIANGLES, 6)
	gl.Scissor(false)
	gl.Texture(0, false)
	gl.UseShader(0)
	r, g, b = read(10, 10)
	ok = check(math.abs(r - 0.25) < 0.02, string.format("depth copy samples %.3f (expected 0.25)", r)) and ok

	if ok then
		passes = passes + 1
		Spring.Echo("[gltest] PASS polygon mode + depth copy; frame " .. Spring.GetGameFrame() .. " (" .. passes .. " passes, " .. fails .. " fails)")
	end
	gl.Blending(true)
end

function widget:Shutdown()
	if triVAO then triVAO:Delete() end
	if quadVAO then quadVAO:Delete() end
	for _, vbo in ipairs(buffers) do vbo:Delete() end
	if colorShader then gl.DeleteShader(colorShader) end
	if depthShader then gl.DeleteShader(depthShader) end
	if depthTex then gl.DeleteTexture(depthTex) end
end
