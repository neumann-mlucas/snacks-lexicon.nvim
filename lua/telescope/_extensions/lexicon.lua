local telescope    = require("telescope")
local pickers      = require("telescope.pickers")
local finders      = require("telescope.finders")
local previewers   = require("telescope.previewers")
local actions      = require("telescope.actions")
local action_state = require("telescope.actions.state")
local conf         = require("telescope.config").values

local lex = require("telescope-lexicon")

-- stream words file line by line; works on Linux/macOS/WSL
-- on Windows: "cmd /c type <path>" reads the same file
local function cat_cmd(path)
  if vim.fn.has("win32") == 1 then
    return { "cmd", "/c", "type", path }
  end
  return { "cat", path }
end

local function make_previewer(lang_key)
  return previewers.new_buffer_previewer({
    define_preview = function(self, entry, _)
      local word  = entry.value
      local src   = lex.current_source(lang_key)
      local bufnr = self.state.bufnr
      local label = lex.lang_cfg(lang_key).label

      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
        { ("[%s | %s]  fetching %q …"):format(label, src, word) })

      lex.fetch(word, src, function(lines)
        if #lines == 0 then
          lines = { "no definition found for: " .. word }
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = ("── %s  [%s] ──"):format(src, label)

        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        end
      end)
    end,
  })
end

local function make_picker(lang_key, opts)
  opts = opts or {}
  lang_key = lang_key or lex.config.default_lang

  local wf = lex.words_file(lang_key)
  if not wf then
    vim.notify(
      ("telescope-lexicon [%s]: no word file found.\n"
        .. "Set languages.%s.word_files in telescope setup."):format(lang_key, lang_key),
      vim.log.levels.WARN
    )
    return
  end

  opts.default_text = opts.default_text or vim.fn.expand("<cword>")

  -- reset source cycle when opening a new picker
  lex._state.source_idx = 1

  pickers.new(opts, {
    prompt_title = ("Lexicon  [%s | %s]"):format(
      lex.lang_cfg(lang_key).label,
      lex.current_source(lang_key)
    ),

    previewer = make_previewer(lang_key),

    finder = finders.new_oneshot_job(cat_cmd(wf), {
      entry_maker = function(w)
        if not w or w == "" then return nil end
        return { value = w, display = w, ordinal = w }
      end,
    }),

    sorter = conf.generic_sorter(opts),

    attach_mappings = function(prompt_bufnr, map)
      -- <C-n> cycles dict.org source and refreshes preview
      local function cycle_and_refresh()
        local src    = lex.cycle_source(lang_key)
        local picker = action_state.get_current_picker(prompt_bufnr)
        local entry  = action_state.get_selected_entry()
        vim.notify(("lexicon source → %s"):format(src), vim.log.levels.INFO)
        if entry and picker.previewer then
          picker.previewer:define_preview(entry, {})
        end
      end

      map("i", "<C-n>", cycle_and_refresh)
      map("n", "<C-n>", cycle_and_refresh)

      -- <CR> inserts selected word at cursor position
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local sel = action_state.get_selected_entry()
        if sel then
          vim.api.nvim_put({ sel.value }, "c", true, true)
        end
      end)

      return true -- keep telescope default mappings
    end,
  }):find()
end

-- Build exports: one entry per configured language + a default "lexicon"
local function build_exports()
  local ex = {}

  -- :Telescope lexicon        → default lang
  ex.lexicon = function(opts) make_picker(nil, opts) end

  -- :Telescope lexicon en / pt / de …
  for key in pairs(lex.config.languages) do
    local k = key -- capture for closure
    ex[k] = function(opts) make_picker(k, opts) end
  end

  return ex
end

return telescope.register_extension({
  setup = function(ext_config, _)
    lex.setup(ext_config)
  end,
  exports = build_exports(),
})
