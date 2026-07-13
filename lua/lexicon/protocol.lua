-- DICT protocol client (RFC 2229) over raw TCP via vim.uv
-- No external dependencies (curl, sed, tr, etc.)
local uv = vim.uv or vim.loop
local M  = {}

-- Parse RFC 2229 response. Each definition arrives between:
--   151 <word> <db> "<name>"     ← definition start
--   ...body lines...
--   .                            ← end of definition
--   250 ok                       ← reply complete
-- Non-status lines outside 151..250 are ignored.
local function parse(raw)
  local out, in_def = {}, false

  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local code = line:match("^(%d%d%d)[ \r]") or line:match("^(%d%d%d)$")

    if code then
      if code == "151" then
        in_def = true
      elseif code == "250" then
        if #out > 0 and out[#out] ~= "" then out[#out + 1] = "" end
        in_def = false
      end
    elseif line == "." then
      in_def = false
    elseif in_def then
      out[#out + 1] = line
    end
  end

  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return out
end

-- Detect complete response by looking for "221" status at the start of a line
-- ("221 goodbye" is sent by the server after our QUIT).
local function response_complete(buf)
  return buf:find("\n221[ \r]") ~= nil or buf:find("^221[ \r]") ~= nil
end

-- Quote a DICT protocol atom per RFC 2229: wrap in `"`, backslash-escape
-- interior `\` and `"`. Necessary for words with spaces, apostrophes, etc.
local function dict_quote(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- Extract matches from a MATCH response body. Each line is `<db> "<word>"`
-- (or unquoted); we only keep the word.
local function parse_matches(raw)
  local out, in_matches = {}, false
  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local code = line:match("^(%d%d%d)[ \r]") or line:match("^(%d%d%d)$")
    if code then
      if code == "152" then in_matches = true
      elseif code == "250" or code == "550" or code == "552" then in_matches = false
      end
    elseif line == "." then
      in_matches = false
    elseif in_matches then
      local w = line:match('%s*%S+%s+"(.-)"') or line:match("%s*%S+%s+(%S+)")
      if w then out[#out + 1] = w end
    end
  end
  return out
end

-- Response is considered "successful" once we've seen any 2xx or 5xx status
-- code from the server. That distinguishes a genuine no-match reply from a
-- network/timeout error so callers can decide whether to cache the result.
local function saw_valid_reply(raw)
  return raw:find("^%d%d%d[ \r]") ~= nil or raw:find("\n%d%d%d[ \r]") ~= nil
end

-- Generic request runner: build a command from `builder(db, word)` and parse
-- the accumulated response with `parser`. Callback receives (result, ok).
local function run_request(server, port, database, word, timeout_ms, on_result, builder, parser)
  word     = tostring(word or ""):gsub("[\r\n]", "")
  database = tostring(database or ""):gsub("[\r\n]", "")

  local buf, done = "", false
  local client, timer

  local function safe_close(handle)
    if handle and not handle:is_closing() then pcall(handle.close, handle) end
  end
  local function cleanup()
    safe_close(timer)
    if client then
      pcall(client.read_stop, client)
      safe_close(client)
      client = nil
    end
  end
  local function finish(explicit_ok)
    if done then return end
    done = true
    cleanup()
    local ok = explicit_ok
    if ok == nil then ok = saw_valid_reply(buf) end
    vim.schedule(function() on_result(parser(buf), ok) end)
  end
  local function cancel()
    if done then return end
    done = true
    cleanup()
  end

  timer = uv.new_timer()
  timer:start(timeout_ms, 0, function() finish(false) end)  -- timeout → not ok

  uv.getaddrinfo(server, tostring(port), { socktype = "stream" }, function(err, res)
    if err or not res or not res[1] then finish(false) return end

    local function try(i)
      if done or i > #res then finish(false) return end
      local addr = res[i]
      client = uv.new_tcp(addr.family == "inet6" and "inet6" or "inet")
      client:connect(addr.addr, port, function(cerr)
        if cerr then
          if client then safe_close(client); client = nil end
          try(i + 1)
          return
        end
        client:write(builder(dict_quote(database), dict_quote(word)), function(werr)
          if werr then finish(false) end
        end)
        client:read_start(function(rerr, data)
          if rerr or not data then finish() return end
          buf = buf .. data
          if buf:find("\n221[ \r]") or buf:find("^221[ \r]") then finish() end
        end)
      end)
    end
    try(1)
  end)

  return { cancel = cancel }
end

--- Fetch a definition via the DICT protocol.
-- @return { cancel = fun() }
function M.define(server, port, database, word, timeout_ms, on_lines)
  return run_request(server, port, database, word, timeout_ms, on_lines,
    function(db, w)
      return ("CLIENT nvim-lexicon\r\nDEFINE %s %s\r\nQUIT\r\n"):format(db, w)
    end,
    parse)
end

--- Fuzzy match a word against a database. Uses the "." strategy which lets
--- the server pick a reasonable default (lev/soundex depending on the db).
--- @return { cancel = fun() }
function M.match(server, port, database, word, timeout_ms, on_matches)
  return run_request(server, port, database, word, timeout_ms, on_matches,
    function(db, w)
      return ("CLIENT nvim-lexicon\r\nMATCH %s . %s\r\nQUIT\r\n"):format(db, w)
    end,
    parse_matches)
end

return M
