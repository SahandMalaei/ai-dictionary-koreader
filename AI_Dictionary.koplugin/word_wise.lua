local Config = require("configuration_manager")
local ErrorBoundary = require("error_boundary")
local Page = require("word_wise_page")
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
-- Number of pages to prefetch after the current page, in order. Set to 0 for none.
local LOOKAHEAD_PAGES = 2

function WordWise.new(plugin)
  if not Page.supported(plugin.ui) then return end
  local self = setmetatable({
    ui = plugin.ui, generation = 0, cache = {}, cache_order = {}, overlay = View.new(),
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
  return Page.signature(self.ui, Screen:getWidth(), Screen:getHeight())
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
  self.pending = ErrorBoundary.wrap("scan Word Wise page", function()
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
    Page.layout_signature(self.ui, Screen:getWidth(), Screen:getHeight()),
    configuration.word_wise_level, configuration.output_language, model,
  }, "\n")
  if scope ~= self.scope then
    self.requests:cancel_all()
    self.cache, self.cache_order = {}, {}
  end
  self.scope, self.configuration = scope, configuration
  self.target = Page.target(self.ui)
  self.current_key = self:key(self.target)
  self.attempted = {}
  local cached = self.cache[self.current_key]
  if cached then
    self.attempted[self.current_key] = true
    self:display(cached)
  end
  self:schedule(cached and 0 or PAGE_DELAY, function() self:scan() end)
  self:redraw()
end

function WordWise:settings_changed()
  self:cancel()
  self.cache, self.cache_order, self.scope = {}, {}, nil
  self:refresh(true)
end

function WordWise:key(target)
  return self.scope .. "\n" .. target.id
end

function WordWise:remember(key, entries)
  if not self.cache[key] then
    self.cache_order[#self.cache_order + 1] = key
    if #self.cache_order > CACHE_SIZE then
      self.cache[table.remove(self.cache_order, 1)] = nil
    end
  end
  self.cache[key] = entries
end

function WordWise:display(entries)
  self.overlay.boxes = Page.boxes(self.ui.document, entries, Screen:getWidth(), Screen:getHeight())
  self:redraw()
end

function WordWise:next_target()
  local target = self.target
  for offset = 0, LOOKAHEAD_PAGES do
    if not target then return end
    local key = self:key(target)
    -- Wait for each nearer page to finish before starting the following page.
    if self.requests.jobs[key] then return end
    if not self.cache[key] and not self.attempted[key] then return target, key end
    if offset < LOOKAHEAD_PAGES then target = Page.following(self.ui, target) end
  end
end

function WordWise:scan()
  if self.closed or self.suspended then return end
  if self.page_signature ~= self:signature() then self:refresh(); return end
  -- Text extraction clears crengine's temporary selection. Never run it while
  -- KOReader owns an active selection, including between scan batches.
  if self:selecting() then
    self:schedule(0.3, function() self:scan() end)
    return
  end
  local target, key = self:next_target()
  if not target then return end
  local generation, signature = self.generation, self.page_signature
  local page = Page.new(self.ui, target)
  local function step()
    if not self:current(generation, signature) then return end
    if self:selecting() then self:schedule(0.3, step); return end
    if not Page.step(self.ui.document, page) then
      self:schedule(0.01, step)
      return
    end
    if #page.words == 0 then
      self.attempted[key] = true
      self:remember(key, {})
      self:wake()
      return
    end
    local context = Page.context(self.ui.document, page)
    self:request(page, context, key)
  end
  step()
end

function WordWise:wake()
  if not self.closed and not self.suspended and not self.pending then
    self:schedule(0, function() self:scan() end)
  end
end

function WordWise:finished(job, page, response)
  if not self.requests:remove(job) then return end
  -- Recheck the viewport before displaying anything; a page event may be pending.
  self:refresh()
  if self.closed or self.suspended or job.scope ~= self.scope then return end
  local entries, err
  if response ~= nil then entries, err = Prompt.parse(response, page.words) end
  if entries then
    self:remember(job.key, entries)
    if job.key == self.current_key then self:display(entries) end
  else
    -- Failed pages can retry on a later visit, without an automatic retry loop.
    logger.warn("AI Dictionary Word Wise: " .. (err or "page request failed."))
  end
  self.attempted[job.key] = true
  if job.key == self.current_key then
    -- A prefetch may finish just after the reader turns into that page. Replace
    -- its pending settle timer so the following page can start immediately.
    self:stop_scan()
  end
  self:wake()
end

function WordWise:request(page, context, key)
  local configuration = self.configuration
  local messages = Prompt.messages(page, context,
    configuration.word_wise_level, configuration.output_language)
  local job = self.requests:reserve(key, page.target.number, self.target.number)
  if not job then return end -- Retry when a nearer request finishes and frees a slot.
  job.scope = self.scope
  self.attempted[key] = true
  local ok, cancel = pcall(queryAI, messages, {
    model = configuration.word_wise_model,
    reasoning_effort = "low",
    provider_sort = "price",
    -- Keep compatibility with providers that do not support JSON response mode.
    on_done = ErrorBoundary.wrap("receive Word Wise definitions", function(response)
      self:finished(job, page, response)
    end),
    on_error = ErrorBoundary.wrap("Word Wise request error", function()
      self:finished(job, page)
    end),
  })
  if not ok then
    self:finished(job, page)
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
  self.cache, self.cache_order = {}, {}
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
