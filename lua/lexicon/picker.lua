local lex = require("lexicon")
local M   = {}

-- Format raw DICT protocol lines into cleaner display lines
local function pretty(lines, word, src)
  local out = {}
  -- header: word + source
  out[#out + 1] = ("  %s"):format(word:upper())
  out[#out + 1] = ("  source: %s"):format(src)
  out[#out + 1] = ""

  for _, line in ipairs(lines) do
    -- blank lines → preserve spacing
    if line == "" then
      out[#out + 1] = ""
    -- definition number lines (e.g. "1. (n) cat --")
    elseif line:match("^%s*%d+%.") then
      out[#out + 1] = ""
      out[#out + 1] = line
    else
      out[#out + 1] = line
    end
  end

  return out
end

-- Write lines into a preview buffer, handling modifiable flag
local function write_buf(bufnr, lines)
  if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "snacks_picker_preview"
end

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
    title   = ("Lexicon [%s]"):format(cfg.label),
    pattern = vim.fn.expand("<cword>"),
    format  = "text",
    items   = items,

    -- wider layout: preview takes 65% of horizontal space
    layout = {
      layout = {
        box      = "horizontal",
        width    = 0.92,
        height   = 0.88,
        border   = "rounded",
        {
          box    = "vertical",
          border = true,
          title  = "{title} {live} {flags}",
          { win = "input", height = 1, border = "bottom" },
          { win = "list",  border = "none" },
        },
        { win = "preview", title = "{preview}", border = true, width = 0.72 },
      },
    },

    -- Async preview with pretty-print and source in title
    preview = function(ctx)
      local word  = ctx.item.word
      local src   = lex.current_source(lang_key)
      local bufnr = ctx.buf

      ctx.preview.win:set_title(src)
      ctx.preview:set_lines({ "", "  fetching…" })

      lex.fetch(word, src, function(lines)
        local out = #lines == 0
          and { "", "  no definition found: " .. word }
          or pretty(lines, word, src)
        write_buf(bufnr, out)
        ctx.preview.win:set_title(src)
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

    -- <C-n>: cycle dict.org source, refresh preview
    actions = {
      lexicon_cycle_source = function(picker)
        local src  = lex.cycle_source(lang_key)
        local item = picker.list:current()
        if not item then return end

        picker.preview.win:set_title(src)
        picker.preview:set_lines({ "", "  fetching…" })
        local bufnr = picker.preview.win.buf

        lex.fetch(item.word, src, function(lines)
          local out = #lines == 0
            and { "", "  no definition found: " .. item.word }
            or pretty(lines, item.word, src)
          write_buf(bufnr, out)
          picker.preview.win:set_title(src)
        end)
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
for key in pairs(lex.config.languages) do
  local k = key
  M[k] = function(o) M.open(k, o) end
end

return M
