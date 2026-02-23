local api = require("zeroxzero.api")
local process = require("zeroxzero.process")

local M = {}

---Pick a session from the list and switch to it
function M.session_picker()
  process.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    api.get_sessions(function(get_err, response)
      if get_err then
        vim.notify("0x0: " .. get_err, vim.log.levels.ERROR)
        return
      end

      local sessions = response and response.body or {}
      if type(sessions) ~= "table" or #sessions == 0 then
        vim.notify("0x0: no sessions found", vim.log.levels.INFO)
        return
      end

      local items = {}
      for _, session in ipairs(sessions) do
        local title = session.title or session.id or "untitled"
        local id = session.id
        table.insert(items, { title = title, id = id })
      end

      vim.ui.select(items, {
        prompt = "Sessions",
        format_item = function(item)
          return item.title
        end,
      }, function(choice)
        if not choice then
          return
        end
        api.select_session(choice.id, function(select_err)
          if select_err then
            vim.notify("0x0: " .. select_err, vim.log.levels.ERROR)
          end
        end)
      end)
    end)
  end)
end

---Open model picker via TUI command
function M.model_picker()
  process.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end
    api.execute_command("model_list", function(cmd_err)
      if cmd_err then
        vim.notify("0x0: " .. cmd_err, vim.log.levels.ERROR)
      else
        process.show()
      end
    end)
  end)
end

---Pick a command from the server and execute it via the TUI
---Commands come from config.yaml, .zeroxzero/commands/*.md, MCP prompts, and skills
function M.command_picker()
  process.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    api.get_commands(function(get_err, response)
      if get_err then
        vim.notify("0x0: " .. get_err, vim.log.levels.ERROR)
        return
      end

      local commands = response and response.body or {}
      if type(commands) ~= "table" or #commands == 0 then
        vim.notify("0x0: no commands found", vim.log.levels.INFO)
        return
      end

      vim.ui.select(commands, {
        prompt = "Commands",
        format_item = function(item)
          local label = item.name or "unknown"
          if item.description and item.description ~= "" then
            label = label .. " — " .. item.description
          end
          if item.source then
            label = label .. " [" .. item.source .. "]"
          end
          return label
        end,
      }, function(choice)
        if not choice then
          return
        end

        local name = choice.name
        local hints = choice.hints or {}

        if #hints > 0 then
          -- Command has placeholders — prompt for arguments
          vim.ui.input({
            prompt = "0x0 /" .. name .. "> ",
          }, function(args)
            if not args then
              return
            end
            local text = "/" .. name .. " " .. args
            api.clear_prompt(function()
              api.append_prompt(text, function(append_err)
                if append_err then
                  vim.notify("0x0: " .. append_err, vim.log.levels.ERROR)
                  return
                end
                api.submit_prompt(function() end)
              end)
            end)
          end)
        else
          -- No arguments needed — submit directly
          local text = "/" .. name
          api.clear_prompt(function()
            api.append_prompt(text, function(append_err)
              if append_err then
                vim.notify("0x0: " .. append_err, vim.log.levels.ERROR)
                return
              end
              api.submit_prompt(function() end)
            end)
          end)
        end
      end)
    end)
  end)
end

---Pick an agent from the server and switch to it
---Agents come from config.yaml and .zeroxzero/agents/*.md
function M.agent_picker()
  process.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    api.get_agents(function(get_err, response)
      if get_err then
        vim.notify("0x0: " .. get_err, vim.log.levels.ERROR)
        return
      end

      local agents = response and response.body or {}
      if type(agents) ~= "table" or #agents == 0 then
        vim.notify("0x0: no agents found", vim.log.levels.INFO)
        return
      end

      -- Filter out hidden agents
      local visible = {}
      for _, agent in ipairs(agents) do
        if not agent.hidden then
          table.insert(visible, agent)
        end
      end

      vim.ui.select(visible, {
        prompt = "Agents",
        format_item = function(item)
          local label = item.displayName or item.name or "unknown"
          if item.description and item.description ~= "" then
            label = label .. " — " .. item.description
          end
          return label
        end,
      }, function(choice)
        if not choice then
          return
        end
        -- Cycle to agent via TUI command — append @agent and submit
        api.execute_command("agent_cycle", function(cmd_err)
          if cmd_err then
            vim.notify("0x0: " .. cmd_err, vim.log.levels.ERROR)
          else
            process.show()
          end
        end)
      end)
    end)
  end)
end

return M
