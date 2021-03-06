describe("lredis.cqueues module", function()
	local lc = require "lredis.cqueues"
	local cqueues = require "cqueues"
	local cs = require "cqueues.socket"
	local interact = function(sock, script)
		for i,act in ipairs(script) do
			if act.read then
				for j, l in ipairs(act) do
					local data, err = sock:read("*l")
					assert.same(l, data)
				end
			elseif act.write then
				for j, l in ipairs(act) do
					assert(sock:xwrite(l.."\r\n", "bn"))
				end
			end
		end
	end
	local testInteraction = function(client_fn, server_script)
		return function()
			local m = cs.listen{host="127.0.0.1", port="0"}
			local _, host, port = m:localname()
			local cq = cqueues.new()
			cq:wrap(function()
				client_fn(host, port)
			end)
			cq:wrap(function()
				local s = m:accept()
				interact(s, server_script)
				s:close()
			end)
			assert(cq:loop(1))
			assert(cq:empty())
		end
	end
	local read = function(...) return {read=true, ...} end
	local write = function(...) return {write=true, ...} end

	it(":close closes the socket", function()
		local c, s = cs.pair()
		local r = lc.new(c)
		r:close()
		assert.same(nil, s:read())
		s:close()
	end)
	it(":ping works", function()
		local c, s = cs.pair()
		local r = lc.new(c)
		local cq = cqueues.new()
		cq:wrap(function()
			assert(r:ping() == "PONG")
		end)
		cq:wrap(function()
			assert(s:xwrite("+PONG\r\n", "bn"))
		end)
		assert(cq:loop(1))
		assert(cq:empty())
		r:close()
		s:close()
	end)
	it(":ping works outside of coroutine", function()
		local c, s = cs.pair()
		local r = lc.new(c)
		assert(s:xwrite("+PONG\r\n", "bn"))
		assert(r:ping() == "PONG")
		r:close()
		s:close()
	end)
	it("supports pipelining", function()
		local c, s = cs.pair()
		local r = lc.new(c)
		local cq = cqueues.new()
		cq:wrap(function()
			assert(r:ping() == "PONG1")
		end)
		cq:wrap(function()
			cqueues.sleep(0.01)
			assert(r:ping() == "PONG2")
		end)
		cq:wrap(function()
			cqueues.sleep(0.02)
			assert(s:xwrite("+PONG1\r\n", "bn"))
			assert(s:xwrite("+PONG2\r\n", "bn"))
		end)
		assert(cq:loop(1))
		assert(cq:empty())
		r:close()
		s:close()
	end)
	it("supports pubsub", function()
		local c, s = cs.pair()
		local r = lc.new(c)
		local cq = cqueues.new()
		cq:wrap(function()
			r:subscribe("foo")
			assert.same({"subscribe", "foo", 1}, r:get_next())
			assert.same({"publish", "foo", "message"}, r:get_next())
			r:unsubscribe("foo")
			assert.same({"unsubscribe", "foo", 0}, r:get_next())
			assert.same(nil, r:get_next())
		end)
		cq:wrap(function()
			assert(s:xwrite("*3\r\n$9\r\nsubscribe\r\n$3\r\nfoo\r\n:1\r\n", "bn"))
			assert(s:xwrite("*3\r\n$7\r\npublish\r\n$3\r\nfoo\r\n$7\r\nmessage\r\n", "bn"))
			assert(s:xwrite("*3\r\n$11\r\nunsubscribe\r\n$3\r\nfoo\r\n:0\r\n", "bn"))
		end)
		assert(cq:loop(1))
		assert(cq:empty())
		r:close()
		s:close()
	end)
	it("supports transactions", function()
		local c, s = cs.pair()
		local r = lc.new(c)
		local cq = cqueues.new()
		cq:wrap(function()
			assert.same("OK", r:multi())
			assert.same("QUEUED", r:ping())
			assert.same({{ok="PONG"}}, r:exec())
		end)
		cq:wrap(function()
			assert(s:xwrite("+OK\r\n", "bn"))
			assert(s:xwrite("+QUEUED\r\n", "bn"))
			assert(s:xwrite("*1\r\n+PONG\r\n", "bn"))
		end)
		assert(cq:loop(1))
		assert(cq:empty())
		r:close()
		s:close()
	end)
	it("works when you mix pubsub and transactions", function()
		local c, s = cs.pair()
		local r = lc.new(c)
		local cq = cqueues.new()
		cq:wrap(function()
			assert.same("OK", r:multi())
			r:subscribe("test")
			assert.same({{"subscribe", "test", 1}}, r:exec())
		end)
		cq:wrap(function()
			assert(s:xwrite("+OK\r\n", "bn"))
			assert(s:xwrite("+QUEUED\r\n", "bn"))
			assert(s:xwrite("*1\r\n*3\r\n$9\r\nsubscribe\r\n$4\r\ntest\r\n:1\r\n", "bn"))
		end)
		assert(cq:loop(1))
		assert(cq:empty())
		r:close()
		s:close()
	end)
	it("has working connect_tcp constructor", testInteraction(function(host, port)
		local r = lc.connect_tcp(host, port)
		r:ping()
		r:close()
	end, {
		read ("*1", "$4", "PING"),
		write("+PONG"),
	}))
	it("has working connect constructor", testInteraction(function(host, port)
		local r = lc.connect("redis://:password@localhost:"..port.."/5")
		assert.same(r:ping(), "PONG")
		r:close()
	end, {
		read ("*2", "$4", "AUTH", "$8", "password"),
		write("+OK"),
		read ("*2", "$6", "SELECT", "$1", "5"),
		write("+OK"),
		read ("*1", "$4", "PING"),
		write("+PONG"),
	}))
	it("has working connect constructor that can parse the querystring", testInteraction(function(host, port)
		local r = lc.connect("redis://localhost:"..port.."/foo?password=password&db=5")
		assert.same(r:ping(), "PONG")
		r:close()
	end, {
		read ("*2", "$4", "AUTH", "$8", "password"),
		write("+OK"),
		read ("*2", "$6", "SELECT", "$1", "5"),
		write("+OK"),
		read ("*1", "$4", "PING"),
		write("+PONG"),
	}))
	it(":hmget works", testInteraction(function(host, port)
		local r = lc.connect(host..":"..port)
		assert.same(r:hmget("foo", "one", "two"), {one="this", two=false})
		r:close()
	end, {
		read ("*4", "$5", "HMGET", "$3", "foo", "$3", "one", "$3", "two"),
		write("*2", "$4", "this", "$-1"),
	}))
	it(":hmset works", testInteraction(function(host, port)
		local r = lc.connect(host..":"..port)
		assert.same(r:hmset("foo", {one="1"}), "OK")
		r:close()
	end, {
		read ("*4", "$5", "HMSET", "$3", "foo", "$3", "one", "$1", "1"),
		write("+OK")
	}))
	it(":hgetall works", testInteraction(function(host, port)
		local r = lc.connect(host..":"..port)
		assert.same(r:hgetall("foo"), {one="this", three="3"})
		r:close()
	end, {
		read ("*2", "$7", "HGETALL", "$3", "foo"),
		write("*4", "$3", "one", "$4", "this", "$5", "three", "$1", "3")
	}))
end)
