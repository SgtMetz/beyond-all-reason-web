-- WebGL2 LuaVAO integration check: ?testwidget=vao. Each green triangle is
-- an indexed instance; the blue pair uses instanced array drawing.
function widget:GetInfo()
	return { name = "Web LuaVAO test", desc = "B2 VAO draw/readback checks", layer = 10000000, enabled = true }
end
local shader, vao, uintVAO
local buffers = {}
local frames = 0
local function buffer(target, count, layout, data)
	local vbo = assert(gl.GetVBO(target, false))
	vbo:Define(count, layout)
	vbo:Upload(data)
	buffers[#buffers + 1] = vbo
	return vbo
end
function widget:Initialize()
	shader = assert(gl.CreateShader({
		vertex = [[#version 330
		layout(location=0) in vec2 pos;
		layout(location=1) in vec2 offset;
		uniform vec2 shift;
		void main() { gl_Position = vec4(pos + offset + shift, 0.0, 1.0); }]],
		fragment = [[#version 330
		uniform vec4 color;
		out vec4 fragColor;
		void main() { fragColor = color; }]],
	}), gl.GetShaderLog())
	local vertices = buffer(GL.ARRAY_BUFFER, 3, {{id=0, name="pos", size=2}}, {-0.8,-0.6, -0.6,-0.6, -0.7,-0.2})
	local instances = buffer(GL.ARRAY_BUFFER, 2, {{id=1, name="offset", size=2}}, {0,0, 0.4,0})
	local indices = buffer(GL.ELEMENT_ARRAY_BUFFER, 6, GL.UNSIGNED_SHORT, {0,1,2, 65535,65535,65535})
	vao = assert(gl.GetVAO())
	vao:AttachVertexBuffer(vertices)
	vao:AttachInstanceBuffer(instances)
	vao:AttachIndexBuffer(indices)
	uintVAO = assert(gl.GetVAO())
	uintVAO:AttachVertexBuffer(vertices)
	uintVAO:AttachIndexBuffer(buffer(GL.ELEMENT_ARRAY_BUFFER, 3, GL.UNSIGNED_INT, {0,1,2}))
	Spring.Echo("[vaotest] initialized")
end
function widget:DrawScreenPost()
	frames = frames + 1
	if frames ~= 1 and frames % 100 ~= 0 then return end
	gl.DepthTest(false); gl.Blending(false); gl.Culling(false); gl.Scissor(false)
	gl.AlphaTest(false); gl.ColorMask(true,true,true,true)
	gl.UseShader(shader)
	local color = gl.GetUniformLocation(shader, "color")
	local shift = gl.GetUniformLocation(shader, "shift")
	local function rejected(name, call)
		local ok, err = pcall(call)
		assert(not ok and tostring(err):find("unavailable in WebGL2", 1, true), name .. ": " .. tostring(err))
		Spring.Echo("[vaotest] rejected " .. name)
	end
	if frames == 1 then
		rejected("base vertex", function() vao:DrawElements(GL.TRIANGLES,3,0,2,1) end)
		rejected("base instance", function() vao:DrawArrays(GL.TRIANGLES,3,0,1,1) end)
		rejected("indirect add", function() vao:AddUnitsToSubmission(0) end)
		rejected("indirect submit", function() vao:Submit() end)
		rejected("uint restart", function() uintVAO:DrawElements(GL.TRIANGLES) end)
		local ok = pcall(function() vao:DrawArrays(GL.PATCHES,3) end)
		assert(not ok, "patches must fail")
	end
	gl.Uniform(shift, 0, 0); gl.Uniform(color, 0,1,0,1)
	vao:DrawElements(GL.TRIANGLES,nil,0,2,0)
	gl.Uniform(shift, 0, 0.8); gl.Uniform(color, 0,0,1,1)
	vao:DrawArrays(GL.TRIANGLES,3,0,2)
	gl.UseShader(0)
	local w,h = Spring.GetViewGeometry()
	local function pixel(x,y,r,g,b)
		local pr,pg,pb = gl.ReadPixels(math.floor(x*w),math.floor(y*h),1,1)
		assert(pr and math.abs(pr-r)<0.05 and math.abs(pg-g)<0.05 and math.abs(pb-b)<0.05,
			string.format("readback at %.2f %.2f: %s %s %s",x,y,tostring(pr),tostring(pg),tostring(pb)))
	end
	pixel(0.15,0.25,0,1,0); pixel(0.35,0.25,0,1,0)
	pixel(0.15,0.65,0,0,1); pixel(0.35,0.65,0,0,1)
	Spring.Echo("[vaotest] PASS indexed/array instancing + fixed ushort restart + rejection recovery; frame " .. Spring.GetGameFrame())
	gl.Blending(true)
end
function widget:Shutdown()
	if vao then vao:Delete() end
	if uintVAO then uintVAO:Delete() end
	for _,vbo in ipairs(buffers) do vbo:Delete() end
	if shader then gl.DeleteShader(shader) end
end
