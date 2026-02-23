local api = require("zeroxzero.api")

local M = {}

---Handle a question.asked SSE event
---@param props table {id, sessionID, questions, tool?}
function M.handle(props)
  local id = props.id
  local questions = props.questions
  if not id or not questions or #questions == 0 then
    return
  end

  local all_answers = {}

  local function ask_next(idx)
    if idx > #questions then
      -- All questions answered — send reply
      api.reply_question(id, all_answers, function(err)
        if err then
          vim.notify("Failed to reply to question: " .. err, vim.log.levels.ERROR)
        end
      end)
      return
    end

    local q = questions[idx]
    local options = q.options or {}
    local labels = {}
    for _, opt in ipairs(options) do
      local label = opt.label
      if opt.description and opt.description ~= "" then
        label = label .. " — " .. opt.description
      end
      table.insert(labels, label)
    end

    -- Add custom input option if allowed
    local custom = q.custom ~= false
    if custom then
      table.insert(labels, "[Custom input]")
    end

    local prompt = q.question or "Question"
    if q.header and q.header ~= "" then
      prompt = "[" .. q.header .. "] " .. prompt
    end

    if q.multiple then
      -- Multiple selection: use sequential vim.ui.select calls
      M._multi_select(prompt, options, labels, custom, function(answers)
        if not answers then
          api.reject_question(id, function() end)
          return
        end
        table.insert(all_answers, answers)
        ask_next(idx + 1)
      end)
    else
      -- Single selection
      vim.ui.select(labels, { prompt = prompt }, function(choice, choice_idx)
        if not choice then
          api.reject_question(id, function() end)
          return
        end

        if custom and choice_idx == #labels then
          -- Custom input selected
          vim.ui.input({ prompt = prompt .. " (custom): " }, function(input)
            if not input then
              api.reject_question(id, function() end)
              return
            end
            table.insert(all_answers, { input })
            ask_next(idx + 1)
          end)
        else
          local selected_label = options[choice_idx] and options[choice_idx].label or choice
          table.insert(all_answers, { selected_label })
          ask_next(idx + 1)
        end
      end)
    end
  end

  ask_next(1)
end

---Multi-select via sequential vim.ui.select with a "Done" option
---@param prompt string
---@param options table[]
---@param labels string[]
---@param custom boolean
---@param callback fun(answers: string[]?)
function M._multi_select(prompt, options, labels, custom, callback)
  local selected = {}

  local function pick()
    local current_labels = {}
    for i, label in ipairs(labels) do
      local prefix = selected[i] and "[x] " or "[ ] "
      -- Skip custom for multi-select
      if not (custom and i == #labels) then
        table.insert(current_labels, prefix .. label)
      end
    end
    table.insert(current_labels, "Done")

    vim.ui.select(current_labels, { prompt = prompt .. " (multi-select)" }, function(choice, idx)
      if not choice then
        callback(nil)
        return
      end

      if choice == "Done" then
        local answers = {}
        for i, opt in ipairs(options) do
          if selected[i] then
            table.insert(answers, opt.label)
          end
        end
        callback(answers)
        return
      end

      -- Toggle selection
      selected[idx] = not selected[idx]
      pick()
    end)
  end

  pick()
end

return M
