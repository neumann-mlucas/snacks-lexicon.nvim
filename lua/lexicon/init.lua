local M = {}

local LANG_DEFAULTS = {
  en = {
    label      = "English",
    sources    = { "wn", "moby-thesaurus", "gcide", "foldoc", "jargon" },
    word_files = {
      "/usr/share/dict/words",  -- Linux
      "/usr/dict/words",        -- older BSD/macOS
    },
  },
  pt = {
    label      = "Português",
    sources    = { "fd-por-eng", "fd-eng-por" },
    word_files = {
      "/usr/share/dict/portuguese",
      "/usr/share/dict/pt_PT",
      "/usr/share/dict/words",
    },
  },
  de = {
    label      = "Deutsch",
    sources    = { "fd-deu-eng", "fd-eng-deu" },
    word_files = { "/usr/share/dict/german", "/usr/share/dict/ngerman" },
  },
  es = {
    label      = "Español",
    sources    = { "fd-spa-eng", "fd-eng-spa" },
    word_files = { "/usr/share/dict/spanish" },
  },
  fr = {
    label      = "Français",
    sources    = { "fd-fra-eng", "fd-eng-fra" },
    word_files = { "/usr/share/dict/french" },
  },
}

M.config = {
  server       = "dict.org",
  port         = 2628,
  timeout_ms   = 3000,       -- per-request budget (define/match/all)
  default_lang = "en",
  languages    = LANG_DEFAULTS,
  parallel     = false,      -- true → preview fetches all sources at once
  suggest      = true,       -- true → MATCH ... on empty define result
  provider     = "dict.org", -- "dict.org" (TCP) | "cli" (dict binary, works offline)
}

-- Per-language cursor into cfg.sources so switching languages does not
-- clobber the source another language is on.
M._state = { source_idx_by_lang = {} }

local function idx_for(lang_key)
  local lk = lang_key or M.config.default_lang
  return M._state.source_idx_by_lang[lk] or 1
end

local function set_idx(lang_key, i)
  local lk = lang_key or M.config.default_lang
  M._state.source_idx_by_lang[lk] = i
end

--- Merge user config. Call once from plugin setup.
-- @param opts table  keys: server, port, timeout_ms, default_lang, languages
function M.setup(opts)
  opts = opts or {}

  -- Copy so we don't mutate caller's table
  local base_opts = vim.deepcopy(opts)
  local lang_overrides = base_opts.languages
  base_opts.languages = nil

  M.config = vim.tbl_deep_extend("force", M.config, base_opts)

  if lang_overrides then
    for key, override in pairs(lang_overrides) do
      local base = M.config.languages[key] or {}
      M.config.languages[key] = vim.tbl_deep_extend("force", base, override)
    end
  end

  M._state.source_idx_by_lang = {}

  -- Any old cached results were built with previous settings (provider,
  -- server). Wipe so setup() reliably applies.
  local ok, cache = pcall(require, "lexicon.cache")
  if ok then cache.clear() end
end

--- Return language config table for lang_key (falls back to default_lang).
function M.lang_cfg(lang_key)
  return M.config.languages[lang_key or M.config.default_lang]
      or M.config.languages[M.config.default_lang]
end

--- Current active dict.org source for lang_key.
function M.current_source(lang_key)
  local cfg = M.lang_cfg(lang_key)
  return cfg.sources[idx_for(lang_key)] or cfg.sources[1]
end

--- Advance to next source in the cycle; returns new source name.
function M.cycle_source(lang_key)
  local n = #M.lang_cfg(lang_key).sources
  set_idx(lang_key, (idx_for(lang_key) % n) + 1)
  return M.current_source(lang_key)
end

--- Step to previous source; returns new source name.
function M.cycle_source_prev(lang_key)
  local n = #M.lang_cfg(lang_key).sources
  set_idx(lang_key, ((idx_for(lang_key) - 2) % n) + 1)
  return M.current_source(lang_key)
end

--- Try to set the current source by exact name; returns true if found.
function M.set_source(lang_key, name)
  local sources = M.lang_cfg(lang_key).sources
  for i, s in ipairs(sources) do
    if s == name then
      set_idx(lang_key, i)
      return true
    end
  end
  return false
end

--- First readable word-list file for lang_key, or nil.
function M.words_file(lang_key)
  for _, p in ipairs(M.lang_cfg(lang_key).word_files or {}) do
    local expanded = vim.fn.expand(p)
    if vim.fn.filereadable(expanded) == 1 then
      return expanded
    end
  end
end

-- Pick the transport implementation based on `config.provider`.
-- Falls back to network if CLI selected but `dict` is not on PATH.
local function provider()
  if M.config.provider == "cli" then
    local cli = require("lexicon.cli")
    if cli.available() then return cli end
    vim.notify("lexicon: config.provider='cli' but `dict` not found; falling back to network",
      vim.log.levels.WARN)
  end
  return require("lexicon.protocol")
end

--- Async definition fetch; on_lines called on vim main thread.
-- Callback signature: on_lines(lines: string[], ok: boolean).
-- `ok=true` means we got a valid reply (may be empty). `ok=false` means the
-- request failed (timeout / network / spawn error) and callers should not
-- cache the result.
-- @return { cancel = fun() }
function M.fetch(word, database, on_lines)
  return provider().define(
    M.config.server, M.config.port,
    database, word, M.config.timeout_ms, on_lines
  )
end

--- Async MATCH — fuzzy-list candidate words in a database.
-- Callback: on_matches(words: string[], ok: boolean).
-- @return { cancel = fun() }
function M.match(word, database, on_matches)
  return provider().match(
    M.config.server, M.config.port,
    database, word, M.config.timeout_ms, on_matches
  )
end

--- Fetch a word from every source configured for lang_key concurrently.
-- Calls on_result with an ordered array `{ { src = "wn", lines = {...} }, ... }`
-- when the last source completes. Empty results are included so callers can
-- render a "no definition" marker for each source.
-- @return { cancel = fun() }
function M.fetch_all(word, lang_key, on_result)
  local cfg      = M.lang_cfg(lang_key)
  local sources  = cfg.sources
  local results  = {}
  local pending  = #sources
  local handles  = {}
  local canceled = false
  local all_ok   = true

  for i, src in ipairs(sources) do
    handles[i] = M.fetch(word, src, function(lines, ok)
      if canceled then return end
      results[i] = { src = src, lines = lines, ok = ok }
      if not ok then all_ok = false end
      pending = pending - 1
      if pending == 0 then on_result(results, all_ok) end
    end)
  end

  return {
    cancel = function()
      canceled = true
      for _, h in ipairs(handles) do pcall(function() h.cancel() end) end
    end,
  }
end

return M
