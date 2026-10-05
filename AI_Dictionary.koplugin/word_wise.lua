local Config = require("configuration_manager")
local ErrorBoundary = require("error_boundary")
local Cache = require("word_wise_cache")
local Chunk = require("word_wise_chunk")
local Source = require("word_wise_source")
local Prompt = require("word_wise_prompt")
local Requests = require("word_wise_requests")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local View = require("word_wise_view")
local logger = require("logger")
local queryAI = require("ai_query")

local WordWise = {}
WordWise.__index = WordWise
local MODULE = "ai_dictionary_word_wise"
local PAGE_DELAY = 0.6
local CACHE_SIZE = 16
-- Complete chunks to prefetch after the visible text, in order.
local LOOKAHEAD_CHUNKS = 2

function WordWise.new(plugin)
  local source = Source.new(plugin.ui)
  if not source then return end
  local self = setmetatable({
    ui = plugin.ui, source = source, generation = 0, overlay = View.new(),
    cache = Cache.new(CACHE_SIZE, source),
    requests = Requests.new(5),
  }, WordWise)
  self.module = {
    paintTo = ErrorBoundary.wrap("paint Word Wise", function(_, bb, x, y) self:paint(bb, x, y) end),
  }
  self.ui.view:registerViewModule(MODULE, self.module)
  self:install_taps()
  return self
end

function WordWise:signature()
  return self.source:signature(Screen:getWidth(), Screen:getHeight())
end

function WordWise:priority_page(chunk)
  -- Distance belongs to the whole range, not its first paragraph's page.
  -- A long paragraph beginning far behind the viewport is still visible work.
  local current = self.source:current_page()
  return math.max(self.source:page(chunk.pos0), math.min(current, self.source:page(chunk.pos1)))
end

function WordWise:selecting()
  local highlight = self.ui.highlight
  return highlight and (highlight.hold_pos or highlight.selected_text or highlight.select_mode)
end

function WordWise:redraw()
  UIManager:setDirty(self.ui.dialog or self.ui, "ui")
end

function WordWise:stop_scan()
  self.generation = self.generation + 1
  if self.pending then UIManager:unschedule(self.pending); self.pending = nil end
end

function WordWise:cancel()
  self:stop_scan()
  self.requests:cancel_all()
end

function WordWise:schedule(delay, callback)
  if self.pending then UIManager:unschedule(self.pending) end
  self.pending = ErrorBoundary.wrap("scan Word Wise passage", function()
    self.pending = nil
    callback()
  end)
  UIManager:scheduleIn(delay, self.pending)
end

function WordWise:current(generation, signature)
  return not self.closed and not self.suspended and generation == self.generation
    and signature == self:signature()
end

function WordWise:refresh(force)
  if self.closed or self.suspended then return end
  local signature = self:signature()
  if not force and signature == self.page_signature then return end
  self:stop_scan()
  self.overlay:clear()
  self.page_signature = signature
  local configuration = Config.load()
  local model = configuration.word_wise_model ~= "" and configuration.word_wise_model
    or configuration.text_model or "gpt-5-nano"
  local scope = table.concat({
    configuration.word_wise_level, configuration.output_language, model, configuration.text_endpoint or "",
  }, "\n")
  if scope ~= self.scope then
    self.requests:cancel_all()
    self.cache = Cache.new(CACHE_SIZE, self.source)
  end
  self.scope, self.configuration = scope, configuration
  self.viewport, self.failed, self.scan_failed, self.nearby = nil, {}, nil, {}
  for _, job in pairs(self.requests.jobs) do
    job.page = self:priority_page(job.chunk)
  end
  self:display()
  self:schedule(#self.overlay.boxes > 0 and 0 or PAGE_DELAY, function() self:scan() end)
  self:redraw()
end

function WordWise:settings_changed()
  -- Only changes affecting meanings invalidate results. Font changes and other
  -- unrelated settings simply rebuild the viewport and geometry.
  self:refresh(true)
end

function WordWise:layout_changed()
  self:refresh(true)
end

function WordWise:protected(chunk)
  local protected = {}
  for id in pairs(self.nearby or {}) do protected[id] = true end
  if self.viewport then
    for _, word in ipairs(self.viewport.words) do
      for _, id in ipairs(self.cache.order) do
        if self.cache:covers(self.cache.records[id], word) then protected[id] = true end
      end
      if chunk and self.cache:covers(chunk, word) then protected[chunk.id] = true end
    end
  end
  return protected
end

function WordWise:display()
  self.overlay.boxes = self.source:boxes(self.cache:entries(), Screen:getWidth(), Screen:getHeight())
  self:redraw()
end

function WordWise:coverage(word)
  local record = self.cache:find(word)
  if record then return record end
  for _, job in pairs(self.requests.jobs) do
    if self.cache:covers(job.chunk, word) then return job.chunk, "active" end
  end
  for _, chunk in ipairs(self.failed) do
    if self.cache:covers(chunk, word) then return chunk end
  end
end

function WordWise:next_word()
  local last
  self.nearby = {}
  for _, word in ipairs(self.viewport.words) do
    local record, status = self:coverage(word)
    if not record then return word end
    if status == "active" then return end
    if not last or self.source:compare(last.pos1, record.pos1) < 0 then last = record end
  end
  if not last then return end
  for _ = 1, LOOKAHEAD_CHUNKS do
    local word = self.source:after(last.pos1)
    if not word then return end
    local record, status = self:coverage(word)
    if not record then
      -- When an unusually dense viewport already occupies the entire cache,
      -- stop speculative work instead of repeatedly querying rejected entries.
      local count = 0
      for _ in pairs(self:protected()) do count = count + 1 end
      if count >= self.cache.limit then return end
      return word
    end
    self.nearby[record.id] = true
    if status == "active" then return end
    last = record
  end
end

function WordWise:extract(step, done)
  local generation, signature = self.generation, self.page_signature
  local function advance()
    if not self:current(generation, signature) then return end
    -- Extracting reflowable text clears the engine's selection. Pause before every
    -- batch while KOReader owns a live selection.
    if self:selecting() then self:schedule(0.3, advance); return end
    local ok, finished, err = pcall(step)
    if not ok or err then
      self.scan_failed = true
      logger.warn("AI Dictionary Word Wise extraction: " .. tostring(err or finished))
      return
    end
    if finished then done() else self:schedule(0.01, advance) end
  end
  advance()
end

function WordWise:scan()
  if self.closed or self.suspended or self.scan_failed then return end
  if self.page_signature ~= self:signature() then self:refresh(); return end
  if self:selecting() then self:schedule(0.3, function() self:scan() end); return end
  if not self.viewport then
    local viewport = self.source:viewport()
    self:extract(function() return self.source:step_viewport(viewport) end, function()
      self.viewport = viewport
      self:display()
      self:wake()
    end)
    return
  end
  local ok, word = pcall(self.next_word, self)
  if not ok then
    self.scan_failed = true
    logger.warn("AI Dictionary Word Wise navigation: " .. tostring(word))
    return
  end
  if not word then return end
  local chunk = Chunk.new(self.source, word)
  self:extract(function() return Chunk.step(chunk) end, function()
    if chunk.id then self:request(chunk) end
  end)
end

function WordWise:wake()
  if not self.closed and not self.suspended and not self.pending then
    self:schedule(0, function() self:scan() end)
  end
end

function WordWise:finished(job, chunk, response)
  if not self.requests:remove(job) then return end
  -- Recheck the viewport before displaying anything; a page event may be pending.
  self:refresh()
  if self.closed or self.suspended or job.scope ~= self.scope then return end
  local entries, err
  if response ~= nil then entries, err = Prompt.parse(response, chunk.words) end
  if entries then
    self.cache:put(chunk, entries, self:protected(chunk))
    self:display()
  else
    -- Only failures suppress a retry for this visit. Successful coverage is
    -- always determined by stored ranges, so eviction cannot create scan gaps.
    self.failed[#self.failed + 1] = { id = chunk.id, pos0 = chunk.pos0, pos1 = chunk.pos1 }
    logger.warn("AI Dictionary Word Wise: " .. (err or "passage request failed."))
  end
  self:wake()
end

function WordWise:request(chunk)
  local configuration = self.configuration
  local messages = Prompt.messages(chunk, chunk.context,
    configuration.word_wise_level, configuration.output_language)
  local key = self.scope .. "\n" .. chunk.id
  local job = self.requests:reserve(key, self:priority_page(chunk), self.source:current_page())
  if not job then return end -- Retry when a nearer request finishes and frees a slot.
  job.scope, job.chunk = self.scope, chunk
  local ok, cancel = pcall(queryAI, messages, {
    model = configuration.word_wise_model,
    reasoning_effort = "low",
    provider_sort = "price",
    -- Keep compatibility with providers that do not support JSON response mode.
    on_done = ErrorBoundary.wrap("receive Word Wise definitions", function(response)
      self:finished(job, chunk, response)
    end),
    on_error = ErrorBoundary.wrap("Word Wise request error", function()
      self:finished(job, chunk)
    end),
  })
  if not ok then
    self:finished(job, chunk)
  elseif self.requests.jobs[key] == job and type(cancel) == "function" then
    -- Some callbacks are synchronous; do not retain a finished worker.
    job.cancel = cancel
  end
end

function WordWise:paint(bb, x, y)
  if self.closed or self.suspended then return end
  -- Also catches layout changes and position changes without a reader event.
  self:refresh()
  if not self:selecting() then self.overlay:paint(bb, x, y) end
end

function WordWise:tap(ges)
  if self.closed or self.suspended or not ges or not ges.pos or self:selecting() then return end
  if self.page_signature ~= self:signature() then self:refresh(); return end
  local had_popup = self.overlay.popup ~= nil
  local handled = self.overlay:tap(ges.pos)
  if self.overlay.popup then self:register_popup_taps() end
  if handled or had_popup then self:redraw() end
  return handled
end

function WordWise:close_popup()
  if self.overlay:close_popup() then self:redraw() end
end

function WordWise:register_popup_taps()
  if type(self.ui.registerTouchZones) ~= "function" then return end
  local id = MODULE .. "_popup_tap"
  local overrides = {}
  -- Register when a bubble opens so even zones installed after ReaderReady
  -- (links, menus, page-turn regions and custom gestures) come after dismissal.
  for zone_id, zone in pairs(self.ui._zones or {}) do
    if zone_id ~= id and zone.def and zone.def.ges == "tap" then
      overrides[#overrides + 1] = zone_id
    end
  end
  self.popup_touch_zones = { {
    id = id, ges = "tap",
    screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
    overrides = overrides,
    handler = ErrorBoundary.wrap("tap Word Wise bubble", function(ges)
      if self.overlay.popup then return self:tap(ges) end
    end),
  } }
  self.ui:registerTouchZones(self.popup_touch_zones)
end

function WordWise:install_taps()
  local highlight = self.ui.highlight
  if not highlight then return end
  self.original_tap, self.original_hold = highlight.onTap, highlight.onHold
  self.tap_wrapper = function(widget, arg, ges)
    if self.overlay.popup and ErrorBoundary.call("tap Word Wise bubble", self.tap, self, ges) then
      return true
    end
    -- Saved highlights and selection gestures retain their normal priority.
    local result
    if self.original_tap then result = self.original_tap(widget, arg, ges) end
    if result then return result end
    return ErrorBoundary.call("tap Word Wise", self.tap, self, ges)
  end
  self.hold_wrapper = function(widget, ...)
    ErrorBoundary.call("dismiss Word Wise on hold", self.close_popup, self)
    if self.original_hold then return self.original_hold(widget, ...) end
  end
  highlight.onTap, highlight.onHold = self.tap_wrapper, self.hold_wrapper
end

function WordWise:suspend()
  self.suspended = true
  self:cancel()
  self.overlay:clear()
  self:redraw()
end

function WordWise:resume()
  self.suspended = false
  self:refresh(true)
end

function WordWise:close()
  if self.closed then return end
  self.closed = true
  self:cancel()
  self.overlay:clear()
  self.cache = Cache.new(CACHE_SIZE, self.source)
  if self.popup_touch_zones and type(self.ui.unRegisterTouchZones) == "function" then
    self.ui:unRegisterTouchZones(self.popup_touch_zones)
    self.popup_touch_zones = nil
  end
  local modules = self.ui.view.view_modules
  if modules and modules[MODULE] == self.module then modules[MODULE] = nil end
  local highlight = self.ui.highlight
  if highlight then
    -- Leave wrappers installed by another plugin after ours intact.
    if highlight.onTap == self.tap_wrapper then highlight.onTap = self.original_tap end
    if highlight.onHold == self.hold_wrapper then highlight.onHold = self.original_hold end
  end
end

return WordWise
