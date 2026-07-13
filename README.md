# snacks-lexicon.nvim

Dictionary and thesaurus lookup via [dict.org](https://dict.org) DICT protocol, powered by [snacks.picker](https://github.com/folke/snacks.nvim).

**This is a vibe-coded project and is still experimental. Use it at your own discretion.**

- Fuzzy search over your system word list (`/usr/share/dict/words`)
- Live definition preview fetched asynchronously from dict.org
- Cycle through multiple dictionary sources (`wn`, `moby-thesaurus`, `gcide`, …)
- Multi-language support (English, Português, Deutsch, Español, Français)
- Two backends: `dict.org` over TCP (default, zero deps) or the `dict` CLI (offline)
- No shell dependencies for the default backend — uses `vim.uv` TCP directly
- Portable: works on Linux, macOS, and Windows (some backends are POSIX-only)

## Requirements

- Neovim 0.9+ (uses `vim.uv`)
- [snacks.nvim](https://github.com/folke/snacks.nvim) with `picker` enabled
- System word list (e.g. `/usr/share/dict/words`) for the word finder
- Internet access to dict.org

## Word lists

The plugin fuzzy-searches over a plain-text word list, one word per line.
For English on Linux/macOS you already have `/usr/share/dict/words`. For
other languages you need to install or generate one.

### Install from your package manager

```
# Debian / Ubuntu
sudo apt install wamerican-large wportuguese ngerman wspanish wfrench witalian

# Arch
sudo pacman -S words                     # English
# Portuguese / German / etc: use aspell dicts (see below) or AUR

# Fedora
sudo dnf install words

# macOS (via Homebrew)
brew install aspell   # provides multi-language dictionaries
```

The Debian packages install into `/usr/share/dict/*`; the defaults in
`languages.<lang>.word_files` already look there.

### Generate from Aspell or Hunspell

If your OS has no packaged word list for the language you want:

```
# Aspell (works on Linux, macOS, Windows via MSYS2)
aspell -d pt   dump master | aspell -l pt   expand > ~/dict/portuguese.txt
aspell -d de   dump master | aspell -l de   expand > ~/dict/german.txt
aspell -d ja   dump master | aspell -l ja   expand > ~/dict/japanese.txt

# Hunspell alternative (one form per line)
unmunch /usr/share/hunspell/pt_BR.dic /usr/share/hunspell/pt_BR.aff \
  > ~/dict/portuguese.txt
```

Then point the config at the file you generated:

```lua
opts = {
  languages = {
    pt = { word_files = { "~/dict/portuguese.txt", "/usr/share/dict/portuguese" } },
    ja = {
      label      = "日本語",
      sources    = { "fd-jpn-eng" },
      word_files = { "~/dict/japanese.txt" },
    },
  },
}
```

Paths are checked in order; first readable one wins. `~` is expanded.

### Windows

There is no default word list path on Windows. Grab a wordlist (e.g.
[SCOWL](http://wordlist.aspell.net/), Wordnik's public list, or
[dwyl/english-words](https://github.com/dwyl/english-words)) and point
`word_files` at it:

```lua
opts = {
  languages = { en = { word_files = { "C:/tools/dict/words.txt" } } },
}
```

The `provider = "cli"` mode requires the `dict` binary, which is POSIX-only;
Windows users should stay on the default `provider = "dict.org"`.

## Installation

```lua
-- lazy.nvim
{
  "neumann-mlucas/snacks-lexicon.nvim",
  lazy = true,
  keys = {
    { "<leader>ww", function() require("lexicon.picker").open() end, desc = "Lexicon (default lang)" },
    { "<leader>we", function() require("lexicon.picker").en() end, desc = "Dict: English" },
    { "<leader>wt", function() require("lexicon.picker").en({ default_source = "moby-thesaurus" }) end, desc = "Dict: Thesaurus" },
    { "<leader>wp", function() require("lexicon.picker").pt() end, desc = "Dict: Português" },
    { "<leader>wd", function() require("lexicon.picker").de() end, desc = "Dict: Deutsch" },
  },
  opts = {
    provider     = "dict.org",  -- or "cli"
    server       = "dict.org",
    port         = 2628,
    timeout_ms   = 6000,        -- per-request budget in milliseconds
    default_lang = "en",
    parallel     = false,       -- true → preview fetches all sources at once
    suggest      = true,        -- MATCH fallback for empty results
  },
  config = function(_, opts)
    require("lexicon").setup(opts)
  end,
}
```

## Keybindings

| Key     | Action                                  |
| ------- | --------------------------------------- |
| `<C-n>` | Cycle to next dictionary source         |
| `<C-p>` | Cycle to previous dictionary source     |
| `<C-a>` | Toggle parallel (all-sources) preview   |
| `<CR>`  | Insert selected word at cursor position |
| `<Esc>` | Close picker                            |

Source cycle order (English): `wn → moby-thesaurus → gcide → foldoc → jargon → …`

## Commands

| Command                        | Action                                          |
| ------------------------------ | ----------------------------------------------- |
| `:Lexicon`                     | Open picker for the configured default language |
| `:Lexicon <lang>`              | Open picker for `<lang>` (tab-completed)        |
| `:LexiconDefine <word>`        | Floating popup with the definition (no picker)  |
| `:LexiconDefine <word> <lang>` | Same, in a specific language                    |
| `:LexiconCacheClear`           | Wipe the in-memory definition cache             |
| `:checkhealth lexicon`         | Verify deps, provider, word files, DNS          |
| `:help lexicon`                | Full documentation                              |

## Provider

Three backends are supported via `opts.provider`:

- `"dict.org"` (default): native `vim.uv` TCP client to a DICT server. Requires network.
- `"cli"`: shells out to the `dict` binary. Works offline against a local `dictd` server, or online via `/etc/dict.conf`. Falls back to the network provider if `dict` is not on `PATH`.
- `"sdcv"`: shells out to `sdcv` (StarDict Console Version). Fully offline, huge ecosystem of dictionaries at [freemdict.com](https://freemdict.com) and [huzheng.org](http://download.huzheng.org/). Falls back to the network provider if `sdcv` is not on `PATH`.

### StarDict / sdcv

The `sdcv` provider unlocks the StarDict ecosystem — hundreds of dictionaries
including monolingual Oxford/Longman-style, specialised (medical, legal),
and per-language sets that aren't in FreeDict.

**Install:**
```
sudo pacman -S sdcv     # Arch
sudo apt   install sdcv # Debian / Ubuntu
brew        install sdcv # macOS
```

**Get dictionaries:** download `.tar.bz2` bundles from
[freemdict.com](https://freemdict.com) or [huzheng.org](http://download.huzheng.org/dict.php),
extract into `~/.stardict/dic/` (or `/usr/share/stardict/dic/`). Each dict
is a folder containing `.ifo`, `.idx`, `.dict[.dz]` files.

**Discover installed dicts:**
```
sdcv -l
```

**Configure:** use the *bookname* string (from `sdcv -l`, exactly as printed)
in the `sources` list:
```lua
require("lexicon").setup({
  provider = "sdcv",
  languages = {
    en = {
      sources = {
        "Oxford Advanced Learner's Dictionary 8th Edition",
        "Merriam-Webster Collegiate Thesaurus",
      },
    },
  },
})
```

`:checkhealth lexicon` prints the full list of detected booknames so you
can copy them verbatim.

## Configuration

```lua
require("lexicon").setup({
  provider     = "dict.org",  -- "dict.org" (TCP) or "cli" (local dict binary)
  server       = "dict.org",  -- DICT server hostname (network provider only)
  port         = 2628,
  timeout_ms   = 6000,        -- per-request budget (bump to 1500 for local dictd)
  default_lang = "en",
  parallel     = false,       -- true → preview fetches all sources at once
  suggest      = true,        -- MATCH fallback on empty results

  -- Override or extend any language profile.
  -- NOTE on database names: they differ between providers.
  --   • dict.org             → `fd-por-eng`, `fd-eng-por`, `fd-deu-eng` (Debian convention, `fd-` prefix)
  --   • local dictd via freedict tarballs → `por-eng`, `eng-por`, `deu-eng` (no prefix)
  -- Adjust `sources` to match whichever backend you use.
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
plugin/lexicon.lua   :Lexicon, :LexiconDefine, :LexiconCacheClear commands
lua/lexicon/
├── protocol.lua     DICT protocol client over raw TCP (vim.uv)
├── cli.lua          `dict` binary spawn client (offline provider)
├── init.lua         Config, language profiles, per-lang source state, fetch/match/fetch_all
├── cache.lua        Bounded LRU cache for fetched definitions
├── define.lua       :LexiconDefine floating window
├── health.lua       :checkhealth lexicon
└── picker.lua       snacks.picker integration: word list, preview, keymaps
```

**`protocol.lua`** — resolves hostname via `uv.getaddrinfo`, opens a TCP connection, sends `DEFINE <database> <word>`, parses RFC 2229 response codes, calls `on_lines(lines, ok)` on the vim main thread. Returns `{ cancel = fn }` so in-flight requests can be aborted.

**`cli.lua`** — same `define/match` interface but shells out to the `dict` binary via `uv.spawn`. Selected via `config.provider = "cli"`. `dict` reads `/etc/dict/dict.conf` for its own server list, so local dictd is used automatically when configured.

**`init.lua`** — holds merged config, per-language source cursor in `_state.source_idx_by_lang`, and dispatches `M.fetch/M.match/M.fetch_all` to either provider. `M.cycle_source` / `M.cycle_source_prev` / `M.set_source` mutate the cursor.

**`picker.lua`** — reads the word list file into `items[]` (cached per path), passes them to `Snacks.picker.pick`. `preview` debounces then fetches asynchronously; a generation counter drops stale callbacks and `cache.set` is skipped when `ok=false`. `<C-n>`/`<C-p>` cycle sources; `<C-a>` toggles parallel-all mode.

## dict.org Sources

Common sources available on dict.org:

| Source           | Content                        |
| ---------------- | ------------------------------ |
| `wn`             | WordNet 3.1                    |
| `moby-thesaurus` | Moby Thesaurus                 |
| `gcide`          | Collaborative Int'l Dictionary |
| `foldoc`         | Free On-line Dict of Computing |
| `jargon`         | Jargon File                    |
| `fd-eng-por`     | English → Português            |
| `fd-eng-deu`     | English → Deutsch              |
| `fd-eng-spa`     | English → Español              |
| `fd-eng-fra`     | English → Français             |
| `fd-por-eng`     | Português → English            |
| `fd-deu-eng`     | Deutsch → English              |

Full list: `dict -h dict.org -D` (or `telnet dict.org 2628` then `SHOW DB`).
