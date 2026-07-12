# snacks-lexicon.nvim

Dictionary and thesaurus lookup via [dict.org](https://dict.org) DICT protocol, powered by [snacks.picker](https://github.com/folke/snacks.nvim).

**This is a vibe-coded project and is still experimental. Use it at your own discretion.**

- Fuzzy search over your system word list (`/usr/share/dict/words`)
- Live definition preview fetched asynchronously from dict.org
- Cycle through multiple dictionary sources (`wn`, `moby-thesaurus`, `gcide`, …)
- Multi-language support (English, Português, Deutsch, Español, Français)
- No shell dependencies — uses `vim.uv` TCP directly

## Requirements

- Neovim 0.9+ (uses `vim.uv`)
- [snacks.nvim](https://github.com/folke/snacks.nvim) with `picker` enabled
- System word list (e.g. `/usr/share/dict/words`) for the word finder
- Internet access to dict.org

## Installation

```lua
-- lazy.nvim
{
  "neumann-mlucas/snacks-lexicon.nvim",
  lazy = true,
  keys = {
    { "<leader>ww", function() require("lexicon.picker").open() end,                                    desc = "Lexicon (default lang)" },
    { "<leader>we", function() require("lexicon.picker").en() end,                                      desc = "Dict: English" },
    { "<leader>wt", function() require("lexicon.picker").en({ default_source = "moby-thesaurus" }) end, desc = "Dict: Thesaurus" },
    { "<leader>wp", function() require("lexicon.picker").pt() end,                                      desc = "Dict: Português" },
    { "<leader>wd", function() require("lexicon.picker").de() end,                                      desc = "Dict: Deutsch" },
  },
  opts = {
    server       = "dict.org",
    port         = 2628,
    timeout_ms   = 3000,
    default_lang = "en",
  },
  config = function(_, opts)
    require("lexicon").setup(opts)
  end,
}
```

## Keybindings

| Key     | Action                                    |
|---------|-------------------------------------------|
| `<C-n>` | Cycle to next dictionary source           |
| `<CR>`  | Insert selected word at cursor position   |
| `<Esc>` | Close picker                              |

Source cycle order (English): `wn → moby-thesaurus → gcide → foldoc → jargon → …`

## Configuration

```lua
require("lexicon").setup({
  server     = "dict.org",  -- any DICT-compatible server
  port       = 2628,
  timeout_ms = 3000,
  default_lang = "en",

  -- Override or extend any language profile
  languages = {
    en = {
      label      = "English",
      sources    = { "wn", "moby-thesaurus", "gcide", "foldoc", "jargon" },
      word_files = { "/usr/share/dict/words", "/usr/dict/words" },
    },
    pt = {
      label      = "Português",
      sources    = { "fd-por-eng", "fd-eng-por" },
      word_files = { "/usr/share/dict/portuguese", "/usr/share/dict/words" },
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
    -- add custom languages or sources
    ja = {
      label      = "日本語",
      sources    = { "fd-jpn-eng" },
      word_files = { "/usr/share/dict/japanese" },
    },
  },
})
```

Each language picker is auto-exported:

```lua
require("lexicon.picker").en(opts)   -- English
require("lexicon.picker").pt(opts)   -- Português
require("lexicon.picker").de(opts)   -- Deutsch
-- one per key in languages table
```

Pass `default_source` to open at a specific source:

```lua
require("lexicon.picker").en({ default_source = "moby-thesaurus" })
```

## Architecture

```
lua/lexicon/
├── protocol.lua   DICT protocol client over raw TCP (vim.uv)
├── init.lua       Config, language profiles, source cycle state, fetch()
└── picker.lua     snacks.picker integration: word list, preview, keymaps
```

**`protocol.lua`** — resolves hostname via `uv.getaddrinfo`, opens a TCP connection, sends `DEFINE <database> <word>`, parses RFC 2229 response codes, calls `on_lines` on the vim main thread.

**`init.lua`** — holds the merged config and `_state.source_idx`. `M.fetch(word, db, cb)` delegates to `protocol.define`. `M.cycle_source()` advances the index mod len.

**`picker.lua`** — reads the word list file into `items[]`, passes them to `Snacks.picker.pick`. The `preview` function fires for each selected word and starts an async fetch; the result is written into the captured preview buffer. `<C-n>` calls `cycle_source` then re-fetches for the current item.

## dict.org Sources

Common sources available on dict.org:

| Source          | Content                        |
|-----------------|--------------------------------|
| `wn`            | WordNet 3.1                    |
| `moby-thesaurus`| Moby Thesaurus                 |
| `gcide`         | Collaborative Int'l Dictionary |
| `foldoc`        | Free On-line Dict of Computing |
| `jargon`        | Jargon File                    |
| `fd-eng-por`    | English → Português            |
| `fd-eng-deu`    | English → Deutsch              |
| `fd-eng-spa`    | English → Español              |
| `fd-eng-fra`    | English → Français             |
| `fd-por-eng`    | Português → English            |
| `fd-deu-eng`    | Deutsch → English              |

Full list: `telnet dict.org 2628` then `SHOW DB`.
