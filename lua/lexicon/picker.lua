local lex = require("lexicon")
local M   = {}

--- Open a lexicon picker for lang_key.
-- @param lang_key string|nil  e.g. "en", "pt", "de". Defaults to config.default_lang.
-- @param opts     table|nil   Merged into Snacks.picker opts.
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
    for i, s in ipairs(cfg.sources) do
      if s == opts.default_source then lex._state.source_idx = i; break end
    end
    opts.default_source = nil
  end

  -- load word list (~100ms for 200k words)
  local items = {}
  for line in io.lines(wf) do
    if line ~= "" then
      items[#items + 1] = { text = line, word = line }
    end
  end

  Snacks.picker.pick(vim.tbl_extend("force", {
    source  = "lexicon_" .. lang_key,
    title   = ("Lexicon  [%s]"):format(cfg.label),
    pattern = vim.fn.expand("<cword>"),
    layout  = { preview = "right" },
    format  = "text",   -- items have no 'file' field; use text formatter
    items   = items,

    -- Async preview: fetch definition from dict.org
    preview = function(ctx)
      local word    = ctx.item.word
      local src     = lex.current_source(lang_key)
      local bufnr   = ctx.buf  -- capture now; preview may change item
      ctx.preview:set_lines({ ("[%s]  fetching %q …"):format(src, word) })

      lex.fetch(word, src, function(lines)
        if #lines == 0 then lines = { "no definition found: " .. word } end
        lines[#lines + 1] = ""
        lines[#lines + 1] = ("── %s ──"):format(src)
        -- write to the captured buf; guard in case picker closed
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.bo[bufnr].modifiable = true
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
          vim.bo[bufnr].modifiable = false
        end
      end)
    end,

    -- <CR>: insert selected word at cursor position
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          vim.api.nvim_put({ item.word }, "c", true, true)
        end)
      end
    end,

    -- <C-n>: cycle dict.org source, refresh preview in place
    actions = {
      lexicon_cycle_source = function(picker)
        local src  = lex.cycle_source(lang_key)
        local item = picker.list:current()
        vim.notify(("lexicon source → %s"):format(src), vim.log.levels.INFO)
        if item then
          picker.preview:set_lines({ ("[%s]  fetching %q …"):format(src, item.word) })
          local bufnr = picker.preview.win.buf
          lex.fetch(item.word, src, function(lines)
            if #lines == 0 then lines = { "no definition found: " .. item.word } end
            lines[#lines + 1] = ""
            lines[#lines + 1] = ("── %s ──"):format(src)
            if vim.api.nvim_buf_is_valid(bufnr) then
              vim.bo[bufnr].modifiable = true
              vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
              vim.bo[bufnr].modifiable = false
            end
          end)
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

-- Convenience wrappers per language: M.en(), M.pt(), M.de() …
-- Generated at require-time from configured languages.
for key in pairs(lex.config.languages) do
  local k = key
  M[k] = function(o) M.open(k, o) end
end

return M
