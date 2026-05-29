describe("acp inline completion lifecycle", function()
  local acp_client
  local config

  local function make_fake_client(overrides)
    overrides = overrides or {}
    local calls = {
      cancel = {},
      close = {},
      unsubscribe = {},
      prompt_opts = {},
    }

    local client = {
      state = "ready",
      callbacks = {},
      id_counter = 0,
      is_ready = function()
        return true
      end,
      start = function(self, on_ready)
        vim.schedule(function()
          on_ready(self)
        end)
      end,
      request = function(self, method, params, callback, opts)
        self.id_counter = self.id_counter + 1
        local id = self.id_counter
        self.callbacks[id] = { cb = callback, method = method, opts = opts }
        if method == "session/new" then
          vim.schedule(function()
            callback({ sessionId = "sess-test" }, nil)
          end)
        end
        return id
      end,
      new_session = function(self, cwd, callback)
        return self:request("session/new", { cwd = cwd }, callback)
      end,
      prompt = function(self, session_id, blocks, callback, opts)
        calls.prompt_opts[#calls.prompt_opts + 1] = opts
        if overrides.prompt_hangs then
          return self:request("session/prompt", { sessionId = session_id, prompt = blocks }, callback, opts)
        end
        vim.schedule(function()
          callback({}, nil)
        end)
        return 99
      end,
      set_model = function(_, _, callback)
        vim.schedule(function()
          callback(nil, nil)
        end)
        return nil
      end,
      subscribe = function() end,
      unsubscribe = function(_, sid)
        calls.unsubscribe[#calls.unsubscribe + 1] = sid
      end,
      cancel = function(_, sid)
        calls.cancel[#calls.cancel + 1] = sid
      end,
      close_session = function(_, sid)
        calls.close[#calls.close + 1] = sid
      end,
      forget_request = function(self, id)
        self.callbacks[id] = nil
      end,
    }

    return client, calls
  end

  before_each(function()
    config = require("zxz.core.config")
    config.setup({
      complete = {
        prompt_timeout_ms = 50,
      },
    })
    package.loaded["zxz.core.acp_client"] = nil
    acp_client = require("zxz.core.acp_client")
    acp_client._reset_client_factory()
  end)

  after_each(function()
    acp_client._reset_client_factory()
    if acp_client.stop_all_completion_clients then
      acp_client.stop_all_completion_clients()
    end
  end)

  it("close_session sends session/close notification", function()
    local notifies = {}
    local client = acp_client.new({ command = "fake", name = "fake" })
    client.notify = function(_, method, params)
      notifies[#notifies + 1] = { method = method, params = params }
    end

    client:close_session("sess-1")

    assert.are.equal("session/close", notifies[1].method)
    assert.are.equal("sess-1", notifies[1].params.sessionId)
  end)

  it("finish closes the session after a successful prompt", function()
    local fake_client, calls = make_fake_client()
    acp_client._set_client_factory(function()
      return fake_client
    end)

    local done_err = "pending"
    local abort = acp_client.stream_completion({ command = "fake" }, {
      prefix = "local x = ",
      suffix = "",
      cwd = "/tmp",
    }, function() end, function(err)
      done_err = err
    end)

    assert.is_true(vim.wait(500, function()
      return done_err ~= "pending"
    end))
    abort()

    assert.is_nil(done_err)
    assert.are.equal("sess-test", calls.close[1])
    assert.are.equal("sess-test", calls.unsubscribe[1])
  end)

  it("abort cancels and closes the session", function()
    local fake_client, calls = make_fake_client({ prompt_hangs = true })
    acp_client._set_client_factory(function()
      return fake_client
    end)

    local abort = acp_client.stream_completion({ command = "fake" }, {
      prefix = "local x = ",
      suffix = "",
      cwd = "/tmp",
    }, function() end, function() end)

    assert.is_true(vim.wait(500, function()
      return #calls.prompt_opts > 0
    end))

    abort()

    assert.are.equal("sess-test", calls.cancel[1])
    assert.are.equal("sess-test", calls.close[1])
    assert.are.equal("sess-test", calls.unsubscribe[1])
  end)

  it("passes prompt_timeout_ms to session/prompt requests", function()
    local fake_client, calls = make_fake_client()
    acp_client._set_client_factory(function()
      return fake_client
    end)

    local abort = acp_client.stream_completion({ command = "fake" }, {
      prefix = "local x = ",
      suffix = "",
      cwd = "/tmp",
    }, function() end, function() end)

    assert.is_true(vim.wait(500, function()
      return #calls.prompt_opts > 0
    end))
    abort()

    assert.are.same({ timeout_ms = 50 }, calls.prompt_opts[1])
  end)

  it("times out hung session/prompt requests", function()
    config.setup({
      complete = {
        prompt_timeout_ms = 50,
      },
    })

    local client = acp_client.new({ command = "fake-timeout", name = "fake" })
    client.transport = { set_idle_armed = function() end, send = function() end }

    local timed_out = false
    client:request("session/prompt", { sessionId = "sess-timeout", prompt = {} }, function(_, err)
      timed_out = err ~= nil
    end, { timeout_ms = 50 })

    assert.is_true(vim.wait(500, function()
      return timed_out
    end))
  end)
end)
