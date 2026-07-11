local lex = require("lexicon")
local M   = {}

local function cat_cmd(path)
  if vim.fn.has("win32") == 1 then
    return { "cmd", "/c", "type", path }
  end
  return { "cat", path }
end

-- Populate preview buffer with an async dict.org lookup
local function update_preview(bufnr, word, src)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
    { ("[%s]  fetching %q …"):format(src, word) })

  lex.fetch(word, src, function(lines)
    if #lines == 0 then lines = { "no definition found: " .. word } end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("── %s ──"):format(src)
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end
  end)
end

--- Open a lexicon picker for lang_key.
-- @param lang_key string|nil  e.g. "en", "pt", "de". Defaults to config.default_lang.
-- @param opts     table|nil   Merged into Snacks.picker opts (title, default_text, …)
function M.open(lang_key, opts)
  opts     = opts or {}
  lang_key = lang_key or lex.config.default_lang

  local cfg = lex.lang_cfg(lang_key)
  local wf  = lex.words_file(lang_key)
  if not wf then
    vim.notify(
      ("snacks-lexicon [%s]: no word file found.\n"
        .. "Set languages.%s.word_files in require('lexicon').setup()."):format(lang_key, lang_key),
      vim.log.levels.WARN
    )
    return
  end

  -- reset source cycle; honour caller's default_source if given
  lex._state.source_idx = 1
  if opts.default_source then
    local sources = cfg.sources
    for i, s in ipairs(sources) do
      if s == opts.default_source then lex._state.source_idx = i; break end
    end
    opts.default_source = nil  -- don't leak into Snacks opts
  end

  Snacks.picker.pick(vim.tbl_extend("force", {
    source       = "lexicon_" .. lang_key,
    title        = ("Lexicon  [%s]"):format(cfg.label),
    default_text = vim.fn.expand("<cword>"),
    layout       = { preview = "right" },

    -- Stream words from the system word list
    finder = function()
      local items = {}
      for line in io.lines(wf) do
        if line ~= "" then
          items[#items + 1] = { text = line, word = line }
        end
      end
      return items
    end,

    -- Async preview: fetch definition from dict.org
    preview = function(ctx)
      update_preview(ctx.buf, ctx.item.word, lex.current_source(lang_key))
    end,

    -- <CR>: insert selected word at cursor
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.api.nvim_put({ item.word }, "c", true, true)
      end
    end,

    -- <C-n>: cycle dict.org source, refresh preview in place
    actions = {
      lexicon_cycle_source = function(picker)
        local src  = lex.cycle_source(lang_key)
        local item = picker.list:current()
        vim.notify(("lexicon source → %s"):format(src), vim.log.levels.INFO)
        if item and picker.preview then
          update_preview(vim.api.nvim_win_get_buf(picker.preview.win), item.word, src)
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-n>"] = { "lexicon_cycle_source", mode = { "i", "n" } },
        },
      },
    },
  }, opts))
end

-- Convenience wrappers per language, callable as M.en(), M.pt(), etc.
-- Generated at require-time from whatever languages are in config.
for key in pairs(lex.config.languages) do
  local k = key
  M[k] = function(opts) M.open(k, opts) end
end

return M
