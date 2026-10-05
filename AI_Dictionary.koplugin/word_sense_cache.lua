-- Cache document ranges, including successful queries with no selected words.
local Cache = {}
Cache.__index = Cache

function Cache.new(limit, source)
  return setmetatable({ limit = limit, source = source, records = {}, order = {} }, Cache)
end

function Cache:touch(id)
  for i, key in ipairs(self.order) do
    if key == id then table.remove(self.order, i); break end
  end
  self.order[#self.order + 1] = id
end

function Cache:covers(record, word)
  return self.source:compare(record.pos0, word.pos0) <= 0
    and self.source:compare(word.pos1, record.pos1) <= 0
end

function Cache:find(word)
  for i = #self.order, 1, -1 do
    local record = self.records[self.order[i]]
    if self:covers(record, word) then self:touch(record.id); return record end
  end
end

function Cache:put(chunk, entries, protected)
  local record = { id = chunk.id, pos0 = chunk.pos0, pos1 = chunk.pos1, entries = entries }
  self.records[record.id] = record
  self:touch(record.id)
  while #self.order > self.limit do
    local victim
    for i, id in ipairs(self.order) do
      if not protected or not protected[id] then victim = i; break end
    end
    -- The bound is soft only if the visible viewport itself needs more chunks.
    -- Never evict visible results to admit speculative work.
    if not victim then break end
    self.records[table.remove(self.order, victim)] = nil
  end
  return record
end

function Cache:entries()
  local entries, seen = {}, {}
  for _, id in ipairs(self.order) do
    for _, entry in ipairs(self.records[id].entries) do
      local key = self.source:key(entry.pos0) .. ":" .. self.source:key(entry.pos1)
      if not seen[key] then entries[#entries + 1], seen[key] = entry, true end
    end
  end
  return entries
end

return Cache
