-- Simple bounded LRU cache for dict.org definitions.
-- Key is `word .. "\0" .. source`; value is the parsed lines array.
--
-- Not global — one instance per user through the module singleton pattern.
local M = {}

local MAX = 100
local data = {} -- key -> lines
local order = {} -- array of keys, oldest first
local count = 0

local function bump(key)
  for i = 1, #order do
    if order[i] == key then
      table.remove(order, i)
      break
    end
  end
  order[#order + 1] = key
end

function M.get(word, src)
  local key = word .. "\0" .. src
  local v = data[key]
  if v then
    bump(key)
  end
  return v
end

function M.set(word, src, lines)
  local key = word .. "\0" .. src
  if data[key] then
    bump(key)
    data[key] = lines
    return
  end
  data[key] = lines
  order[#order + 1] = key
  count = count + 1
  if count > MAX then
    local drop = table.remove(order, 1)
    data[drop] = nil
    count = count - 1
  end
end

function M.clear()
  data, order, count = {}, {}, 0
end

return M
