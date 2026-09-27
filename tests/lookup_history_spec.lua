-- Run from the repository root: luajit tests/lookup_history_spec.lua
package.path = "./AI_Dictionary.koplugin/?.lua;" .. package.path

local requests, image_jobs, logs, buffers = {}, {}, {}, {}
local scheduled = {}
local android = false
local UI = { shows = 0 }
function UI:scheduleIn(_, action) scheduled[action] = true end
function UI:unschedule(action) scheduled[action] = nil end
function UI:show(viewer) self.active = viewer; self.shows = self.shows + 1 end
function UI:close(viewer) if self.active == viewer then self.active = nil end end
function UI:forceRePaint() end
function UI:yieldToEPDC() end
package.loaded["ui/uimanager"] = UI
package.loaded.device = { isAndroid = function() return android end }
package.loaded.logger = { err = function() end }
package.loaded.configuration_manager = {
  is_images_enabled = function() return true end,
  is_debug_mode_enabled = function() return false end,
  is_english_output = function() return true end,
}
package.loaded.context = { build_query_context = function()
  return {
    selected_text = "beaver", display_selection = "beaver", selection_context = "book context",
    replacements = { ["{selection}"] = "beaver" }, viewer_position = "bottom",
  }
end }
package.loaded.lookups_log = function(_, selection, context)
  logs[#logs + 1] = { selection, context }
  return true
end
package.loaded.tts = {
  create_request_if_available = function(selection) return { text = selection } end,
  cancel = function(request) if request then request.cancelled = true end end,
  mark_text_query_finished = function(request) request.finished = true end,
}

local Viewer = {}
Viewer.__index = Viewer
function Viewer:new(options) return setmetatable(options, self) end
function Viewer:isTextLookupPending()
  return self.pending_text_lookup and not self.pending_text_lookup.completed
end
function Viewer:cancelPendingTextLookup() self.pending_text_lookup = nil end
function Viewer:refreshHistoryButtons()
  self.back_enabled = self.lookup_history:can_move(-1)
  self.forward_enabled = self.lookup_history:can_move(1)
end
function Viewer:update(text, header, options)
  local copy = {}
  for key, value in pairs(self) do copy[key] = value end
  copy.text, copy.header_text = text, header or self.header_text
  for key, value in pairs(options or {}) do
    copy[key == "on_deep_dive" and "onDeepDive" or key] = value
  end
  local viewer = Viewer:new(copy)
  UI:close(self)
  UI:show(viewer)
  return viewer
end
function Viewer:onClose()
  self:cancelPendingTextLookup()
  if self.stream_cancel then self.stream_cancel() end
  if self.auxiliary_cancel then self.auxiliary_cancel() end
  UI:close(self)
  if self.close_callback then self.close_callback() end
end
package.loaded.ai_viewer = Viewer

local function buffer()
  local result = { freed = 0 }
  function result:free()
    self.freed = self.freed + 1
    assert(self.freed == 1, "image buffer freed twice")
  end
  buffers[#buffers + 1] = result
  return result
end
local function image(title)
  return { bb = buffer(), hi_bb = buffer(), title = title, width = 100, height = 100 }
end
local Wiki = {
  prompt_suffix = " [image]",
  prompt_suffix_for_deep_dive = function(term) return " [image for " .. term .. "]" end,
  required_viewport_height = function() return 200 end,
  new_placeholder = function(title) return { bb = buffer(), title = title, is_placeholder = true } end,
  from_file = function(_, title) return image(title) end,
  from_data = function(_, title) return image(title) end,
  parse_response = function(response)
    local title, text = response:match("^%[([^%]]+)%](.*)$")
    return title ~= "None" and title or nil, text or "", title ~= nil
  end,
  strip_metadata_fallback = function(text) return text end,
  thumbnail_api_url = function(title) return "api/" .. title end,
  parse_thumbnail_response = function() return "image/url" end,
}
function Wiki.free(descriptor)
  if not descriptor then return end
  if descriptor.bb then descriptor.bb:free(); descriptor.bb = nil end
  if descriptor.hi_bb then descriptor.hi_bb:free(); descriptor.hi_bb = nil end
end
package.loaded.wikipedia_image = Wiki
package.loaded.background_worker = { start = function(_, callbacks)
  local job = { callbacks = callbacks }
  image_jobs[#image_jobs + 1] = job
  return function()
    job.cancelled = true
    if job.fail_cancel then error("failed to cancel image worker") end
  end
end }
package.loaded.android_http_worker = { start = function(options, callbacks)
  local job = { options = options, callbacks = callbacks }
  image_jobs[#image_jobs + 1] = job
  return function() job.cancelled = true end
end }
package.loaded.ai_query = function(messages, callbacks)
  local request = { messages = messages, callbacks = callbacks }
  requests[#requests + 1] = request
  return function() request.cancelled = true end
end

local Query = require("query_session")
local plugin = { path = ".", ui = { highlight = { onClose = function() end } } }
function plugin:Regenerate(viewer) Query.regenerate(self, viewer) end
function plugin:playDictionaryPronunciation(request) self.spoken = request.text end
local function start(kind)
  Query.query(plugin, {}, kind or "AI Dictionary", true, "Original {selection}", { temperature = 0.1 })
  local history = UI.active.lookup_history
  local action = UI.active.lookup_session.query_start_action
  assert(scheduled[action]); scheduled[action] = nil; action()
  return history
end
local function run_pending()
  local entry = UI.active.lookup_session
  local action = entry.query_start_action
  assert(scheduled[action]); scheduled[action] = nil; action()
end
local function finish(text) requests[#requests].callbacks.on_done(text or "[None]answer") end
local function lookup(term)
  UI.active.text_selection_callback(term, "popup " .. term)
  run_pending()
end
local function go(offset) UI.active.onHistoryNavigate(offset) end
local function regenerate() Query.regenerate(plugin, UI.active); run_pending() end
local function contains(text, value) assert(text:find(value, 1, true), text .. " missing " .. value) end

-- Cached text, headers, pronunciation and images; delayed images stay on their node.
local history = start()
assert(not history:can_move(-1) and not history:can_move(1))
finish("[Beaver]Definition: first answer")
local first = history:current()
local first_text, first_header = UI.active.text, UI.active.header_text
local first_image_job = image_jobs[#image_jobs]
lookup("rodent")
finish("[Rodent]Definition: second answer")
local second = history:current()
local second_image_job = image_jobs[#image_jobs]
local shown = UI.shows
first_image_job.callbacks.on_message("pixels")
first_image_job.callbacks.on_complete()
assert(UI.shows == shown and not first.image_descriptor.is_placeholder)
local request_count, image_count, log_count = #requests, #image_jobs, #logs
go(-1)
assert(UI.active.text == first_text and UI.active.header_text == first_header)
assert(UI.active.images[1] == first.image_descriptor and UI.active.text_lookup_enabled)
UI.active.onPronunciation(); assert(plugin.spoken == "beaver")
go(1)
UI.active.onPronunciation(); assert(plugin.spoken == "rodent")
assert(#requests == request_count and #image_jobs == image_count and #logs == log_count)

-- Branching disposes the entire forward tail, and ignores its late callbacks.
lookup("mammal"); finish("[Mammal]third answer")
local third = history:current()
go(-1); go(-1)
lookup("dam"); finish("[None]branched answer")
assert(#history.entries == 2 and history.entries[1] == first)
assert(second.cancelled and third.cancelled and second_image_job.cancelled)
assert(second.image_descriptor == nil and second.message_history == nil)
shown = UI.shows
second_image_job.callbacks.on_message("late pixels")
second_image_job.callbacks.on_complete()
assert(UI.shows == shown)

-- Regenerating a middle entry changes only that node and its resource ownership.
lookup("river"); finish("[River]river answer")
local tail = history:current()
local tail_messages = tail.message_history
go(-1)
local old_middle = history:current()
local original_prompt = old_middle.message_history[1].content
log_count = #logs
regenerate()
assert(requests[#requests].messages[1].content == original_prompt)
assert(old_middle.cancelled and #history.entries == 3 and history.entries[3] == tail)
finish("[NewDam]new middle answer")
assert(#logs == log_count, "regeneration must not duplicate lookup logging")
local replacement = history:current()
assert(replacement ~= old_middle and UI.active.back_enabled and UI.active.forward_enabled)
assert(tail.message_history == tail_messages)
go(1); contains(UI.active.text, "river answer")
go(-1); contains(UI.active.text, "new middle answer")
go(-1); assert(UI.active.text == first_text)

-- Selection confirmation cannot navigate, but a completed recursive selection can.
UI.active.pending_text_lookup = { completed = false }
go(1); assert(history:current() == first)
UI.active.pending_text_lookup.completed = true
UI.active.text_lookup_enabled = false
lookup("branch after selection"); finish()
go(-1); assert(UI.active.text_lookup_enabled)
UI.active:onClose()
assert(history.closed and #history.entries == 0 and history.index == 0)
assert(first.image_descriptor == nil and replacement.cancelled and tail.cancelled)

-- Explain keeps independent conversation tails and regenerates the selected focus.
history = start("AI Explain"); finish("[None]root explanation")
first = history:current()
lookup("architecture"); finish("[None]architecture explanation")
second = history:current()
lookup("arches"); finish("[None]arches explanation")
third = history:current()
assert(#first.message_history == 2 and #second.message_history == 4 and #third.message_history == 6)
go(-1); regenerate()
local messages = requests[#requests].messages
assert(#messages == 3 and messages[2].content == "root explanation")
contains(messages[3].content, "beaver -> architecture")
contains(messages[3].content, "[image for architecture]")
finish("[None]new architecture explanation")
assert(history.entries[3] == third and third.message_history[4].content == "architecture explanation")
lookup("bridges"); finish()
messages = history:current().message_history
assert(third.cancelled and messages[4].content == "new architecture explanation")
contains(messages[5].content, "beaver -> architecture -> bridges")
assert(not messages[5].content:find("arches", 1, true))
UI.active:onClose()

-- Errors remain navigable, and a cancelled generation cannot overwrite its replacement.
history = start(); finish()
lookup("error")
requests[#requests].callbacks.on_error("offline")
assert(UI.active.back_enabled and not UI.active.text_lookup_enabled)
go(-1); go(1); contains(UI.active.text, "offline")
regenerate()
local obsolete = requests[#requests]
regenerate()
shown = UI.shows
obsolete.callbacks.on_done("[Obsolete]stale answer")
obsolete.callbacks.on_error("stale error")
assert(obsolete.cancelled and UI.shows == shown)
finish(); UI.active:onClose()

-- Back is available immediately and abandons queued or partially streamed
-- recursive lookups, without adding an incomplete answer to forward history.
for _, kind in ipairs({ "AI Dictionary", "AI Explain" }) do
  history = start(kind); finish("[None]saved answer")
  local saved = history:current()
  local saved_text = UI.active.text
  UI.active.text_selection_callback("queued lookup", "popup context")
  local queued = history:current()
  local queued_action = queued.query_start_action
  assert(history:can_move(-1) and not history:can_move(1))
  request_count = #requests
  go(-1)
  assert(history:current() == saved and #history.entries == 1 and UI.active.text == saved_text)
  assert(queued.cancelled and not scheduled[queued_action] and not history:can_move(1))
  queued_action(); assert(#requests == request_count)

  lookup("partial lookup")
  local partial = history:current()
  local partial_request = requests[#requests]
  partial_request.callbacks.on_delta("", "[Partial]Definition: partial answer\nExample: waiting", 20)
  local partial_image_job = image_jobs[#image_jobs]
  local partial_image = partial.image_descriptor
  assert(history:can_move(-1) and not partial.finished)
  contains(UI.active.text, "partial answer")
  go(-1)
  assert(history:current() == saved and UI.active.text == saved_text)
  assert(#history.entries == 1 and not history:can_move(1))
  assert(partial.cancelled and partial_request.cancelled and partial_image_job.cancelled)
  assert(partial_image.bb == nil and partial_image.hi_bb == nil)
  shown, log_count = UI.shows, #logs
  partial_request.callbacks.on_delta("", "[Late]stale delta", 100)
  partial_request.callbacks.on_done("[Late]stale answer")
  partial_request.callbacks.on_error("stale error")
  partial_image_job.callbacks.on_message("stale pixels")
  partial_image_job.callbacks.on_complete()
  assert(UI.shows == shown and #logs == log_count)
  lookup("after cancellation"); finish()
  assert(#history.entries == 2 and history.entries[1] == saved)
  UI.active:onClose()
end

-- Cancelling a regeneration also leaves its completed neighbors intact.
history = start(); finish("[None]first")
first = history:current()
lookup("middle"); finish("[None]middle")
lookup("last"); finish("[None]last")
local last = history:current()
go(-1); regenerate()
local unfinished = history:current()
local unfinished_request = requests[#requests]
assert(history:can_move(-1) and not history:can_move(1))
go(-1)
assert(unfinished.cancelled and unfinished_request.cancelled)
assert(history:current() == first and #history.entries == 2 and history.entries[2] == last)
go(1); contains(UI.active.text, "last")
UI.active:onClose()

-- Closing before launch unschedules the query; closing during it cancels all work.
Query.query(plugin, {}, "AI Dictionary", true, "pending")
local pending_entry = UI.active.lookup_session
local pending_action = pending_entry.query_start_action
request_count = #requests
UI.active:onClose()
assert(not scheduled[pending_action]); pending_action()
assert(#requests == request_count)
history = start()
local active_request = requests[#requests]
active_request.callbacks.on_delta("", "[Closing]Definition: partial\nExample: waiting", 20)
local active_image_job = image_jobs[#image_jobs]
UI.active:onClose()
assert(active_request.cancelled and active_image_job.cancelled and history.closed)
shown = UI.shows
active_request.callbacks.on_done("[Closing]late answer")
active_image_job.callbacks.on_complete()
assert(UI.shows == shown)

-- A broken worker cancellation still frees fallback and cached image buffers.
history = start(); finish("[CancelFailure]answer")
image_jobs[#image_jobs].fail_cancel = true
history:current().stream_cancel = function() error("failed to cancel stream") end
UI.active:onClose()
assert(history.closed)

-- Android's two-stage image download also completes safely off screen.
android = true
history = start(); finish("[Android]android answer")
first = history:current()
local api_job = image_jobs[#image_jobs]
lookup("other"); finish()
shown = UI.shows
api_job.callbacks.on_complete(200, "metadata")
local download_job = image_jobs[#image_jobs]
download_job.callbacks.on_complete(200)
assert(UI.shows == shown and not first.image_descriptor.is_placeholder)
go(-1); assert(UI.active.images[1] == first.image_descriptor)
UI.active:onClose()
android = false

-- The non-recursive Simplify and report flows still render and regenerate.
start("AI Simplify")
finish("simplified answer")
assert(not UI.active.lookup_history)
regenerate(); finish("regenerated simplification")
contains(UI.active.text, "regenerated simplification")
UI.active:onClose()
local report = Viewer:new { text = "loading", benedict = plugin }
UI:show(report)
Query.start_report(report, "report prompt")
finish("report answer")
regenerate(); finish("regenerated report")
contains(UI.active.text, "regenerated report")
UI.active:onClose()

-- Every decoded buffer, including unused fallbacks, is explicitly released once.
for _, bb in ipairs(buffers) do assert(bb.freed == 1, "leaked image buffer") end
assert(next(scheduled) == nil, "scheduled work remains after closing")
print("lookup history: all tests passed")
