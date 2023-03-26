local Players = game:GetService("Players")

-------------------------------------------------------------------------------
-- init
local toggle = false
local gm
local original
--- used to prevent recursives
local prevTables = {}
--- how many spaces to indent
local indent = 4
--- used for task scheduler
local scheduled = {}
local topstr = ""
local bottomstr = ""
local p
local getnilrequired = false

-- autoblock variables

-- function info variables
local funcEnabled = true

-- remote hooking/connecting api variables
local remoteSignals = {}
local remoteHooks = {}

-- original mouse icon
local oldIcon

-- if mouse inside gui
local mouseInGui = false

-- handy array of RBXScriptConnections to disconnect on shutdown
local connections = {}

-- whether or not SimpleSpy uses 'getcallingscript()' to get the script (default is false because detection)
local useGetCallingScript = false

--- used to enable/disable SimpleSpy's keyToString for remotes
local keyToString = false

-- determines whether return values are recorded
local recordReturnValues = false

-- functions

--- Converts arguments to a string and generates code that calls the specified method with them, recommended to be used in conjunction with ValueToString (method must be a string, e.g. `game:GetService("ReplicatedStorage").Remote.remote:FireServer`)
--- @param method string
--- @param args any[]
--- @return string
function SimpleSpy:ArgsToString(method, args)
	assert(typeof(method) == "string", "string expected, got " .. typeof(method))
	assert(typeof(args) == "table", "table expected, got " .. typeof(args))
	return v2v({ args = args }) .. "\n\n" .. method .. "(unpack(args))"
end

--- Converts a value to variables with the specified index as the variable name (if nil/invalid then the name will be assigned automatically)
--- @param t any[]
--- @return string
function SimpleSpy:TableToVars(t)
	assert(typeof(t) == "table", "table expected, got " .. typeof(t))
	return v2v(t)
end

--- Converts a value to a variable with the specified `variablename` (if nil/invalid then the name will be assigned automatically)
--- @param value any
--- @return string
function SimpleSpy:ValueToVar(value, variablename)
	assert(variablename == nil or typeof(variablename) == "string", "string expected, got " .. typeof(variablename))
	if not variablename then
		variablename = 1
	end
	return v2v({ [variablename] = value })
end

--- Converts any value to a string, cannot preserve function contents
--- @param value any
--- @return string
function SimpleSpy:ValueToString(value)
	return v2s(value)
end

--- Generates the simplespy function info
--- @param func function
--- @return string
function SimpleSpy:GetFunctionInfo(func)
	assert(typeof(func) == "function", "Instance expected, got " .. typeof(func))
	warn("Function info currently unavailable due to crashing in Synapse X")
	return v2v({ functionInfo = {
		info = debug.getinfo(func),
		constants = debug.getconstants(func),
	} })
end

--- Gets the ScriptSignal for a specified remote being fired
--- @param remote Instance
function SimpleSpy:GetRemoteFiredSignal(remote)
	assert(typeof(remote) == "Instance", "Instance expected, got " .. typeof(remote))
	if not remoteSignals[remote] then
		remoteSignals[remote] = newSignal()
	end
	return remoteSignals[remote]
end

--- Allows for direct hooking of remotes **THIS CAN BE VERY DANGEROUS**
--- @param remote Instance
--- @param f function
function SimpleSpy:HookRemote(remote, f)
	assert(typeof(remote) == "Instance", "Instance expected, got " .. typeof(remote))
	assert(typeof(f) == "function", "function expected, got " .. typeof(f))
	remoteHooks[remote] = f
end

--- Blocks the specified remote instance/string
--- @param remote any
function SimpleSpy:BlockRemote(remote)
	assert(
		typeof(remote) == "Instance" or typeof(remote) == "string",
		"Instance | string expected, got " .. typeof(remote)
	)
	blocklist[remote] = true
end

--- Excludes the specified remote from logs (instance/string)
--- @param remote any
function SimpleSpy:ExcludeRemote(remote)
	assert(
		typeof(remote) == "Instance" or typeof(remote) == "string",
		"Instance | string expected, got " .. typeof(remote)
	)
	blacklist[remote] = true
end

--- Creates a new ScriptSignal that can be connected to and fired
--- @return table
function newSignal()
	local connected = {}
	return {
		Connect = function(self, f)
			assert(connected, "Signal is closed")
			connected[tostring(f)] = f
			return {
				Connected = true,
				Disconnect = function(self)
					if not connected then
						warn("Signal is already closed")
					end
					self.Connected = false
					connected[tostring(f)] = nil
				end,
			}
		end,
		Wait = function(self)
			local thread = coroutine.running()
			local connection
			connection = self:Connect(function()
				connection:Disconnect()
				if coroutine.status(thread) == "suspended" then
					coroutine.resume(thread)
				end
			end)
			coroutine.yield()
		end,
		Fire = function(self, ...)
			for _, f in pairs(connected) do
				coroutine.wrap(f)(...)
			end
		end,
	}
end

--- Gets the player an instance is descended from
function getPlayerFromInstance(instance)
	for _, v in pairs(Players:GetPlayers()) do
		if v.Character and (instance:IsDescendantOf(v.Character) or instance == v.Character) then
			return v
		end
	end
end

--- Generates a script from the provided arguments (first has to be remote path)
function genScript(remote, args)
	prevTables = {}
	local gen = ""
	if #args > 0 then
		if not pcall(function()
			gen = v2v({ args = args }) .. "\n"
		end) then
			gen = gen
				.. "-- TableToString failure! Reverting to legacy functionality (results may vary)\nlocal args = {"
			if
				not pcall(function()
					for i, v in pairs(args) do
						if type(i) ~= "Instance" and type(i) ~= "userdata" then
							gen = gen .. "\n    [object] = "
						elseif type(i) == "string" then
							gen = gen .. '\n    ["' .. i .. '"] = '
						elseif type(i) == "userdata" and typeof(i) ~= "Instance" then
							gen = gen .. "\n    [" .. string.format("nil --[[%s]]", typeof(v)) .. ")] = "
						elseif type(i) == "userdata" then
							gen = gen .. "\n    [game." .. i:GetFullName() .. ")] = "
						end
						if type(v) ~= "Instance" and type(v) ~= "userdata" then
							gen = gen .. "object"
						elseif type(v) == "string" then
							gen = gen .. '"' .. v .. '"'
						elseif type(v) == "userdata" and typeof(v) ~= "Instance" then
							gen = gen .. string.format("nil --[[%s]]", typeof(v))
						elseif type(v) == "userdata" then
							gen = gen .. "game." .. v:GetFullName()
						end
					end
					gen = gen .. "\n}\n\n"
				end)
			then
				gen = gen .. "}\n-- Legacy tableToString failure! Unable to decompile."
			end
		end
		if not remote:IsDescendantOf(game) and not getnilrequired then
			gen = "function getNil(name,class) for _,v in pairs(getnilinstances())do if v.ClassName==class and v.Name==name then return v;end end end\n\n"
				.. gen
		end
		if remote:IsA("RemoteEvent") then
			gen = gen .. v2s(remote) .. ":FireServer(unpack(args))"
		elseif remote:IsA("RemoteFunction") then
			gen = gen .. v2s(remote) .. ":InvokeServer(unpack(args))"
		end
	else
		if remote:IsA("RemoteEvent") then
			gen = gen .. v2s(remote) .. ":FireServer()"
		elseif remote:IsA("RemoteFunction") then
			gen = gen .. v2s(remote) .. ":InvokeServer()"
		end
	end
	prevTables = {}
	return gen
end

--- value-to-string: value, string (out), level (indentation), parent table, var name, is from tovar
function v2s(v, l, p, n, vtv, i, pt, path, tables, tI)
	if not tI then
		tI = { 0 }
	else
		tI[1] += 1
	end
	if typeof(v) == "number" then
		if v == math.huge then
			return "math.huge"
		elseif tostring(v):match("nan") then
			return "0/0 --[[NaN]]"
		end
		return tostring(v)
	elseif typeof(v) == "boolean" then
		return tostring(v)
	elseif typeof(v) == "string" then
		return formatstr(v, l)
	elseif typeof(v) == "function" then
		return f2s(v)
	elseif typeof(v) == "table" then
		return t2s(v, l, p, n, vtv, i, pt, path, tables, tI)
	elseif typeof(v) == "Instance" then
		return i2p(v)
	elseif typeof(v) == "userdata" then
		return "newproxy(true)"
	elseif type(v) == "userdata" then
		return u2s(v)
	elseif type(v) == "vector" then
		return string.format("Vector3.new(%s, %s, %s)", v2s(v.X), v2s(v.Y), v2s(v.Z))
	else
		return "nil --[[" .. typeof(v) .. "]]"
	end
end

--- value-to-variable
--- @param t any
function v2v(t)
	topstr = ""
	bottomstr = ""
	getnilrequired = false
	local ret = ""
	local count = 1
	for i, v in pairs(t) do
		if type(i) == "string" and i:match("^[%a_]+[%w_]*$") then
			ret = ret .. "local " .. i .. " = " .. v2s(v, nil, nil, i, true) .. "\n"
		elseif tostring(i):match("^[%a_]+[%w_]*$") then
			ret = ret
				.. "local "
				.. tostring(i):lower()
				.. "_"
				.. tostring(count)
				.. " = "
				.. v2s(v, nil, nil, tostring(i):lower() .. "_" .. tostring(count), true)
				.. "\n"
		else
			ret = ret
				.. "local "
				.. type(v)
				.. "_"
				.. tostring(count)
				.. " = "
				.. v2s(v, nil, nil, type(v) .. "_" .. tostring(count), true)
				.. "\n"
		end
		count = count + 1
	end
	if getnilrequired then
		topstr = "function getNil(name,class) for _,v in pairs(getnilinstances())do if v.ClassName==class and v.Name==name then return v;end end end\n"
			.. topstr
	end
	if #topstr > 0 then
		ret = topstr .. "\n" .. ret
	end
	if #bottomstr > 0 then
		ret = ret .. bottomstr
	end
	return ret
end

--- table-to-string
--- @param t table
--- @param l number
--- @param p table
--- @param n string
--- @param vtv boolean
--- @param i any
--- @param pt table
--- @param path string
--- @param tables table
--- @param tI table
function t2s(t, l, p, n, vtv, i, pt, path, tables, tI)
	local globalIndex = table.find(getgenv(), t) -- checks if table is a global
	if type(globalIndex) == "string" then
		return globalIndex
	end
	if not tI then
		tI = { 0 }
	end
	if not path then -- sets path to empty string (so it doesn't have to manually provided every time)
		path = ""
	end
	if not l then -- sets the level to 0 (for indentation) and tables for logging tables it already serialized
		l = 0
		tables = {}
	end
	if not p then -- p is the previous table but doesn't really matter if it's the first
		p = t
	end
	for _, v in pairs(tables) do -- checks if the current table has been serialized before
		if n and rawequal(v, t) then
			bottomstr = bottomstr
				.. "\n"
				.. tostring(n)
				.. tostring(path)
				.. " = "
				.. tostring(n)
				.. tostring(({ v2p(v, p) })[2])
			return "{} --[[DUPLICATE]]"
		end
	end
	table.insert(tables, t) -- logs table to past tables
	local s = "{" -- start of serialization
	local size = 0
	l = l + indent -- set indentation level
	for k, v in pairs(t) do -- iterates over table
		size = size + 1 -- changes size for max limit
		if size > (_G.SimpleSpyMaxTableSize or 1000) then
			s = s
				.. "\n"
				.. string.rep(" ", l)
				.. "-- MAXIMUM TABLE SIZE REACHED, CHANGE '_G.SimpleSpyMaxTableSize' TO ADJUST MAXIMUM SIZE "
			break
		end
		if rawequal(k, t) then -- checks if the table being iterated over is being used as an index within itself (yay, lua)
			bottomstr = bottomstr
				.. "\n"
				.. tostring(n)
				.. tostring(path)
				.. "["
				.. tostring(n)
				.. tostring(path)
				.. "]"
				.. " = "
				.. (
					rawequal(v, k) and tostring(n) .. tostring(path)
					or v2s(v, l, p, n, vtv, k, t, path .. "[" .. tostring(n) .. tostring(path) .. "]", tables)
				)
			size -= 1
			continue
		end
		local currentPath = "" -- initializes the path of 'v' within 't'
		if type(k) == "string" and k:match("^[%a_]+[%w_]*$") then -- cleanly handles table path generation (for the first half)
			currentPath = "." .. k
		else
			currentPath = "[" .. k2s(k, l, p, n, vtv, k, t, path .. currentPath, tables, tI) .. "]"
		end
		if size % 100 == 0 then
			scheduleWait()
		end
		-- actually serializes the member of the table
		s = s
			.. "\n"
			.. string.rep(" ", l)
			.. "["
			.. k2s(k, l, p, n, vtv, k, t, path .. currentPath, tables, tI)
			.. "] = "
			.. v2s(v, l, p, n, vtv, k, t, path .. currentPath, tables, tI)
			.. ","
	end
	if #s > 1 then -- removes the last comma because it looks nicer (no way to tell if it's done 'till it's done so...)
		s = s:sub(1, #s - 1)
	end
	if size > 0 then -- cleanly indents the last curly bracket
		s = s .. "\n" .. string.rep(" ", l - indent)
	end
	return s .. "}"
end

--- key-to-string
function k2s(v, ...)
	if keyToString then
		if typeof(v) == "userdata" and getrawmetatable(v) then
			return string.format(
				'"<void> (%s)" --[[Potentially hidden data (tostring in SimpleSpy:HookRemote/GetRemoteFiredSignal at your own risk)]]',
				safetostring(v)
			)
		elseif typeof(v) == "userdata" then
			return string.format('"<void> (%s)"', safetostring(v))
		elseif type(v) == "userdata" and typeof(v) ~= "Instance" then
			return string.format('"<%s> (%s)"', typeof(v), tostring(v))
		elseif type(v) == "function" then
			return string.format('"<Function> (%s)"', tostring(v))
		end
	end
	return v2s(v, ...)
end

--- function-to-string
function f2s(f)
	for k, x in pairs(getgenv()) do
		local isgucci, gpath
		if rawequal(x, f) then
			isgucci, gpath = true, ""
		elseif type(x) == "table" then
			isgucci, gpath = v2p(f, x)
		end
		if isgucci and type(k) ~= "function" then
			if type(k) == "string" and k:match("^[%a_]+[%w_]*$") then
				return k .. gpath
			else
				return "getgenv()[" .. v2s(k) .. "]" .. gpath
			end
		end
	end
	if funcEnabled and debug.getinfo(f).name:match("^[%a_]+[%w_]*$") then
		return "function()end --[[" .. debug.getinfo(f).name .. "]]"
	end
	return "function()end --[[" .. tostring(f) .. "]]"
end

--- instance-to-path
--- @param i userdata
function i2p(i)
	local player = getplayer(i)
	local parent = i
	local out = ""
	if parent == nil then
		return "nil"
	elseif player then
		while true do
			if parent and parent == player.Character then
				if player == Players.LocalPlayer then
					return 'game:GetService("Players").LocalPlayer.Character' .. out
				else
					return i2p(player) .. ".Character" .. out
				end
			else
				if parent.Name:match("[%a_]+[%w+]*") ~= parent.Name then
					out = ":FindFirstChild(" .. formatstr(parent.Name) .. ")" .. out
				else
					out = "." .. parent.Name .. out
				end
			end
			parent = parent.Parent
		end
	elseif parent ~= game then
		while true do
			if parent and parent.Parent == game then
				local service = game:FindService(parent.ClassName)
				if service then
					if parent.ClassName == "Workspace" then
						return "workspace" .. out
					else
						return 'game:GetService("' .. service.ClassName .. '")' .. out
					end
				else
					if parent.Name:match("[%a_]+[%w_]*") then
						return "game." .. parent.Name .. out
					else
						return "game:FindFirstChild(" .. formatstr(parent.Name) .. ")" .. out
					end
				end
			elseif parent.Parent == nil then
				getnilrequired = true
				return "getNil(" .. formatstr(parent.Name) .. ', "' .. parent.ClassName .. '")' .. out
			elseif parent == Players.LocalPlayer then
				out = ".LocalPlayer" .. out
			else
				if parent.Name:match("[%a_]+[%w_]*") ~= parent.Name then
					out = ":FindFirstChild(" .. formatstr(parent.Name) .. ")" .. out
				else
					out = "." .. parent.Name .. out
				end
			end
			parent = parent.Parent
		end
	else
		return "game"
	end
end

--- userdata-to-string: userdata
--- @param u userdata
function u2s(u)
	if typeof(u) == "TweenInfo" then
		-- TweenInfo
		return "TweenInfo.new("
			.. tostring(u.Time)
			.. ", Enum.EasingStyle."
			.. tostring(u.EasingStyle)
			.. ", Enum.EasingDirection."
			.. tostring(u.EasingDirection)
			.. ", "
			.. tostring(u.RepeatCount)
			.. ", "
			.. tostring(u.Reverses)
			.. ", "
			.. tostring(u.DelayTime)
			.. ")"
	elseif typeof(u) == "Ray" then
		-- Ray
		return "Ray.new(" .. u2s(u.Origin) .. ", " .. u2s(u.Direction) .. ")"
	elseif typeof(u) == "NumberSequence" then
		-- NumberSequence
		local ret = "NumberSequence.new("
		for i, v in pairs(u.KeyPoints) do
			ret = ret .. tostring(v)
			if i < #u.Keypoints then
				ret = ret .. ", "
			end
		end
		return ret .. ")"
	elseif typeof(u) == "DockWidgetPluginGuiInfo" then
		-- DockWidgetPluginGuiInfo
		return "DockWidgetPluginGuiInfo.new(Enum.InitialDockState" .. tostring(u) .. ")"
	elseif typeof(u) == "ColorSequence" then
		-- ColorSequence
		local ret = "ColorSequence.new("
		for i, v in pairs(u.KeyPoints) do
			ret = ret .. "Color3.new(" .. tostring(v) .. ")"
			if i < #u.Keypoints then
				ret = ret .. ", "
			end
		end
		return ret .. ")"
	elseif typeof(u) == "BrickColor" then
		-- BrickColor
		return "BrickColor.new(" .. tostring(u.Number) .. ")"
	elseif typeof(u) == "NumberRange" then
		-- NumberRange
		return "NumberRange.new(" .. tostring(u.Min) .. ", " .. tostring(u.Max) .. ")"
	elseif typeof(u) == "Region3" then
		-- Region3
		local center = u.CFrame.Position
		local size = u.CFrame.Size
		local vector1 = center - size / 2
		local vector2 = center + size / 2
		return "Region3.new(" .. u2s(vector1) .. ", " .. u2s(vector2) .. ")"
	elseif typeof(u) == "Faces" then
		-- Faces
		local faces = {}
		if u.Top then
			table.insert(faces, "Enum.NormalId.Top")
		end
		if u.Bottom then
			table.insert(faces, "Enum.NormalId.Bottom")
		end
		if u.Left then
			table.insert(faces, "Enum.NormalId.Left")
		end
		if u.Right then
			table.insert(faces, "Enum.NormalId.Right")
		end
		if u.Back then
			table.insert(faces, "Enum.NormalId.Back")
		end
		if u.Front then
			table.insert(faces, "Enum.NormalId.Front")
		end
		return "Faces.new(" .. table.concat(faces, ", ") .. ")"
	elseif typeof(u) == "EnumItem" then
		return tostring(u)
	elseif typeof(u) == "Enums" then
		return "Enum"
	elseif typeof(u) == "Enum" then
		return "Enum." .. tostring(u)
	elseif typeof(u) == "RBXScriptSignal" then
		return "nil --[[RBXScriptSignal]]"
	elseif typeof(u) == "Vector3" then
		return string.format("Vector3.new(%s, %s, %s)", v2s(u.X), v2s(u.Y), v2s(u.Z))
	elseif typeof(u) == "CFrame" then
		local xAngle, yAngle, zAngle = u:ToEulerAnglesXYZ()
		return string.format(
			"CFrame.new(%s, %s, %s) * CFrame.Angles(%s, %s, %s)",
			v2s(u.X),
			v2s(u.Y),
			v2s(u.Z),
			v2s(xAngle),
			v2s(yAngle),
			v2s(zAngle)
		)
	elseif typeof(u) == "DockWidgetPluginGuiInfo" then
		return string.format(
			"DockWidgetPluginGuiInfo(%s, %s, %s, %s, %s, %s, %s)",
			"Enum.InitialDockState.Right",
			v2s(u.InitialEnabled),
			v2s(u.InitialEnabledShouldOverrideRestore),
			v2s(u.FloatingXSize),
			v2s(u.FloatingYSize),
			v2s(u.MinWidth),
			v2s(u.MinHeight)
		)
	elseif typeof(u) == "PathWaypoint" then
		return string.format("PathWaypoint.new(%s, %s)", v2s(u.Position), v2s(u.Action))
	elseif typeof(u) == "UDim" then
		return string.format("UDim.new(%s, %s)", v2s(u.Scale), v2s(u.Offset))
	elseif typeof(u) == "UDim2" then
		return string.format(
			"UDim2.new(%s, %s, %s, %s)",
			v2s(u.X.Scale),
			v2s(u.X.Offset),
			v2s(u.Y.Scale),
			v2s(u.Y.Offset)
		)
	elseif typeof(u) == "Rect" then
		return string.format("Rect.new(%s, %s)", v2s(u.Min), v2s(u.Max))
	else
		return string.format("nil --[[%s]]", typeof(u))
	end
end

--- Gets the player an instance is descended from
function getplayer(instance)
	for _, v in pairs(Players:GetPlayers()) do
		if v.Character and (instance:IsDescendantOf(v.Character) or instance == v.Character) then
			return v
		end
	end
end

--- value-to-path (in table)
function v2p(x, t, path, prev)
	if not path then
		path = ""
	end
	if not prev then
		prev = {}
	end
	if rawequal(x, t) then
		return true, ""
	end
	for i, v in pairs(t) do
		if rawequal(v, x) then
			if type(i) == "string" and i:match("^[%a_]+[%w_]*$") then
				return true, (path .. "." .. i)
			else
				return true, (path .. "[" .. v2s(i) .. "]")
			end
		end
		if type(v) == "table" then
			local duplicate = false
			for _, y in pairs(prev) do
				if rawequal(y, v) then
					duplicate = true
				end
			end
			if not duplicate then
				table.insert(prev, t)
				local found
				found, p = v2p(x, v, path, prev)
				if found then
					if type(i) == "string" and i:match("^[%a_]+[%w_]*$") then
						return true, "." .. i .. p
					else
						return true, "[" .. v2s(i) .. "]" .. p
					end
				end
			end
		end
	end
	return false, ""
end

--- format s: string, byte encrypt (for weird symbols)
function formatstr(s, indentation)
	if not indentation then
		indentation = 0
	end
	local handled, reachedMax = handlespecials(s, indentation)
	return '"'
		.. handled
		.. '"'
		.. (
			reachedMax
				and " --[[ MAXIMUM STRING SIZE REACHED, CHANGE '_G.SimpleSpyMaxStringSize' TO ADJUST MAXIMUM SIZE ]]"
			or ""
		)
end

--- Adds \'s to the text as a replacement to whitespace chars and other things because string.format can't yayeet
function handlespecials(value, indentation)
	local buildStr = {}
	local i = 1
	local char = string.sub(value, i, i)
	local indentStr
	while char ~= "" do
		if char == '"' then
			buildStr[i] = '\\"'
		elseif char == "\\" then
			buildStr[i] = "\\\\"
		elseif char == "\n" then
			buildStr[i] = "\\n"
		elseif char == "\t" then
			buildStr[i] = "\\t"
		elseif string.byte(char) > 126 or string.byte(char) < 32 then
			buildStr[i] = string.format("\\%d", string.byte(char))
		else
			buildStr[i] = char
		end
		i = i + 1
		char = string.sub(value, i, i)
		if i % 200 == 0 then
			indentStr = indentStr or string.rep(" ", indentation + indent)
			table.move({ '"\n', indentStr, '... "' }, 1, 3, i, buildStr)
			i += 3
		end
	end
	return table.concat(buildStr)
end

-- safe (ish) tostring
function safetostring(v: any)
	if typeof(v) == "userdata" or type(v) == "table" then
		local mt = getrawmetatable(v)
		local badtostring = mt and rawget(mt, "__tostring")
		if mt and badtostring then
			rawset(mt, "__tostring", nil)
			local out = tostring(v)
			rawset(mt, "__tostring", badtostring)
			return out
		end
	end
	return tostring(v)
end

--- finds script from 'src' from getinfo, returns nil if not found
--- @param src string
function getScriptFromSrc(src)
	local realPath
	local runningTest
	--- @type number
	local s, e
	local match = false
	if src:sub(1, 1) == "=" then
		realPath = game
		s = 2
	else
		runningTest = src:sub(2, e and e - 1 or -1)
		for _, v in pairs(getnilinstances()) do
			if v.Name == runningTest then
				realPath = v
				break
			end
		end
		s = #runningTest + 1
	end
	if realPath then
		e = src:sub(s, -1):find("%.")
		local i = 0
		repeat
			i += 1
			if not e then
				runningTest = src:sub(s, -1)
				local test = realPath.FindFirstChild(realPath, runningTest)
				if test then
					realPath = test
				end
				match = true
			else
				runningTest = src:sub(s, e)
				local test = realPath.FindFirstChild(realPath, runningTest)
				local yeOld = e
				if test then
					realPath = test
					s = e + 2
					e = src:sub(e + 2, -1):find("%.")
					e = e and e + yeOld or e
				else
					e = src:sub(e + 2, -1):find("%.")
					e = e and e + yeOld or e
				end
			end
		until match or i >= 50
	end
	return realPath
end

--- schedules the provided function (and calls it with any args after)
function schedule(f, ...)
	table.insert(scheduled, { f, ... })
end

--- yields the current thread until the scheduler gives the ok
function scheduleWait()
	local thread = coroutine.running()
	schedule(function()
		coroutine.resume(thread)
	end)
	coroutine.yield()
end

--- the big (well tbh small now) boi task scheduler himself, handles p much anything as quicc as possible
function taskscheduler()
	if not toggle then
		scheduled = {}
		return
	end
	if #scheduled > 1000 then
		table.remove(scheduled, #scheduled)
	end
	if #scheduled > 0 then
		local currentf = scheduled[1]
		table.remove(scheduled, 1)
		if type(currentf) == "table" and type(currentf[1]) == "function" then
			pcall(unpack(currentf))
		end
	end
end

return genScript
