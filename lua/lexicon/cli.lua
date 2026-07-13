-- CLI provider: shells out to `dict` (dictd client). Works offline against
-- a local dictd server or online if /etc/dict.conf points at a remote host.
-- Same interface as protocol.lua so it's a drop-in for require('lexicon').fetch.
--
-- Exit codes (from dict(1)):
--   0  = ok, definition returned
--   20 = no match
--   21 = approximate matches only
--   other = client / server error
local uv = vim.uv or vim.loop
local M  = {}

local function run(argv, timeout_ms, on_output)
  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)
  local handle, pid
  local buf, done = {}, false

  local function safe_close(h)
    if h and not h:is_closing() then pcall(h.close, h) end
  end

  local function finish(exit_code)
    if done then return end
    done = true
    safe_close(stdout); safe_close(stderr); safe_close(handle)
    vim.schedule(function() on_output(buf, exit_code) end)
  end

  local timer = uv.new_timer()
  timer:start(timeout_ms, 0, function() safe_close(timer); finish(nil) end)

  handle, pid = uv.spawn(argv[1], {
    args   = { unpack(argv, 2) },
    stdio  = { nil, stdout, stderr },
  }, function(code)
    safe_close(timer)
    finish(code)
  end)

  if not handle then
    safe_close(timer); safe_close(stdout); safe_close(stderr)
    vim.schedule(function() on_output({}, -1) end)
    return { cancel = function() end }
  end

  stdout:read_start(function(err, data)
    if err or not data then return end
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
      if line ~= "" then buf[#buf + 1] = (line:gsub("\r$", "")) end
    end
  end)
  stderr:read_start(function() end)  -- discard

  return {
    cancel = function()
      if done then return end
      done = true
      safe_close(timer)
      if handle and not handle:is_closing() then pcall(uv.process_kill, handle, "sigterm") end
      safe_close(stdout); safe_close(stderr); safe_close(handle)
    end,
  }
end

--- dict -d <db> <word>    (no formatting flags — parse output ourselves)
function M.define(_server, _port, database, word, timeout_ms, on_lines)
  word     = tostring(word or ""):gsub("[\r\n]", "")
  database = tostring(database or ""):gsub("[\r\n]", "")

  return run({ "dict", "-d", database, word }, timeout_ms, function(lines, code)
    -- code 20 = no match; still a valid (empty) reply from the tool.
    if code == 0 then
      -- Strip the leading "From <db>" header and empty trailing lines
      local out = {}
      for _, l in ipairs(lines) do
        if not l:match("^From [%w_%-]+%s*%[") then out[#out + 1] = l end
      end
      while #out > 0 and out[#out] == "" do out[#out] = nil end
      on_lines(out, true)
    elseif code == 20 or code == 21 then
      on_lines({}, true)   -- authoritative no match
    else
      on_lines({}, false)  -- error, don't cache
    end
  end)
end

--- dict -d <db> -m <word>  → prints "  <db> "word"" per match
function M.match(_server, _port, database, word, timeout_ms, on_matches)
  word     = tostring(word or ""):gsub("[\r\n]", "")
  database = tostring(database or ""):gsub("[\r\n]", "")

  return run({ "dict", "-d", database, "-m", word }, timeout_ms, function(lines, code)
    if code ~= 0 and code ~= 20 and code ~= 21 then
      on_matches({}, false); return
    end
    local out = {}
    for _, l in ipairs(lines) do
      local w = l:match('%s*%S+%s+"(.-)"') or l:match("%s*%S+%s+(%S+)")
      if w then out[#out + 1] = w end
    end
    on_matches(out, true)
  end)
end

function M.available()
  return vim.fn.executable("dict") == 1
end

return M
