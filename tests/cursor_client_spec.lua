describe("cursor completion client", function()
  local cursor_client
  local original_system
  local original_executable

  before_each(function()
    package.loaded["zxz.core.cursor_client"] = nil
    cursor_client = require("zxz.core.cursor_client")
    original_system = vim.system
    original_executable = vim.fn.executable
    vim.fn.executable = function(cmd)
      if cmd == "cursor-agent" then
        return 1
      end
      return original_executable(cmd)
    end
  end)

  after_each(function()
    vim.system = original_system
    vim.fn.executable = original_executable
  end)

  it("streams running-total assistant text as deltas", function()
    local chunks = {}
    vim.system = function(_, opts, on_exit)
      vim.schedule(function()
        opts.stdout(nil, '{"type":"assistant","message":{"content":"hel"}}\n')
        vim.schedule(function()
          opts.stdout(nil, '{"type":"assistant","message":{"content":"hello"}}\n')
          vim.schedule(function()
            on_exit({ code = 0 })
          end)
        end)
      end)
      return { kill = function() end }
    end

    cursor_client.stream_completion({ command = "cursor-agent" }, {
      prefix = "local x = ",
      suffix = "",
    }, function(text)
      chunks[#chunks + 1] = text
    end, function() end)

    assert.is_true(vim.wait(500, function()
      return #chunks >= 2
    end))
    assert.are.equal("hel", chunks[1])
    assert.are.equal("lo", chunks[2])
  end)

  it("returns partial output when the process exits non-zero", function()
    local chunks = {}
    local done = false
    vim.system = function(_, opts, on_exit)
      vim.schedule(function()
        opts.stdout(nil, '{"type":"assistant","message":{"content":"ok"}}\n')
        vim.schedule(function()
          on_exit({ code = 1 })
        end)
      end)
      return { kill = function() end }
    end

    cursor_client.stream_completion({ command = "cursor-agent" }, {
      prefix = "local x = ",
      suffix = "",
    }, function(text)
      chunks[#chunks + 1] = text
    end, function(err)
      done = true
      assert.is_nil(err)
    end)

    assert.is_true(vim.wait(500, function()
      return done
    end))
    assert.are.equal("ok", chunks[1])
  end)

  it("kill abort stops further chunks", function()
    local chunks = {}
    vim.system = function(_, opts, on_exit)
      local handle = { killed = false }
      function handle:kill()
        self.killed = true
        on_exit({ code = 9 })
      end
      vim.schedule(function()
        opts.stdout(nil, '{"type":"assistant","message":{"content":"a"}}\n')
      end)
      return handle
    end

    local abort = cursor_client.stream_completion({ command = "cursor-agent" }, {
      prefix = "local x = ",
      suffix = "",
    }, function(text)
      chunks[#chunks + 1] = text
    end, function() end)

    assert.is_true(vim.wait(200, function()
      return #chunks > 0
    end))
    abort()
    local count = #chunks
    vim.wait(100)
    assert.are.equal(count, #chunks)
  end)
end)
