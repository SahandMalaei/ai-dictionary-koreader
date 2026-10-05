-- Keep nearby page requests alive across navigation, with a fixed concurrency cap.
local Requests = {}
Requests.__index = Requests
local ErrorBoundary = require("error_boundary")

function Requests.new(limit)
  return setmetatable({ limit = limit, jobs = {}, sequence = 0 }, Requests)
end

function Requests:remove(job, cancel)
  if self.jobs[job.key] ~= job then return false end
  -- Remove first: cancelling a transport may synchronously invoke its callback.
  self.jobs[job.key] = nil
  if cancel and job.cancel then ErrorBoundary.call("cancel Word Sense request", job.cancel) end
  job.cancel = nil
  return true
end

function Requests:reserve(key, page, current_page)
  if self.jobs[key] then return end
  local count, farthest, distance = 0, nil, -1
  for _, job in pairs(self.jobs) do
    count = count + 1
    local delta = math.abs(job.page - current_page)
    if delta > distance or (delta == distance and job.sequence < farthest.sequence) then
      farthest, distance = job, delta
    end
  end
  if count >= self.limit then
    -- A speculative page must never displace a closer active page.
    if math.abs(page - current_page) > distance then return end
    self:remove(farthest, true)
  end
  self.sequence = self.sequence + 1
  local job = { key = key, page = page, sequence = self.sequence }
  self.jobs[key] = job
  return job
end

function Requests:cancel_all()
  local jobs = self.jobs
  self.jobs = {}
  for _, job in pairs(jobs) do
    if job.cancel then ErrorBoundary.call("cancel Word Sense request", job.cancel) end
    job.cancel = nil
  end
end

return Requests
