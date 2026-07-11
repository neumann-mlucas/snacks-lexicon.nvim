local M = {}

local LANG_DEFAULTS = {
  en = {
    label      = "English",
    sources    = { "wn", "moby-thesaurus", "gcide", "foldoc", "jargon" },
    word_files = {
      "/usr/share/dict/words",  -- Linux / macOS
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
      "/usr/share/dict/words",   -- fallback: English list still usable
    },
  },
  de = {
    label      = "Deutsch",
    sources    = { "fd-deu-eng", "fd-eng-deu" },
    word_files = {
      "/usr/share/dict/german",
      "/usr/share/dict/ngerman",
    },
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

M._state = { lang = "en", source_idx = 1 }

--- Merge user config. Call once from plugin setup.
-- @param opts table  keys: server, port, timeout_ms, default_lang, languages
function M.setup(opts)
  opts = opts or {}

  -- languages are merged per-entry, not deep-replaced wholesale
  local lang_overrides = opts.languages
  opts.languages = nil
  M.config = vim.tbl_deep_extend("force", M.config, opts)

  if lang_overrides then
    for key, override in pairs(lang_overrides) do
      local base = M.config.languages[key] or {}
      M.config.languages[key] = vim.tbl_deep_extend("force", base, override)
    end
  end

  M._state.lang       = M.config.default_lang
  M._state.source_idx = 1
end

--- Return language config table for lang_key (falls back to default_lang).
function M.lang_cfg(lang_key)
  return M.config.languages[lang_key or M._state.lang]
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

--- First readable word-list file for lang_key, or nil.
function M.words_file(lang_key)
  for _, p in ipairs(M.lang_cfg(lang_key).word_files or {}) do
    if vim.fn.filereadable(p) == 1 then return p end
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
