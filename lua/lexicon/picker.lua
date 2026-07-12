local lex   = require("lexicon")
local cache = require("lexicon.cache")
local uv    = vim.uv or vim.loop
local M     = {}

-- Module-level cache of word lists keyed by absolute file path.
-- Avoids re-reading /usr/share/dict/words (~200k lines, ~100ms) on every open.
local WORD_CACHE = {}

-- Debounce delay before firing a dict.org lookup on preview change.
-- Prevents flooding the server when the user scrolls fast.
local DEBOUNCE_MS = 150

-- Format raw DICT protocol lines into cleaner display lines.
local function pretty(lines, word, src)
  local out = {}
  out[#out + 1] = ("  %s"):format(vim.fn.toupper(word))
  out[#out + 1] = ("  source: %s"):format(src)
  out[#out + 1] = ""

  for _, line in ipairs(lines) do
    if line == "" then
      out[#out + 1] = ""
    elseif line:match("^%s*%d+%.") then
      out[#out + 1] = ""
      out[#out + 1] = line
    else
      out[#out + 1] = line
    end
  end
  return out
end

-- Write lines into a preview buffer; toggles modifiable guard.
local function write_buf(bufnr, lines)
  if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

-- Safely update window title (no-op if window is gone).
local function set_title(win, title)
  pcall(function() win:set_title(title) end)
end

-- Load a word file into snacks picker item format, with case-insensitive
-- ordinal for search matching. Cached per path.
local function load_words(path)
  if WORD_CACHE[path] then return WORD_CACHE[path] end
  local items = {}
  for line in io.lines(path) do
    if line ~= "" then
      items[#items + 1] = {
        text    = line,        -- shown in the list
        word    = line,        -- inserted on <CR>
        ordinal = line:lower(),-- used by matcher for fuzzy filtering
      }
    end
  end
  WORD_CACHE[path] = items
  return items
end

-- Resolve the snacks.picker.pick function. Handles the case where snacks
-- is loaded but the global is not exposed yet.
local function get_pick()
  if _G.Snacks and _G.Snacks.picker then return _G.Snacks.picker.pick end
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks and snacks.picker then return snacks.picker.pick end
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

  local pick = get_pick()
  if not pick then
    vim.notify("snacks-lexicon: snacks.nvim with picker enabled is required", vim.log.levels.ERROR)
    return
  end

  -- Reset source cycle; honour caller's default_source if valid.
  lex._state.source_idx = 1
  if opts.default_source then
    local ok = lex.set_source(lang_key, opts.default_source)
    if not ok then
      vim.notify(
        ("snacks-lexicon: unknown source %q for lang %q"):format(opts.default_source, lang_key),
        vim.log.levels.WARN
      )
    end
    opts.default_source = nil
  end

  local items = load_words(wf)

  -- Per-picker state: request generation counter, debounce timer, active fetch.
  -- gen: incremented on each schedule_fetch call. Stale callbacks (my_gen != gen)
  --   are discarded so fast cursor movement never overwrites a newer preview.
  -- timer: pending debounce timer, cancelled when a new preview starts.
  -- fetch: in-flight protocol handle, cancelled to close TCP early.
  local state = { gen = 0, timer = nil, fetch = nil }

  local function cancel_timer()
    if state.timer and not state.timer:is_closing() then
      pcall(state.timer.stop, state.timer)
      pcall(state.timer.close, state.timer)
    end
    state.timer = nil
  end

  local function cancel_fetch()
    if state.fetch then
      pcall(state.fetch.cancel)
      state.fetch = nil
    end
  end

  -- Fire an async preview fetch after a short debounce.
  local function schedule_fetch(word, src, pwin, bufnr)
    state.gen = state.gen + 1
    local my_gen = state.gen
    cancel_timer()
    cancel_fetch()

    set_title(pwin, src)

    -- Cache hit: render immediately, skip debounce and network entirely.
    local hit = cache.get(word, src)
    if hit then
      write_buf(bufnr, pretty(hit, word, src))
      return
    end

    write_buf(bufnr, { "", "  fetching…" })

    state.timer = uv.new_timer()
    state.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      cancel_timer()
      if state.gen ~= my_gen then return end

      state.fetch = lex.fetch(word, src, function(lines)
        state.fetch = nil
        if state.gen ~= my_gen then return end  -- newer preview took over

        if #lines == 0 then
          write_buf(bufnr, { "", "  no definition found: " .. word })
        else
          cache.set(word, src, lines)
          write_buf(bufnr, pretty(lines, word, src))
        end
        set_title(pwin, src)
      end)
    end))
  end

  -- Lowercase the seed pattern so <cword>="House" matches word list "house"
  -- (snacks smartcase treats mixed-case patterns as case-sensitive).
  local seed = vim.fn.tolower(vim.fn.expand("<cword>") or "")

  pick(vim.tbl_extend("force", {
    source  = "lexicon_" .. lang_key,
    title   = ("Lexicon [%s]"):format(cfg.label),
    pattern = seed,
    format  = "text",
    items   = items,

    layout = {
      layout = {
        box    = "horizontal",
        width  = 0.92,
        height = 0.88,
        border = "rounded",
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

    preview = function(ctx)
      schedule_fetch(
        ctx.item.word,
        lex.current_source(lang_key),
        ctx.preview.win,
        ctx.buf
      )
    end,

    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          vim.api.nvim_put({ item.word }, "c", true, true)
        end)
      end
    end,

    actions = {
      lexicon_cycle_source = function(picker)
        local item = picker.list:current()
        if not item then return end
        schedule_fetch(item.word, lex.cycle_source(lang_key), picker.preview.win, picker.preview.win.buf)
      end,
      lexicon_prev_source = function(picker)
        local item = picker.list:current()
        if not item then return end
        schedule_fetch(item.word, lex.cycle_source_prev(lang_key), picker.preview.win, picker.preview.win.buf)
      end,
    },

    win = {
      input = {
        keys = {
          ["<C-n>"] = { "lexicon_cycle_source", mode = { "i", "n" } },
          ["<C-p>"] = { "lexicon_prev_source",  mode = { "i", "n" } },
        },
      },
    },

    on_close = function()
      cancel_timer()
      cancel_fetch()
    end,
  }, opts))
end

-- Convenience wrappers per language. Resolved lazily via metatable so
-- languages added *after* first require() still work.
return setmetatable(M, {
  __index = function(_, k)
    if type(k) == "string" and lex.config.languages[k] then
      return function(o) M.open(k, o) end
    end
  end,
})
