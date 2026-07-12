local M = {}

local LANG_DEFAULTS = {
  en = {
    label      = "English",
    sources    = { "wn", "moby-thesaurus", "gcide", "foldoc", "jargon" },
    word_files = {
      "/usr/share/dict/words",   -- Linux / macOS
      "/usr/dict/words",
      "C:/tools/dict/words.txt", -- Windows (user-supplied)
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
  timeout_ms   = 3000,
  default_lang = "en",
  languages    = LANG_DEFAULTS,
}

M._state = { source_idx = 1 }

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

  M._state.source_idx = 1
end

--- Return language config table for lang_key (falls back to default_lang).
function M.lang_cfg(lang_key)
  return M.config.languages[lang_key or M.config.default_lang]
      or M.config.languages[M.config.default_lang]
end

--- Current active dict.org source for lang_key.
function M.current_source(lang_key)
  local cfg = M.lang_cfg(lang_key)
  return cfg.sources[M._state.source_idx] or cfg.sources[1]
end

--- Advance to next source in the cycle; returns new source name.
function M.cycle_source(lang_key)
  local n = #M.lang_cfg(lang_key).sources
  M._state.source_idx = (M._state.source_idx % n) + 1
  return M.current_source(lang_key)
end

--- Step to previous source; returns new source name.
function M.cycle_source_prev(lang_key)
  local n = #M.lang_cfg(lang_key).sources
  M._state.source_idx = ((M._state.source_idx - 2) % n) + 1
  return M.current_source(lang_key)
end

--- Try to set the current source by exact name; returns true if found.
function M.set_source(lang_key, name)
  local sources = M.lang_cfg(lang_key).sources
  for i, s in ipairs(sources) do
    if s == name then
      M._state.source_idx = i
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

--- Async definition fetch; on_lines called on vim main thread.
function M.fetch(word, database, on_lines)
  local proto = require("lexicon.protocol")
  proto.define(
    M.config.server,
    M.config.port,
    database,
    word,
    M.config.timeout_ms,
    on_lines
  )
end

return M
