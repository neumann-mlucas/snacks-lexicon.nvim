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

--- Fetch a definition via the DICT protocol.
-- @param server     string  hostname or IP
-- @param port       number  usually 2628
-- @param database   string  e.g. "wn", "moby-thesaurus"
-- @param word       string  word to look up (CRLF stripped for safety)
-- @param timeout_ms number  milliseconds before giving up
-- @param on_lines   fun(lines: string[])  called on vim main thread
-- @return { cancel = fun() }  aborts in-flight request without invoking on_lines
function M.define(server, port, database, word, timeout_ms, on_lines)
  -- Strip CRLF; RFC quoting handles everything else
  word = tostring(word or ""):gsub("[\r\n]", "")
  database = tostring(database or ""):gsub("[\r\n]", "")

  local buf, done = "", false
  local client, timer

  local function safe_close(handle)
    if handle and not handle:is_closing() then
      pcall(handle.close, handle)
    end
  end

  local function cleanup()
    safe_close(timer)
    if client then
      pcall(client.read_stop, client)
      safe_close(client)
      client = nil
    end
  end

  local function finish(lines)
    if done then return end
    done = true
    cleanup()
    vim.schedule(function() on_lines(lines or parse(buf)) end)
  end

  local function cancel()
    if done then return end
    done = true      -- prevent finish() from firing on_lines
    cleanup()
  end

  timer = uv.new_timer()
  timer:start(timeout_ms, 0, function() finish({}) end)

  -- Resolve host without pinning to IPv4 so IPv6-only networks still work
  uv.getaddrinfo(server, tostring(port), { socktype = "stream" }, function(err, res)
    if err or not res or not res[1] then
      finish({})
      return
    end

    -- Try each returned address in order; fall through on connect failure
    local function try(i)
      if done or i > #res then finish({}) return end
      local addr = res[i]

      client = uv.new_tcp(addr.family == "inet6" and "inet6" or "inet")
      client:connect(addr.addr, port, function(cerr)
        if cerr then
          if client then safe_close(client); client = nil end
          try(i + 1)
          return
        end

        local cmd = ("CLIENT nvim-lexicon\r\nDEFINE %s %s\r\nQUIT\r\n"):format(
          dict_quote(database), dict_quote(word))
        client:write(cmd, function(werr)
          if werr then finish({}) end
        end)

        client:read_start(function(rerr, data)
          if rerr or not data then finish() return end
          buf = buf .. data
          if response_complete(buf) then finish() end
        end)
      end)
    end

    try(1)
  end)

  return { cancel = cancel }
end

return M
