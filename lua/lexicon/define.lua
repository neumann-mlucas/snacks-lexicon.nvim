-- Direct definition popup — bypass the picker entirely.
-- Fetches the current source for the language and shows the result in a
-- floating window. Press `q` or `<Esc>` to close.
local lex = require("lexicon")
local cache = require("lexicon.cache")

local M = {}

local function write(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Open a floating window and fetch a definition for `word`.
-- @param word     string  word to look up
-- @param lang_key string|nil  language, defaults to config.default_lang
-- @param source   string|nil  specific source, defaults to current
function M.show(word, lang_key, source)
  if not word or word == "" then
    vim.notify("LexiconDefine: word required", vim.log.levels.WARN)
    return
  end
  lang_key = lang_key or lex.config.default_lang
  source = source or lex.current_source(lang_key)

  local width = math.min(100, math.floor(vim.o.columns * 0.7))
  local height = math.min(30, math.floor(vim.o.lines * 0.6))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    title = (" Lexicon: %s [%s] "):format(word, source),
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true })
  vim.keymap.set("n", "<esc>", "<cmd>close<cr>", { buffer = buf, silent = true })

  write(buf, { "  fetching…" })

  local function render(lines)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if #lines == 0 then
      write(buf, { "  no definition found for '" .. word .. "' in " .. source })
    else
      write(buf, lines)
    end
  end

  local hit = cache.get(word, source)
  if hit then
    render(hit)
    return
  end

  lex.fetch(word, source, function(lines, ok)
    if ok then
      cache.set(word, source, lines)
    end
    if ok then
      render(lines)
    else
      write(buf, { "  fetch failed (timeout or network error). Try again or raise timeout_ms." })
    end
  end)
end

return M
