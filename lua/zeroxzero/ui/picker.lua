local api = require("zeroxzero.api")
local server = require("zeroxzero.server")

local M = {}

---Pick a session from the list and switch to it
function M.session_picker()
  server.ensure(function(err)
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
        local chat = require("zeroxzero.chat")
        chat.switch_session(choice.id)
        chat.open()
      end)
    end)
  end)
end

---Pick a model from available providers
function M.model_picker()
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    api.get_providers(function(get_err, response)
      if get_err then
        vim.notify("0x0: " .. get_err, vim.log.levels.ERROR)
        return
      end

      local providers = response and response.body or {}
      if type(providers) ~= "table" or #providers == 0 then
        vim.notify("0x0: no providers found", vim.log.levels.INFO)
        return
      end

      -- Build flat list of provider + model combos
      local items = {}
      for _, provider in ipairs(providers) do
        local models = provider.models or {}
        for _, model in ipairs(models) do
          table.insert(items, {
            providerID = provider.id,
            modelID = model.id or model,
            label = (provider.id or "?") .. "/" .. (model.id or model),
          })
        end
      end

      if #items == 0 then
        vim.notify("0x0: no models found", vim.log.levels.INFO)
        return
      end

      vim.ui.select(items, {
        prompt = "Models",
        format_item = function(item)
          return item.label
        end,
      }, function(choice)
        if not choice then
          return
        end
        local chat = require("zeroxzero.chat")
        chat.set_model({ providerID = choice.providerID, modelID = choice.modelID })
        vim.notify("0x0: model set to " .. choice.label, vim.log.levels.INFO)
      end)
    end)
  end)
end

---Pick a command from the server and send it as a prompt
function M.command_picker()
  server.ensure(function(err)
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
            label = label .. " \u{2014} " .. item.description
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
        local chat = require("zeroxzero.chat")

        if #hints > 0 then
          vim.ui.input({
            prompt = "0x0 /" .. name .. "> ",
          }, function(args)
            if not args then
              return
            end
            chat.send("/" .. name .. " " .. args)
          end)
        else
          chat.send("/" .. name)
        end
      end)
    end)
  end)
end

---Pick an agent from the server and set it for next prompt
function M.agent_picker()
  server.ensure(function(err)
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
            label = label .. " \u{2014} " .. item.description
          end
          return label
        end,
      }, function(choice)
        if not choice then
          return
        end
        local chat = require("zeroxzero.chat")
        chat.set_agent(choice.name)
        vim.notify("0x0: agent set to " .. (choice.displayName or choice.name), vim.log.levels.INFO)
      end)
    end)
  end)
end

return M
