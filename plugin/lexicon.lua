if vim.g.loaded_lexicon then
  return
end
vim.g.loaded_lexicon = true

-- :Lexicon           → open picker for the default language
-- :Lexicon en        → English
-- :Lexicon pt / de   → other configured language
local function complete_langs(prefix)
  local ok, lex = pcall(require, "lexicon")
  if not ok then
    return {}
  end
  local out = {}
  for key in pairs(lex.config.languages) do
    if key:find("^" .. vim.pesc(prefix)) then
      out[#out + 1] = key
    end
  end
  table.sort(out)
  return out
end

vim.api.nvim_create_user_command("Lexicon", function(args)
  local lang = args.args ~= "" and args.args or nil
  require("lexicon.picker").open(lang)
end, {
  nargs = "?",
  complete = complete_langs,
  desc = "Open the Lexicon dictionary picker",
})

-- :LexiconDefine <word> [lang]  → floating window with the definition.
-- With no arg, uses <cword>.
vim.api.nvim_create_user_command("LexiconDefine", function(args)
  local parts = vim.split(args.args, "%s+", { trimempty = true })
  local word = parts[1]
  if not word or word == "" then
    word = vim.fn.expand("<cword>")
  end
  require("lexicon.define").show(word, parts[2])
end, {
  nargs = "*",
  desc = "Show a definition in a floating window",
})

vim.api.nvim_create_user_command("LexiconCacheClear", function()
  require("lexicon.cache").clear()
  vim.notify("lexicon: definition cache cleared", vim.log.levels.INFO)
end, { desc = "Wipe the in-memory definition cache" })
