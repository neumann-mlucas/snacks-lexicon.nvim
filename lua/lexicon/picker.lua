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

local NS = vim.api.nvim_create_namespace("snacks_lexicon_hl")

-- Format a single source's raw DICT lines into cleaner display lines.
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

-- Combine multiple {src, lines} results into a single stacked output.
local function pretty_all(results, word)
  local out = {}
  out[#out + 1] = ("  %s"):format(vim.fn.toupper(word))
  out[#out + 1] = ""
  for _, r in ipairs(results) do
    out[#out + 1] = ("── %s ──"):format(r.src)
    out[#out + 1] = ""
    if #r.lines == 0 then
      out[#out + 1] = "  (no definition)"
    else
      for _, line in ipairs(r.lines) do
        if line:match("^%s*%d+%.") then
          out[#out + 1] = ""
          out[#out + 1] = line
        else
          out[#out + 1] = line
        end
      end
    end
    out[#out + 1] = ""
  end
  return out
end

-- Apply extmark highlights to a preview buffer. Called after content is
-- written. Cheap linear scan; buffers are small (a few hundred lines).
local function apply_highlights(preview)
  local buf = preview and preview.win and preview.win.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  local n = vim.api.nvim_buf_line_count(buf)
  for i = 0, n - 1 do
    local line = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or ""

    if i < 2 and line:match("^  %u") then
      vim.api.nvim_buf_add_highlight(buf, NS, "Title", i, 0, -1)
    elseif line:match("^  source:") then
      vim.api.nvim_buf_add_highlight(buf, NS, "Comment", i, 0, -1)
    elseif line:match("^──") then
      vim.api.nvim_buf_add_highlight(buf, NS, "Function", i, 0, -1)
    elseif line:match("^%s*%d+%.") then
      local _, e = line:find("^%s*%d+%.")
      vim.api.nvim_buf_add_highlight(buf, NS, "Number", i, 0, e)
    elseif line:match("^%s+See also") or line:match("^%s+Syn:") or line:match("^%s+Ant:") then
      vim.api.nvim_buf_add_highlight(buf, NS, "Statement", i, 0, -1)
    end
    -- Bracketed cross-refs like {word}
    local s, e = 0, 0
    while true do
      s, e = line:find("{[^}]+}", e + 1)
      if not s then break end
      vim.api.nvim_buf_add_highlight(buf, NS, "Underlined", i, s - 1, e)
    end
    -- Part-of-speech tags: [n], [v], [adj]
    s, e = 0, 0
    while true do
      s, e = line:find("%[%a+%]", e + 1)
      if not s then break end
      vim.api.nvim_buf_add_highlight(buf, NS, "Type", i, s - 1, e)
    end
  end
end

-- Write lines through the snacks preview object.
-- Preview manages its own buffer swaps; using preview:set_lines() ensures
-- we always target the buffer that is currently visible in the window.
local function write_lines(preview, lines)
  if not preview then return end
  local ok = pcall(function() preview:set_lines(lines) end)
  if ok then return end
  -- Fallback: direct buffer write (in case preview API is unavailable)
  local buf = preview.win and preview.win.buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end
end

-- Safely update window title (no-op if window is gone).
local function set_title(win, title)
  pcall(function() win:set_title(title) end)
end

-- Return a lowercased seed from <cword> if it looks like a real word.
-- Rejects symbols/operators such as `->`, `!=` that would produce zero matches.
local function seed_pattern()
  local cword = vim.fn.expand("<cword>") or ""
  if cword:match("^[%w%-]+$") then
    return vim.fn.tolower(cword)
  end
  return ""
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

  -- Honour caller's default_source; otherwise keep last-used per language.
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
  if #items == 0 then
    vim.notify(
      ("snacks-lexicon: word file is empty: %s"):format(wf),
      vim.log.levels.WARN
    )
    return
  end

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

  -- Update the preview window title (the source name) via the snacks title
  -- template system so the change survives layout refreshes.
  local function refresh_titles(picker, src)
    if not picker then return end
    if src and picker.preview then picker.preview.title = src end
    pcall(function() picker:update_titles() end)
  end

  -- Render either the definition, a "no definition" placeholder, or an
  -- explicit fetch-failure message. Suggestions are appended for empty results.
  local function render_one(preview, picker, word, src, lines, ok, suggestions)
    if not ok then
      write_lines(preview, {
        "",
        "  fetch failed (timeout, network, or dict server unreachable)",
        "",
        "  Try again, raise timeout_ms in config, or switch provider.",
      })
    elseif #lines == 0 then
      local buf = { "", "  no definition found: " .. word }
      if suggestions and #suggestions > 0 then
        buf[#buf + 1] = ""
        buf[#buf + 1] = "  did you mean:"
        for _, s in ipairs(suggestions) do
          if #buf < 30 then buf[#buf + 1] = "    - " .. s end
        end
      end
      write_lines(preview, buf)
    else
      write_lines(preview, pretty(lines, word, src))
    end
    refresh_titles(picker, src)
    apply_highlights(preview)
  end

  local function render_all(preview, picker, word, results)
    write_lines(preview, pretty_all(results, word))
    refresh_titles(picker, "all sources")
    apply_highlights(preview)
  end

  -- Fire an async preview fetch after a short debounce.
  local function schedule_fetch(preview, picker, word)
    state.gen = state.gen + 1
    local my_gen = state.gen
    cancel_timer()
    cancel_fetch()

    local src = lex.current_source(lang_key)
    refresh_titles(picker, src)

    -- Parallel mode: fetch every source at once, cache each individually.
    if lex.config.parallel then
      -- Try cache first: only run remote calls for uncached sources.
      local cached_all = {}
      local missing = false
      for _, s in ipairs(cfg.sources) do
        local hit = cache.get(word, s)
        if hit then
          cached_all[#cached_all + 1] = { src = s, lines = hit }
        else
          missing = true
          break
        end
      end
      if not missing and #cached_all == #cfg.sources then
        render_all(preview, picker, word, cached_all)
        return
      end

      write_lines(preview, { "", "  fetching all sources…" })
      state.timer = uv.new_timer()
      state.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        cancel_timer()
        if state.gen ~= my_gen then return end
        state.fetch = lex.fetch_all(word, lang_key, function(results, _all_ok)
          state.fetch = nil
          if state.gen ~= my_gen then return end
          for _, r in ipairs(results) do
            if r.ok then cache.set(word, r.src, r.lines) end
          end
          render_all(preview, picker, word, results)
        end)
      end))
      return
    end

    -- Single-source: cache hit renders immediately.
    local hit = cache.get(word, src)
    if hit then
      render_one(preview, picker, word, src, hit, true, nil)
      return
    end

    write_lines(preview, { "", "  fetching…" })
    state.timer = uv.new_timer()
    state.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      cancel_timer()
      if state.gen ~= my_gen then return end

      state.fetch = lex.fetch(word, src, function(lines, ok)
        state.fetch = nil
        if state.gen ~= my_gen then return end
        if ok then cache.set(word, src, lines) end  -- never cache errors

        -- No result AND ok AND suggestions enabled → fire a MATCH request.
        if ok and #lines == 0 and lex.config.suggest then
          state.fetch = lex.match(word, src, function(matches, _mok)
            state.fetch = nil
            if state.gen ~= my_gen then return end
            render_one(preview, picker, word, src, lines, ok, matches)
          end)
        else
          render_one(preview, picker, word, src, lines, ok, nil)
        end
      end)
    end))
  end

  -- Only these opts may be overridden by callers. Prevents accidents like
  -- passing `items` or `preview` from a user config wiping out core wiring.
  local ALLOWED = { pattern = true, title = true, layout = true, on_close = true }
  local user = {}
  for k, v in pairs(opts) do
    if ALLOWED[k] then user[k] = v end
  end

  pick(vim.tbl_extend("force", {
    source  = "lexicon_" .. lang_key,
    -- `title` is snacks' picker.title, which we don't render anywhere
    -- (each box has its own explicit title below) but keep sensible for
    -- users inspecting `Snacks.picker.get()`.
    title   = "Lexicon",
    pattern = seed_pattern(),
    format  = "text",
    items   = items,

    -- Three-title layout:
    --   • Outer horizontal box   → "Lexicon" (static, plugin identity)
    --   • Inner vertical box     → language label, e.g. " English " (static)
    --   • Preview window          → dict source, e.g. " gcide " (updated on cycle)
    layout = {
      layout = {
        box       = "horizontal",
        width     = 0.92,
        height    = 0.88,
        border    = "rounded",
        title     = " Lexicon ",
        title_pos = "center",
        {
          box       = "vertical",
          border    = true,
          title     = (" %s "):format(cfg.label),
          title_pos = "center",
          { win = "input", height = 1, border = "bottom" },
          { win = "list",  border = "none" },
        },
        {
          win       = "preview",
          border    = true,
          title     = "{preview}",
          title_pos = "center",
          width     = 0.72,
        },
      },
    },

    preview = function(ctx)
      schedule_fetch(ctx.preview, ctx.picker, ctx.item.word)
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
        lex.cycle_source(lang_key)
        schedule_fetch(picker.preview, picker, item.word)
      end,
      lexicon_prev_source = function(picker)
        local item = picker.list:current()
        if not item then return end
        lex.cycle_source_prev(lang_key)
        schedule_fetch(picker.preview, picker, item.word)
      end,
      lexicon_toggle_parallel = function(picker)
        lex.config.parallel = not lex.config.parallel
        local item = picker.list:current()
        if item then schedule_fetch(picker.preview, picker, item.word) end
      end,
    },

    win = {
      input = {
        keys = {
          ["<C-n>"] = { "lexicon_cycle_source",   mode = { "i", "n" } },
          ["<C-p>"] = { "lexicon_prev_source",    mode = { "i", "n" } },
          ["<C-a>"] = { "lexicon_toggle_parallel", mode = { "i", "n" } },
        },
      },
      preview = {
        wo = {
          number         = false,
          relativenumber = false,
          signcolumn     = "no",
          wrap           = true,
          linebreak      = true,
          breakindent    = true,
          list           = false,
          cursorline     = false,
        },
      },
    },

    on_close = function()
      cancel_timer()
      cancel_fetch()
    end,
  }, user))
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
