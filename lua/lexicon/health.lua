local M = {}

local function has_snacks_picker()
  if _G.Snacks and _G.Snacks.picker and type(_G.Snacks.picker.pick) == "function" then
    return true
  end
  local ok, snacks = pcall(require, "snacks")
  return ok and snacks and snacks.picker and type(snacks.picker.pick) == "function"
end

local function dns_ok(host, timeout_ms)
  local uv = vim.uv or vim.loop
  local result
  uv.getaddrinfo(host, nil, { socktype = "stream" }, function(err, res)
    result = { err = err, res = res }
  end)
  vim.wait(timeout_ms or 2000, function()
    return result ~= nil
  end, 50)
  return result and result.res and result.res[1], result and result.err
end

function M.check()
  vim.health.start("snacks-lexicon: dependencies")
  if has_snacks_picker() then
    vim.health.ok("snacks.nvim with picker enabled")
  else
    vim.health.error("snacks.nvim with `picker = { enabled = true }` is required")
  end

  if vim.uv or vim.loop then
    vim.health.ok("vim.uv available")
  else
    vim.health.error("vim.uv missing — needs Neovim 0.9+")
  end

  local lex = require("lexicon")

  vim.health.start("snacks-lexicon: word files")
  for key, cfg in pairs(lex.config.languages) do
    local wf = lex.words_file(key)
    if wf then
      vim.health.ok(("%s (%s) → %s"):format(key, cfg.label, wf))
    else
      local paths = table.concat(cfg.word_files or {}, ", ")
      vim.health.warn(
        ("%s (%s): no readable word file"):format(key, cfg.label),
        { "Tried: " .. paths, "Install a system dict package or override `languages." .. key .. ".word_files`" }
      )
    end
  end

  vim.health.start("snacks-lexicon: provider")
  vim.health.info(("provider: %s"):format(lex.config.provider))
  vim.health.info(("timeout_ms: %d"):format(lex.config.timeout_ms))
  if lex.config.provider == "cli" then
    if require("lexicon.cli").available() then
      vim.health.ok("`dict` binary found on PATH")
    else
      vim.health.error(
        "config.provider='cli' but `dict` not installed",
        { "Install `dictd`/`dict` (Debian/Ubuntu) or `dict-client` (Arch)" }
      )
    end
  end

  vim.health.start("snacks-lexicon: server")
  local host = lex.config.server
  local ok, err = dns_ok(host, 2000)
  if ok then
    vim.health.ok(("DNS resolves %s"):format(host))
  else
    vim.health.error(("Cannot resolve %s"):format(host), {
      err and tostring(err) or "getaddrinfo returned no addresses",
      "Check network connectivity and the `server` config option",
    })
  end
  vim.health.info(("Port: %d, timeout: %dms"):format(lex.config.port, lex.config.timeout_ms))
end

return M
