if vim.g.loaded_lexicon then return end
vim.g.loaded_lexicon = true

-- :Lexicon           → open picker for the default language
-- :Lexicon en        → English
-- :Lexicon pt / de   → other configured language
vim.api.nvim_create_user_command("Lexicon", function(args)
  local lang = args.args ~= "" and args.args or nil
  require("lexicon.picker").open(lang)
end, {
  nargs = "?",
  complete = function(prefix)
    local ok, lex = pcall(require, "lexicon")
    if not ok then return {} end
    local out = {}
    for key in pairs(lex.config.languages) do
      if key:find("^" .. vim.pesc(prefix)) then
        out[#out + 1] = key
      end
    end
    table.sort(out)
    return out
  end,
  desc = "Open the Lexicon dictionary picker",
})
