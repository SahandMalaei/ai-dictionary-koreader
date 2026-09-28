-- Run from the repository root: luajit tests/word_wise_spec.lua
-- KOReader geometry, scheduling, JSON decoding and networking are mocked;
-- page extraction, validation, rendering and lifecycle code are real.
package.path = "./AI_Dictionary.koplugin/?.lua;" .. package.path

local errors, warnings, requests, scheduled, decoded = {}, {}, {}, {}, {}
local draws, frees, encoded = {}, 0, nil
local screen = { width = 600, height = 800 }
function screen:getWidth() return self.width end
function screen:getHeight() return self.height end
function screen:scaleBySize(n) return n * (self.scale or 1) end
package.loaded.device = { screen = screen }
package.loaded.logger = {
  err = function(err) errors[#errors + 1] = err end,
  warn = function(err) warnings[#warnings + 1] = err end,
}
package.loaded.json = {
  encode = function(value) encoded = value; return "encoded page" end,
  decode = function(text) assert(decoded[text], "malformed JSON"); return decoded[text] end,
}
local UI = { repaints = 0 }
function UI:scheduleIn(delay, callback) scheduled[callback] = delay end
function UI:unschedule(callback) scheduled[callback] = nil end
function UI:setDirty() self.repaints = self.repaints + 1 end
function UI:show() end
package.loaded["ui/uimanager"] = UI
package.loaded["ffi/blitbuffer"] = { COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_GRAY = 2 }
package.loaded["ui/font"] = { getFace = function() return {} end }
local Text = {}
function Text:new(options) return setmetatable(options, { __index = self }) end
function Text:getSize()
  local width = self.width or #self.text * 10
  return { w = width, h = math.ceil(#self.text * 10 / width) * 24 }
end
function Text:free() frees = frees + 1 end
local Frame = {}
function Frame:new(options) return setmetatable(options, { __index = self }) end
function Frame:getSize()
  local size = self[1]:getSize()
  return { w = size.w + 2 * (self.padding + self.bordersize),
    h = size.h + 2 * (self.padding + self.bordersize) }
end
function Frame:paintTo(_, x, y) self.last_paint = { x = x, y = y } end
function Frame:free() self[1]:free(); frees = frees + 1 end
package.loaded["ui/widget/textwidget"] = Text
package.loaded["ui/widget/textboxwidget"] = Text
package.loaded["ui/widget/container/framecontainer"] = Frame
package.loaded["ui/widget/inputdialog"] = {}
package.loaded["ui/widget/infomessage"] = Text
package.loaded.gettext = function(text) return text end
package.loaded.ai_query = function(messages, callbacks)
  local request = { messages = messages, callbacks = callbacks, page = encoded, cancels = 0 }
  requests[#requests + 1] = request
  if requests.start_error then error("could not start request") end
  if requests.synchronous_error then callbacks.on_error("offline") end
  return function()
    request.cancels = request.cancels + 1
    -- Some transports can still dispatch callbacks when being cancelled.
    if request.on_cancel then request.on_cancel() end
  end
end

local Config = require("configuration_manager")
local configuration
Config.load = function() return Config.normalize(configuration) end
local Page = require("word_wise_page")
local Prompt = require("word_wise_prompt")
local View = require("word_wise_view")
local WordWise = require("word_wise")

local function pointer(index, ending) return tostring(index) .. (ending and "e" or "s") end
local function index_of(xp) return tonumber(xp:match("^(%d+)")) end
local function document(pages)
  local doc = { file = "book.EPUB", page = 1, hash = 1, texts = {}, ranges = {}, reads = 0 }
  for i, words in ipairs(pages) do
    doc.ranges[i] = { first = #doc.texts + 1 }
    for _, word in ipairs(words) do doc.texts[#doc.texts + 1] = word end
    doc.ranges[i].last = #doc.texts
  end
  function doc:getCurrentPage() return self.page end
  function doc:getCurrentPos() return self.page * 100 end
  function doc:getDocumentRenderingHash() return self.hash end
  function doc:getPageCount() return #self.ranges end
  function doc:getVisiblePageNumberCount() return self.visible_pages or 1 end
  function doc:getNextPage(p) return p < #self.ranges and p + 1 or 0 end
  function doc:getPageFromXPointer(xp)
    local index = index_of(xp)
    for p, range in ipairs(self.ranges) do
      if index >= range.first and index <= range.last then return p end
    end
    error("invalid pointer")
  end
  function doc:getPageXPointer(p) return pointer(self.ranges[p].first) end
  function doc:getXPointer() return self:getPageXPointer(self.page) end
  function doc:getNextVisibleWordEnd(xp)
    local index = index_of(xp) + (xp:sub(-1) == "e" and 1 or 0)
    if index <= #self.texts then return pointer(index, true) end
  end
  function doc:getPrevVisibleWordStart(xp) return pointer(index_of(xp)) end
  function doc:isXPointerInCurrentPage(xp)
    local index, range = index_of(xp), self.ranges[self.page]
    return index >= range.first and index <= range.last
  end
  function doc:getTextFromXPointers(a, b)
    assert(not self.selection_active, "extraction must never clear a live selection")
    self.reads = self.reads + 1
    local text = {}
    for i = index_of(a), index_of(b) do text[#text + 1] = self.texts[i] end
    return table.concat(text, " ")
  end
  function doc:getScreenBoxesFromPositions(a, b)
    self.last_boxes = { a, b }
    if self.box_error then error("bad geometry") end
    if self.boxes then return self.boxes end
    return { { x = index_of(a) * 10, y = 100, w = (index_of(b) - index_of(a) + 1) * 20, h = 20 } }
  end
  return doc
end

local function make_ui(doc)
  local ui = {
    document = doc, view = { view_mode = "page", view_modules = {} }, highlight = {},
    _zones = {
      readerhighlight_tap = { def = { ges = "tap" } },
      readerlink_tap = { def = { ges = "tap" } },
      readermenu_tap = { def = { ges = "tap" } },
      tap_forward = { def = { ges = "tap" } },
      readerhighlight_hold = { def = { ges = "hold" } },
    },
  }
  function ui.view:registerViewModule(name, module) self.view_modules[name] = module end
  function ui:registerTouchZones(zones)
    for _, zone in ipairs(zones) do self._zones[zone.id] = { def = zone, handler = zone.handler } end
  end
  function ui:unRegisterTouchZones(zones)
    for _, zone in ipairs(zones) do self._zones[zone.id] = nil end
  end
  function ui.highlight:onTap() self.native_taps = (self.native_taps or 0) + 1; return self.native_handled end
  function ui.highlight:onHold(arg, ges)
    self.native_holds = (self.native_holds or 0) + 1
    self.last_hold = { arg, ges }
    self.hold_pos = ges.pos
    doc.selection_active = true
    return "native hold"
  end
  return ui
end

local function start(pages)
  local ui = make_ui(document(pages or { { "bear", "give", "way", "bear" }, { "rare", "word" } }))
  local controller = assert(WordWise.new { ui = ui })
  controller:refresh()
  return controller, ui
end

local function tick()
  local callback = next(scheduled)
  assert(callback, "expected scheduled work")
  scheduled[callback] = nil
  callback()
end

local function drain()
  for _ = 1, 100 do
    if not next(scheduled) then return end
    tick()
  end
  error("work did not finish")
end

local function complete(request, entries)
  decoded.response = { entries = entries or { { first = 1, last = 1, meaning = "large forest animal" } } }
  request.callbacks.on_done("response")
end

local function active_count(controller)
  local count = 0
  for _ in pairs(controller.requests.jobs) do count = count + 1 end
  return count
end

local function many_pages(count)
  local pages = {}
  for i = 1, count do pages[i] = { "page" .. i } end
  return pages
end

local function turn(controller, ui, page)
  ui.document.page = page
  controller:refresh()
  drain()
end

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name, fn } end

test("reading level defaults and native choice list", function()
  assert(Config.normalize({}).word_wise_level == "Intermediate")
  assert(Config.normalize({ word_wise_level = "invalid" }).word_wise_level == "Intermediate")
  local plugin = { saveConfiguration = function(_, config) configuration = config; return true end }
  local items = require("settings_menu").get_items(plugin)
  local choices
  for _, item in ipairs(items) do
    if item.text:find("Word Wise reading level", 1, true) then choices = item.sub_item_table end
    assert(not item.text:find("Enable Word Wise", 1, true))
  end
  assert(choices and #choices == 3)
  for i, level in ipairs({ "Basic", "Intermediate", "Advanced" }) do
    assert(choices[i].text == level and choices[i].radio)
    choices[i].callback()
    assert(configuration.word_wise_level == level and choices[i].checked_func())
  end
end)

test("unsupported documents do not install hooks or schedule requests", function()
  local ui = make_ui(document({ { "word" } }))
  for _, file in ipairs({ "book.pdf", "book.djvu", "book.txt" }) do
    ui.document.file = file
    assert(not WordWise.new { ui = ui })
  end
  ui.document.file, ui.document.getNextVisibleWordEnd = "book.epub", false
  assert(not WordWise.new { ui = ui })
  assert(not next(scheduled) and not next(ui.view.view_modules))
end)

test("Word Wise model setting is optional, editable and saved as a string", function()
  assert(Config.normalize({}).word_wise_model == "")
  for _, invalid in ipairs({ false, {}, 12, " \t ", "bad\nmodel" }) do
    assert(Config.normalize({ word_wise_model = invalid }).word_wise_model == "")
  end
  local model = "deepseek/deepseek-v4.1-flash"
  local normalized = Config.normalize({ word_wise_model = "  " .. model .. "  " })
  assert(normalized.word_wise_model == model)
  local saved = assert(loadstring(Config.serialize_configuration(normalized)))()
  assert(saved.word_wise_model == model)
  assert(Config.display_value("word_wise_model", "") == "Use text model")
  local edited
  local items = require("settings_menu").get_items({
    editConfigurationValue = function(_, key, literal) edited = { key = key, literal = literal } end,
  })
  for _, item in ipairs(items) do
    if item.text == "Word Wise model: Use text model" then item.callback() end
  end
  assert(edited and edited.key == "word_wise_model" and edited.literal == false)
end)

test("Word Wise model changes retain reasoning and invalidate page results", function()
  configuration.text_model = "google/gemini-2.5-flash"
  configuration.word_wise_model = "deepseek/deepseek-v4.1-flash"
  local controller, ui = start(); drain()
  assert(requests[1].callbacks.model == configuration.word_wise_model)
  assert(requests[1].callbacks.reasoning_effort == "low")
  assert(requests[1].callbacks.provider_sort == "price")
  complete(requests[1])

  configuration.word_wise_model = "another-model"
  controller:settings_changed(); drain()
  assert(#requests == 2 and #controller.overlay.boxes == 0)
  assert(requests[2].callbacks.model == "another-model" and requests[2].callbacks.reasoning_effort == "low")
  configuration.word_wise_model = ""
  controller:settings_changed()
  assert(requests[2].cancels == 1)
  complete(requests[2]); assert(#controller.overlay.boxes == 0)
  drain()
  assert(requests[3].callbacks.model == "" and requests[3].callbacks.reasoning_effort == "low")
  assert(configuration.text_model == "google/gemini-2.5-flash")
  complete(requests[3])

  -- Direct configuration-file edits also keep results from different models apart.
  ui.document.page = 2; controller:refresh(); drain(); complete(requests[4])
  configuration.word_wise_model = "a-new-model"
  ui.document.page = 1; controller:refresh(); drain()
  assert(#requests == 5 and requests[5].callbacks.model == "a-new-model")
  controller:close()
end)

test("visible extraction keeps first and last words and exact occurrences", function()
  local doc = document({ { "bear", "give", "way", "bear" }, { "unseen" } })
  local page = Page.new(make_ui(doc))
  assert(not Page.step(doc, page, 2) and #page.words == 2)
  assert(not Page.step(doc, page, 2) and #page.words == 4)
  assert(Page.step(doc, page, 2) and #page.words == 4)
  assert(page.words[1].pos0 == "1s" and page.words[4].pos1 == "4e")
  assert(Page.context(doc, page) == "bear give way bear")
  doc.page = 2
  page = Page.new(make_ui(doc))
  assert(Page.step(doc, page, 24) and #page.words == 1) -- final book page
end)

test("parser validates definitions, phrase spans, overlap and repeated words", function()
  local doc = document({ { "bear", "give", "way", "bear" } })
  local page = Page.new(make_ui(doc)); assert(Page.step(doc, page, 24))
  decoded.valid = { entries = {
    { first = 2, last = 3, meaning = "  stop\nresisting " },
    { first = 1, last = 1, meaning = "forest animal" },
    { first = 4, last = 4, meaning = "endure" },
    { first = 2, last = 2, meaning = "overlap" },
    { first = 5, last = 5, meaning = "out of bounds" },
    { first = 1.5, last = 2, meaning = "fraction" },
    { first = 1, last = 1, meaning = "one two three four five six" },
  } }
  local entries = assert(Prompt.parse("```json\nvalid\n```", page.words))
  assert(#entries == 3 and entries[1].meaning == "stop resisting")
  assert(entries[1].pos0 == "2s" and entries[1].pos1 == "3e")
  assert(entries[2].pos0 == "1s" and entries[3].pos0 == "4s")
  assert(not Prompt.parse("malformed", page.words))
  assert(not Prompt.parse(string.rep("x", 65537), page.words))
  assert(not Prompt.validate({ entries = { first = 1, last = 1, meaning = "wrong shape" } }, page.words))
  assert(not Prompt.validate({ entries = { { first = -1, last = 1, meaning = "bad" } } }, page.words))
  assert(not Prompt.validate({ entries = { { first = 1, last = 1, meaning = "one two three four five six" } } }, page.words))
  assert(#assert(Prompt.validate({ entries = {} }, page.words)) == 0)
  local messages = Prompt.messages(page, "context", "Basic", "Persian")
  assert(messages[1].content:find("Persian", 1, true) and messages[1].content:find("basic proficiency", 1, true))
  assert(encoded.tokens[4].id == 4 and encoded.tokens[4].text == "bear")
end)

test("page turns debounce scans, retain active requests and cache offscreen results", function()
  local controller, ui = start()
  ui.document.page = 2; controller:refresh()
  assert(#requests == 0)
  drain(); assert(#requests == 1 and requests[1].page.tokens[1].text == "rare")
  local old = requests[1]
  ui.document.page = 1; controller:refresh()
  assert(old.cancels == 0 and #controller.overlay.boxes == 0)
  drain(); assert(#requests == 2)
  complete(old); assert(#controller.overlay.boxes == 0)
  complete(requests[2]); assert(#controller.overlay.boxes == 1)
  assert(not next(controller.requests.jobs))
  controller:refresh(); drain(); assert(#requests == 2)
  ui.document.page = 2; controller:refresh(); drain()
  assert(#requests == 2 and #controller.overlay.boxes == 1, "offscreen results must be cached")
  ui.document.page = 1; controller:refresh(); drain()
  assert(#requests == 2 and #controller.overlay.boxes == 1, "completed page should use memory cache")
  controller:close()
end)

test("prefetch queries pages sequentially and stops two pages ahead", function()
  local controller, ui = start(many_pages(5)); drain()
  assert(#requests == 1 and requests[1].page.tokens[1].text == "page1")
  complete(requests[1]); drain()
  assert(#requests == 2 and requests[2].page.tokens[1].text == "page2")
  assert(ui.document.page == 1 and requests[2].callbacks.reasoning_effort == "low")
  assert(requests[2].callbacks.provider_sort == "price")
  assert(#controller.overlay.boxes == 1 and controller.overlay.boxes[1].entry.pos0 == "1s")
  complete(requests[2]); drain()
  assert(#requests == 3 and requests[3].page.tokens[1].text == "page3")
  assert(active_count(controller) == 1 and ui.document.page == 1)
  complete(requests[3]); drain()
  assert(#requests == 3 and active_count(controller) == 0, "stop after two pages of lookahead")
  assert(controller.overlay.boxes[1].entry.pos0 == "1s", "prefetch must not paint offscreen entries")
  ui.document.page = 2; controller:refresh()
  assert(controller.overlay.boxes[1].entry.pos0 == "2s", "prefetched results display immediately")
  drain(); assert(#requests == 4 and requests[4].page.tokens[1].text == "page4")
  turn(controller, ui, 3)
  assert(#requests == 4, "wait for the nearer active page before requesting page5")
  -- Turning into an active prefetch attaches to it instead of making a duplicate.
  turn(controller, ui, 4)
  assert(#requests == 4 and requests[4].cancels == 0)
  complete(requests[4]); drain()
  assert(#requests == 5 and requests[5].page.tokens[1].text == "page5")
  assert(controller.overlay.boxes[1].entry.pos0 == "4s")
  turn(controller, ui, 5); complete(requests[5]); drain()
  assert(#requests == 5 and active_count(controller) == 0, "stop at end of book")
  controller:close()
end)

test("five active requests are retained and the farthest is replaced after navigation", function()
  local controller, ui = start(many_pages(12)); drain()
  for page = 2, 5 do
    turn(controller, ui, page)
    assert(active_count(controller) == page)
  end
  for _, request in ipairs(requests) do assert(request.cancels == 0) end
  local evicted = requests[1]
  evicted.on_cancel = function() complete(evicted) end
  turn(controller, ui, 6)
  assert(#requests == 6 and active_count(controller) == 5 and evicted.cancels == 1)
  complete(evicted); assert(#controller.overlay.boxes == 0)
  for i = 2, 6 do assert(requests[i].cancels == 0) end
  -- The farthest is recalculated from the new reading position, not request age.
  turn(controller, ui, 1)
  assert(#requests == 7 and requests[6].cancels == 1 and active_count(controller) == 5)
  complete(requests[6]); assert(#controller.overlay.boxes == 0)
  assert(requests[7].page.tokens[1].text == "page1")
  complete(requests[2]); drain()
  assert(#controller.overlay.boxes == 0 and active_count(controller) == 4)
  turn(controller, ui, 2)
  assert(#requests == 7 and controller.overlay.boxes[1].entry.pos0 == "2s")
  complete(requests[7]); drain()
  assert(controller.overlay.boxes[1].entry.pos0 == "2s", "late nearby results only update the cache")
  controller:close()
end)

test("priority protects nearer work, and cancel callbacks cannot release replacement jobs", function()
  local pool = require("word_wise_requests").new(2)
  local first = assert(pool:reserve("first", 10, 10))
  local second = assert(pool:reserve("second", 11, 10))
  assert(not pool:reserve("distant", 20, 10))
  assert(not pool:reserve("first", 10, 10))
  first.cancel = function() assert(not pool:remove(first)) end
  assert(pool:reserve("replacement", 12, 12))
  assert(not pool.jobs.first and pool.jobs.second == second)
  assert(not pool:remove(first))
  local replacement = assert(pool:reserve("first", 10, 10))
  assert(not pool:remove(first) and pool.jobs.first == replacement)
  pool:cancel_all(); assert(not next(pool.jobs))
end)

test("cached current pages prefetch the next page even with five other queries active", function()
  local controller, ui = start(many_pages(10)); drain(); complete(requests[1])
  -- Navigate before the page-2 prefetch starts, leaving a gap to fill on return.
  for page = 3, 7 do turn(controller, ui, page) end
  assert(active_count(controller) == 5 and #requests == 6)
  turn(controller, ui, 1)
  assert(#requests == 7 and requests[7].page.tokens[1].text == "page2")
  assert(requests[6].cancels == 1 and requests[2].cancels == 0)
  assert(active_count(controller) == 5 and controller.overlay.boxes[1].entry.pos0 == "1s")
  controller:close()
end)

test("prefetch completion on arrival starts read-ahead immediately and resume retains cache", function()
  local controller, ui = start(many_pages(4)); drain(); complete(requests[1]); drain()
  ui.document.page = 2; controller:refresh()
  assert(scheduled[controller.pending] == 0.6)
  complete(requests[2])
  assert(scheduled[controller.pending] == 0, "completion must not wait for the settle timer")
  drain(); assert(#requests == 3)
  controller:suspend(); assert(requests[3].cancels == 1)
  controller:resume()
  assert(controller.overlay.boxes[1].entry.pos0 == "2s")
  drain()
  assert(#requests == 4 and requests[4].page.tokens[1].text == "page3")
  controller:close()
end)

test("page ranges prefetch whole spreads, honor hidden flows and keep scroll extraction", function()
  local doc = document(many_pages(5))
  local ui = make_ui(doc)
  doc.visible_pages = 2
  local target = Page.target(ui)
  assert(target.number == 1 and target.last == 2)
  target = Page.following(ui, target)
  assert(target.number == 3 and target.last == 4)
  local page = Page.new(ui, target)
  assert(Page.step(doc, page) and #page.words == 2 and page.words[1].text == "page3")
  assert(doc.page == 1)
  doc.getNextPage = function(_, p) return p == 2 and 5 or 0 end
  target = Page.following(ui, Page.target(ui))
  assert(target.number == 5 and target.last == 5)
  assert(not Page.following(ui, target))
  ui.view.view_mode = "scroll"
  target = Page.target(ui)
  assert(not target.last and not Page.following(ui, target))
  page = Page.new(ui, target)
  assert(Page.step(doc, page) and #page.words == 1 and page.words[1].text == "page1")
end)

test("selection pauses offscreen prefetch and navigation gives the visible scan priority", function()
  local pages = many_pages(4)
  for i = 2, 60 do pages[2][i] = "word" .. i end
  local controller, ui = start(pages); drain(); complete(requests[1])
  ui.highlight.selected_text, ui.document.selection_active = {}, true
  local reads = ui.document.reads
  tick(); assert(ui.document.reads == reads and #requests == 1)
  ui.highlight.selected_text, ui.document.selection_active = nil, false
  tick(); assert(ui.document.reads == reads + 24 and #requests == 1)
  turn(controller, ui, 3)
  assert(#requests == 2 and requests[2].page.tokens[1].text == "page3")
  complete(requests[2]); drain()
  assert(#requests == 3 and requests[3].page.tokens[1].text == "page4")
  controller:close()
end)

test("selection pauses extraction before and between batches", function()
  local words = {}; for i = 1, 60 do words[i] = "word" .. i end
  local controller, ui = start({ words, { "next" } })
  ui.highlight.selected_text = {}; ui.document.selection_active = true
  tick(); assert(ui.document.reads == 0 and #requests == 0)
  ui.highlight.selected_text = nil; ui.document.selection_active = false
  tick(); local reads = ui.document.reads
  assert(reads == 24 and #requests == 0)
  ui.highlight.hold_pos = {}; ui.document.selection_active = true
  tick(); assert(ui.document.reads == reads and #requests == 0)
  ui.highlight.hold_pos = nil; ui.document.selection_active = false
  ui.document.page = 2; controller:refresh(); drain()
  assert(#requests == 1 and #requests[1].page.tokens == 1)
  controller:close()
end)

test("tap bubbles preserve native taps, saved highlights and long presses", function()
  local controller, ui = start(); drain(); complete(requests[1])
  local gesture = { pos = { x = 15, y = 110 } }
  assert(ui.highlight:onTap(nil, gesture) == true and controller.overlay.popup)
  local hold_gesture = { pos = { x = 15, y = 110 } }
  assert(ui.highlight:onHold("argument", hold_gesture) == "native hold")
  assert(not controller.overlay.popup and ui.highlight.native_holds == 1)
  assert(ui.highlight.last_hold[1] == "argument" and ui.highlight.last_hold[2] == hold_gesture)
  ui.highlight.hold_pos = nil; ui.document.selection_active = false
  ui.highlight.native_handled = "saved highlight"
  assert(ui.highlight:onTap(nil, gesture) == "saved highlight" and not controller.overlay.popup)
  ui.highlight.native_handled = nil
  assert(not ui.highlight:onTap(nil, { pos = { x = 500, y = 500 } }))
  controller:close()
end)

test("an outside tap dismisses the bubble before other reader tap zones", function()
  local controller, ui = start(); drain(); complete(requests[1])
  assert(requests[1].callbacks.reasoning_effort == "low")
  local word = { pos = { x = 15, y = 110 } }
  local outside = { pos = { x = 500, y = 500 } }
  assert(ui.highlight:onTap(nil, word) and controller.overlay.popup)
  local zone = assert(ui._zones.ai_dictionary_word_wise_popup_tap)
  local overrides = {}
  for _, id in ipairs(zone.def.overrides) do overrides[id] = true end
  assert(overrides.readerhighlight_tap and overrides.readerlink_tap
    and overrides.readermenu_tap and overrides.tap_forward)
  assert(not overrides.readerhighlight_hold and zone.def.ges == "tap")
  assert(zone.def.screen_zone.ratio_w == 1 and zone.def.screen_zone.ratio_h == 1)
  local repaints = UI.repaints
  assert(zone.handler(outside) == true and not controller.overlay.popup)
  assert(UI.repaints > repaints, "dismissal must erase the painted bubble")
  assert(not zone.handler(outside), "normal reader taps must pass through when no bubble is open")

  -- Even the highlight-wrapper fallback must dismiss before a saved highlight.
  assert(ui.highlight:onTap(nil, word))
  ui.highlight.native_handled = "saved highlight"
  assert(ui.highlight:onTap(nil, outside) == true and not controller.overlay.popup)
  assert(ui.highlight:onTap(nil, outside) == "saved highlight")
  ui.highlight.native_handled = nil

  -- A later-installed zone is covered when the next bubble opens.
  ui._zones.custom_tap = { def = { ges = "tap" } }
  assert(ui.highlight:onTap(nil, word))
  zone = ui._zones.ai_dictionary_word_wise_popup_tap
  local found
  for _, id in ipairs(zone.def.overrides) do if id == "custom_tap" then found = true end end
  assert(found)
  assert(zone.handler(word) == true and controller.overlay.popup, "marked-word taps can switch definitions")
  controller:close()
  assert(not ui._zones.ai_dictionary_word_wise_popup_tap and ui._zones.readerlink_tap)
end)

test("wrapped phrase boxes are clipped and bad geometry is isolated", function()
  local doc = document({ { "give", "way" } })
  local entry = { pos0 = "1s", pos1 = "2e", meaning = "stop resisting" }
  doc.boxes = {
    { x = 550, y = 100, w = 80, h = 20 }, { x = 10, y = 125, w = 30, h = 20 },
    { x = -80, y = 100, w = 20, h = 20 }, { x = 10, y = 900, w = 20, h = 20 },
  }
  local boxes = Page.boxes(doc, { entry }, 600, 800)
  assert(#boxes == 2 and boxes[1].box.w == 50 and boxes[1].entry == boxes[2].entry)
  doc.box_error = true; assert(#Page.boxes(doc, { entry }, 600, 800) == 0)
end)

test("bubble placement respects scaled screen padding and painting does not query or select", function()
  local view = View.new()
  local entry = { meaning = "very lengthy contextual vocabulary definition" }
  -- The screen gap is deliberately tunable in the script, not fixed by this test.
  local view_file = assert(io.open("./AI_Dictionary.koplugin/word_wise_view.lua", "r"))
  local view_source = view_file:read("*a")
  view_file:close()
  local popup_padding = assert(tonumber(view_source:match("local POPUP_SCREEN_PADDING%s*=%s*(%d+)")))
  for _, scale in ipairs({ 1, 2 }) do
    screen.scale = scale
    local gap = popup_padding * scale
    for _, box in ipairs({
      { x = 0, y = 0, w = 20, h = 20 }, { x = 580, y = 0, w = 20, h = 20 },
      { x = 0, y = 775, w = 20, h = 20 }, { x = 580, y = 775, w = 20, h = 20 },
    }) do
      view.boxes = { { box = box, entry = entry } }
      assert(view:tap({ x = box.x + 1, y = box.y + 1 }))
      local bubble = view.popup
      assert(bubble.x >= gap and bubble.y >= gap
        and bubble.x + bubble.w <= 600 - gap and bubble.y + bubble.h <= 800 - gap)
      assert(box.x == 0 and bubble.x == gap or box.x == 580 and bubble.x + bubble.w == 600 - gap)
      view:paint({ paintRect = function(_, x, y, w, h, color)
        assert(x >= 0 and y >= 0 and x + w <= 600 and y + h <= 800)
        if color ~= package.loaded["ffi/blitbuffer"].COLOR_GRAY then
          assert(x >= gap and y >= gap and x + w <= 600 - gap and y + h <= 800 - gap,
            "the popup tail must also respect the screen padding")
        end
        draws[#draws + 1] = { x, y, w, h }
      end }, 0, 0)
      assert(view:tap({ x = bubble.x + 1, y = bubble.y + 1 }) and not view.popup)
    end
  end
  screen.scale = nil
  assert(#draws > 0 and frees > 0 and #requests == 0)
  view.boxes = { { box = { x = 0, y = 0, w = 20, h = 1 }, entry = entry } }
  view:paint({ paintRect = function() error("clipped text has no visible underline") end }, 0, 0)
end)

test("settings and reflow invalidate pending responses and cached geometry", function()
  local controller, ui = start(); drain()
  configuration.word_wise_level, configuration.output_language = "Advanced", "French"
  controller:settings_changed()
  complete(requests[1]); assert(#controller.overlay.boxes == 0)
  drain(); assert(#requests == 2)
  assert(requests[2].messages[1].content:find("French", 1, true))
  assert(requests[2].messages[1].content:find("advanced proficiency", 1, true))
  complete(requests[2]); assert(#controller.overlay.boxes == 1)
  ui.document.hash = 2
  controller:paint({ paintRect = function() error("old boxes painted") end }, 0, 0)
  assert(#controller.overlay.boxes == 0)
  drain(); assert(#requests == 3)
  controller:close()
end)

test("settings, reflow, suspend and close cancel every active query and reject late results", function()
  for _, action in ipairs({ "settings", "reflow", "suspend", "close" }) do
    local first = #requests + 1
    local controller, ui = start(many_pages(6)); drain()
    for page = 2, 5 do turn(controller, ui, page) end
    assert(active_count(controller) == 5)
    if action == "settings" then
      controller:settings_changed()
    elseif action == "reflow" then
      ui.document.hash = ui.document.hash + 1
      controller:refresh()
    else
      controller[action](controller)
    end
    assert(active_count(controller) == 0)
    for i = first, first + 4 do
      assert(requests[i].cancels == 1)
      complete(requests[i])
    end
    assert(#controller.overlay.boxes == 0 and not next(controller.cache))
    controller:close()
    assert(not next(scheduled))
  end
end)

test("blank pages and synchronous startup failures do not stall or loop prefetch", function()
  local controller, ui = start({ {}, { "word" }, {} }); drain()
  assert(#requests == 1 and requests[1].page.tokens[1].text == "word" and ui.document.page == 1)
  complete(requests[1]); drain()
  turn(controller, ui, 2)
  assert(#requests == 1 and #controller.overlay.boxes == 1)
  turn(controller, ui, 3)
  assert(#requests == 1 and #controller.overlay.boxes == 0)
  controller:close()

  requests.start_error = true
  controller = start(many_pages(4)); drain()
  assert(#requests == 4 and active_count(controller) == 0 and not next(scheduled))
  controller:close()
end)

test("empty pages cache, failures stay quiet, and page revisits can retry", function()
  local controller, ui = start(); drain(); complete(requests[1], {})
  ui.document.page = 2; controller:refresh(); drain()
  requests[2].callbacks.on_error("offline")
  drain()
  assert(#controller.overlay.boxes == 0 and not next(scheduled))
  ui.document.page = 1; controller:refresh(); drain(); assert(#requests == 3)
  ui.document.page = 2; controller:refresh(); drain(); assert(#requests == 3)
  requests[3].callbacks.on_done("malformed")
  assert(#controller.overlay.boxes == 0)
  controller:close()
  requests.synchronous_error = true
  controller = start(); drain()
  assert(not next(controller.requests.jobs) and #requests == 5)
  controller:close()
end)

test("suspend, resume and close clean up requests, hooks, cache and timers", function()
  local controller, ui = start(); drain()
  local tap, hold = controller.original_tap, controller.original_hold
  controller:suspend(); assert(requests[1].cancels == 1 and not next(scheduled))
  complete(requests[1]); assert(#controller.overlay.boxes == 0)
  controller:resume(); drain(); assert(#requests == 2)
  complete(requests[2])
  for i = 1, 20 do controller:remember(tostring(i), {}) end
  assert(#controller.cache_order == 16 and not controller.cache["1"])
  controller:close(); controller:close()
  assert(not next(controller.cache) and not next(ui.view.view_modules) and not next(scheduled))
  assert(ui.highlight.onTap == tap and ui.highlight.onHold == hold)
  controller, ui = start()
  local later_wrapper = function() return "another plugin" end
  ui.highlight.onTap = later_wrapper
  controller:close(); assert(ui.highlight.onTap == later_wrapper)
end)

for _, spec in ipairs(tests) do
  errors, warnings, requests, scheduled, decoded = {}, {}, {}, {}, {}
  configuration = { output_language = "English", word_wise_level = "Intermediate" }
  local ok, err = xpcall(spec[2], debug.traceback)
  assert(ok, spec[1] .. "\n" .. tostring(err))
  assert(#errors == 0, spec[1] .. "\n" .. table.concat(errors, "\n"))
  assert(not next(scheduled), spec[1] .. ": leaked scheduled work")
  print("PASS: " .. spec[1])
end
print("Word Wise: " .. #tests .. " isolated checks passed")
