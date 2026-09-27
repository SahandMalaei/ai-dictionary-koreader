-- A popup owns one linear journey. Entries own their answer resources; the
-- supplied disposer also cancels any work still running for a discarded entry.
local LookupHistory = {}
LookupHistory.__index = LookupHistory

function LookupHistory.new(dispose)
  return setmetatable({ entries = {}, index = 0, dispose = dispose }, LookupHistory)
end

function LookupHistory:current()
  return self.entries[self.index]
end

function LookupHistory:can_move(offset)
  local current = self:current()
  return not self.closed and current ~= nil and not current.cancelled
      and (offset == -1 or (offset == 1 and current.finished == true))
      and self.entries[self.index + offset] ~= nil
end

function LookupHistory:move(offset)
  if not self:can_move(offset) then return nil end
  if offset == -1 and not self:current().finished then
    -- Back abandons an unfinished answer, including queued/streaming work.
    -- Remove only this entry so regeneration cannot discard its neighbors.
    self.dispose(table.remove(self.entries, self.index))
  end
  self.index = self.index + offset
  return self:current()
end

function LookupHistory:append(entry)
  if self.closed then return end
  for i = #self.entries, self.index + 1, -1 do
    self.dispose(self.entries[i])
    self.entries[i] = nil
  end
  self.index = self.index + 1
  self.entries[self.index] = entry
end

function LookupHistory:replace(entry)
  if self.closed or not self:current() then return end
  self.dispose(self:current())
  self.entries[self.index] = entry
end

function LookupHistory:clear()
  if self.closed then return end
  self.closed = true
  for i = #self.entries, 1, -1 do
    self.dispose(self.entries[i])
    self.entries[i] = nil
  end
  self.index = 0
end

return LookupHistory
