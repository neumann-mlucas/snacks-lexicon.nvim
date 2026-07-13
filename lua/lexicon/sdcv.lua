-- StarDict provider: shells out to `sdcv` (StarDict Console Version).
-- Reads local StarDict .ifo/.idx/.dict files under ~/.stardict/dic/ or
-- /usr/share/stardict/dic/. Same {define, match, available} shape as
-- protocol.lua and cli.lua so init.lua can hot-swap providers.
--
-- Reference:
--   sdcv -n -j -u <dict> <word>     JSON-formatted definition
--   sdcv -0 <word>                  match list (no definitions)
--   sdcv -l                         list installed dictionaries
local uv = vim.uv or vim.loop
local M  = {}

local function run(argv, timeout_ms, on_output)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local handle
  local buf_out, buf_err, done = {}, {}, false

  local function safe_close(h)
    if h and not h:is_closing() then pcall(h.close, h) end
  end

  local function finish(exit_code)
    if done then return end
    done = true
    safe_close(stdout); safe_close(stderr); safe_close(handle)
    vim.schedule(function()
      on_output(buf_out, buf_err, exit_code)
    end)
  end

  local timer = uv.new_timer()
  timer:start(timeout_ms, 0, function()
    safe_close(timer)
    finish(nil)
  end)

  handle = uv.spawn(argv[1], {
    args  = { unpack(argv, 2) },
    stdio = { nil, stdout, stderr },
  }, function(code)
    safe_close(timer)
    finish(code)
  end)

  if not handle then
    safe_close(timer); safe_close(stdout); safe_close(stderr)
    vim.schedule(function() on_output({}, {}, -1) end)
    return { cancel = function() end }
  end

  stdout:read_start(function(err, data)
    if err or not data then return end
    buf_out[#buf_out + 1] = data
  end)
  stderr:read_start(function(err, data)
    if err or not data then return end
    buf_err[#buf_err + 1] = data
  end)

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

-- Strip a small set of HTML entities/tags that some StarDict dicts embed
-- in their definition bodies.
local function html_clean(s)
  s = s:gsub("<[^>]+>", "")
  s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'")
  return s
end

-- Split a possibly-multiline string into an array of lines with trimming.
local function split_lines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line:gsub("\r$", "")
  end
  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return out
end

--- Lookup a definition via sdcv.
-- @return { cancel = fun() }
function M.define(_server, _port, database, word, timeout_ms, on_lines)
  word     = tostring(word or ""):gsub("[\r\n]", "")
  database = tostring(database or ""):gsub("[\r\n]", "")

  local argv = { "sdcv", "-n", "-j" }
  if database ~= "" then
    table.insert(argv, "-u")
    table.insert(argv, database)
  end
  table.insert(argv, word)

  return run(argv, timeout_ms, function(out_chunks, err_chunks, code)
    -- Treat spawn error / timeout as network-style failure (don't cache).
    if code == nil or code == -1 then
      on_lines({}, false); return
    end

    local stderr_blob = table.concat(err_chunks)
    -- sdcv prints "Nothing similar to <word>, sorry :(" and returns exit=1
    -- for authoritative no-match. Treat as ok=true, empty result.
    if stderr_blob:find("Nothing similar") then
      on_lines({}, true); return
    end

    local blob = table.concat(out_chunks)
    if blob == "" then
      -- No stdout, exit non-zero, no "Nothing similar" — treat as ok=false
      on_lines({}, code == 0)
      return
    end

    local decoded
    local ok = pcall(function() decoded = vim.json.decode(blob) end)
    if not ok or type(decoded) ~= "table" then
      on_lines({}, false); return
    end

    local lines = {}
    for _, entry in ipairs(decoded) do
      if entry.dict and #lines > 0 then
        lines[#lines + 1] = ""
      end
      if entry.dict then
        lines[#lines + 1] = ("── %s ──"):format(entry.dict)
      end
      for _, l in ipairs(split_lines(html_clean(entry.definition or ""))) do
        lines[#lines + 1] = l
      end
    end
    on_lines(lines, true)
  end)
end

--- List candidate matches via sdcv.
-- @return { cancel = fun() }
function M.match(_server, _port, database, word, timeout_ms, on_matches)
  word     = tostring(word or ""):gsub("[\r\n]", "")
  database = tostring(database or ""):gsub("[\r\n]", "")

  -- `sdcv -0 <word>` prints matching headwords (one per line) then exits.
  -- The `-0` flag is 'output only the exactly matched word'; behaviour
  -- varies slightly across versions but is the closest analogue to
  -- DICT's MATCH command.
  local argv = { "sdcv", "-n", "-j", "-0" }
  if database ~= "" then
    table.insert(argv, "-u")
    table.insert(argv, database)
  end
  table.insert(argv, word)

  return run(argv, timeout_ms, function(out_chunks, _, code)
    if code == nil or code == -1 then on_matches({}, false); return end
    local blob = table.concat(out_chunks)
    if blob == "" then on_matches({}, code == 0); return end

    local decoded, ok = nil, false
    ok = pcall(function() decoded = vim.json.decode(blob) end)
    if not ok or type(decoded) ~= "table" then
      -- Fallback: line-per-match text format
      on_matches(split_lines(blob), true); return
    end

    local words = {}
    for _, entry in ipairs(decoded) do
      if entry.word then words[#words + 1] = entry.word end
    end
    on_matches(words, true)
  end)
end

--- List installed StarDict dictionaries (bookname strings only).
-- Skips the "Dictionary's name  Word count" header and strips the trailing
-- word-count column so the caller receives ready-to-use booknames.
-- @return string[]
function M.list_dicts()
  local blob = vim.fn.system({ "sdcv", "-l" })
  if vim.v.shell_error ~= 0 then return {} end
  local out = {}
  for _, line in ipairs(split_lines(blob)) do
    if not line:match("^Dictionary") and line ~= "" then
      -- Strip trailing whitespace + digits (the word-count column).
      local name = line:gsub("%s+%d+%s*$", "")
      if name ~= "" then out[#out + 1] = name end
    end
  end
  return out
end

function M.available()
  return vim.fn.executable("sdcv") == 1
end

return M
