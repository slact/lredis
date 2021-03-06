local protocol = require "lredis.protocol"
local commands = require "lredis.commands"
local cs = require "cqueues.socket"
local cc = require "cqueues.condition"
local new_fifo = require "fifo"
local lpeg = require "lpeg"
local uri_patts = require "lpeg_patterns.uri"

local pack = table.pack or function(...) return {n = select("#", ...), ...} end

local methods = setmetatable({}, {__index = commands})
local mt = {
	__index = methods;
}

local function new(socket)
	socket:setmode("b", "b")
	socket:setvbuf("full", math.huge) -- 'infinite' buffering; no write locks needed
	return setmetatable({
		socket = socket;
		fifo = new_fifo();
		subscribes_pending = 0;
		subscribed_to = 0;
		in_transaction = false;
	}, mt)
end

local function connect_tcp(host, port)
	local socket = assert(cs.connect({
		host = host or "127.0.0.1";
		port = port or "6379";
		nodelay = true;
	}))
	assert(socket:connect())
	return new(socket)
end

local uri_lpeg = uri_patts.uri* lpeg.P(-1)

local splitquery_lpeg
do
	--from luatex, http://mirror.unl.edu/ctan/macros/luatex/generic/lualibs/lualibs-url.lua
	local tochar      = function(s) return char(tonumber(s,16)) end
	local amp, equal, percent, hexdigit, endofstring = lpeg.P("&"), lpeg.P("="), lpeg.P("%"), lpeg.R("09","AF","af"), lpeg.P(-1)
	local escapedchar = (percent * lpeg.C(hexdigit * hexdigit)) / tochar
	local key   = lpeg.Cs(((escapedchar+1)-equal            )^0)
	local value = lpeg.Cs(((escapedchar+1)-amp  -endofstring)^0)
	splitquery_lpeg = lpeg.Cf ( lpeg.Ct("") * lpeg.P { "sequence",
		sequence = lpeg.V("pair") * (amp * lpeg.V("pair"))^0,
		pair     = lpeg.Cg(key * equal * value),
	}, rawset)
end
local function connect(url)
	url = url or ""
	local m = uri_lpeg:match(url) or uri_lpeg:match("redis://"..url)
	m.scheme = m.scheme or "redis"
	assert(m.scheme:match("rediss?"), "Expected uri scheme to be 'redis' or 'rediss', but got '"..m.scheme.."'")
	local self = connect_tcp(m.host, m.port)
	if m.scheme == "rediss" then
		self.socket:starttls()
	end
	
	local password
	local parsed_query
	if not m.userinfo and m.query then
		parsed_query = splitquery_lpeg:match(m.query)
		password = parsed_query.password
	elseif m.userinfo then
		password = m.userinfo:match("^.*:(.*)")
	end
	
	if password then
		self:call("AUTH", password)
	end
	
	local db
	if(not m.path or not m.path:match('^/[1-9]%d*$')) and m.query then
		parsed_query = parsed_query or splitquery_lpeg:match(m.query)
		db = parsed_query.db
	elseif m.path then
		db = m.path:match("^/(.*)")
	end
	
	if db then
		self:call("SELECT", db)
	end
	return self
end

function methods:close()
	self.socket:close()
end

-- call with table arg/return
function methods:pcallt(arg, new_status, new_error, string_null, array_null)
	if self.subscribed_to > 0 or (self.subscribes_pending > 0 and not self.in_transaction) then
		error("cannot 'call' while in subscribe mode")
	end
	local cond = cc.new()
	local req = protocol.encode_request(arg)
	assert(self.socket:write(req))
	assert(self.socket:flush())
	self.fifo:push(cond)
	if self.fifo:peek() ~= cond then
		cond:wait()
	end
	local resp = protocol.read_response(self.socket, new_status, new_error, string_null, array_null)
	assert(self.fifo:pop() == cond)
	-- signal next thing in pipeline
	local next, ok = self.fifo:peek()
	if ok then
		next:signal()
	end
	return resp
end

-- call in vararg style
function methods:pcall(...)
	return self:pcallt(pack(...), protocol.status_reply, protocol.error_reply, protocol.string_null, protocol.array_null)
end

-- need locking around sending subscribe, as you won't know
function methods:start_subscription_modet(arg)
	if self.in_transaction then -- in a transaction
		-- read off "QUEUED"
		local resp = self:pcallt(arg, protocol.status_reply, protocol.error_reply, protocol.string_null, protocol.array_null)
		assert(type(resp) == "table" and resp.ok == "QUEUED")
	else
		local req = protocol.encode_request(arg)
		assert(self.socket:write(req))
		assert(self.socket:flush())
	end
	self.subscribes_pending = self.subscribes_pending + 1
end

function methods:start_subscription_mode(...)
	return self:start_subscription_modet(pack(...))
end

function methods:get_next(new_status, new_error, string_null, array_null)
	if self.in_transaction or (self.subscribed_to == 0 and self.subscribes_pending == 0) then
		return nil, "not in subscribe mode"
	end
	local resp = protocol.read_response(self.socket, new_status, new_error, string_null, array_null)
	local kind = resp[1]
	if kind == "subscribe" or kind == "unsubscribe" or kind == "psubscribe" or kind == "punsubscribe" then
		self.subscribed_to = resp[3]
		self.subscribes_pending = self.subscribes_pending - 1
	end
	return resp
end

function methods:start_transaction()
	self.in_transaction = true
end

function methods:end_transaction()
	self.in_transaction = false
end

return {
	new = new;
	connect_tcp = connect_tcp;
	connect = connect;
}
