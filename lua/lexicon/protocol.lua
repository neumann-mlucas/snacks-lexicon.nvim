-- DICT protocol client (RFC 2229) over raw TCP via vim.uv
-- No external dependencies (curl, sed, tr, etc.)
local uv = vim.uv or vim.loop
local M = {}

local function parse(raw)
  local out, in_def = {}, false

  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local code = line:match("^(%d%d%d)[ \r]")

    if code then
      if code == "151" then
        in_def = true
      elseif code == "250" then
        if out[#out] ~= "" then
          out[#out + 1] = ""
        end
        in_def = false
      end
    elseif line == "." then
      in_def = false
    elseif in_def then
      out[#out + 1] = line
    end
  end

  while out[#out] == "" do
    out[#out] = nil
  end
  return out
end

--- Fetch a definition via the DICT protocol.
-- @param server     string  e.g. "dict.org"
-- @param port       number  e.g. 2628
-- @param database   string  e.g. "wn", "moby-thesaurus"
-- @param word       string  word to look up
-- @param timeout_ms number  milliseconds before giving up
-- @param on_lines   fun(lines: string[])  called on the vim main thread
function M.define(server, port, database, word, timeout_ms, on_lines)
  local client = uv.new_tcp()
  local buf, done = "", false

  local function finish()
    if done then
      return
    end
    done = true
    pcall(function()
      client:read_stop()
    end)
    pcall(function()
      client:close()
    end)
    vim.schedule(function()
      on_lines(parse(buf))
    end)
  end

  local timer = uv.new_timer()
  timer:start(timeout_ms, 0, function()
    timer:close()
    finish()
  end)

  -- uv.tcp:connect() requires an IP address, not a hostname
  uv.getaddrinfo(server, nil, { family = "inet" }, function(err, res)
    if err or not res or not res[1] then
      timer:close()
      vim.schedule(function() on_lines({}) end)
      return
    end

    client:connect(res[1].addr, port, function(cerr)
      if cerr then
        timer:close()
        vim.schedule(function() on_lines({}) end)
        return
      end

      local cmd = ("CLIENT nvim-lexicon\r\nDEFINE %s %s\r\nQUIT\r\n"):format(database, word)
      client:write(cmd)

      client:read_start(function(rerr, data)
        if rerr or not data then
          timer:close()
          finish()
          return
        end
        buf = buf .. data
        if buf:find("221[ \r]") then -- 221 = server goodbye after QUIT
          timer:close()
          finish()
        end
      end)
    end)
  end)
end

return M
