-- Run from the repository root: luajit tests/word_sense_spec.lua
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
package.loaded["ui/geometry"] = { new = function(_, value) return value or {} end }
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
  if requests.synchronous_success then
    decoded.response = { entries = { { first = 1, last = 1, meaning = "simple meaning" } } }
    callbacks.on_done("response")
  end
  return function()
    request.cancels = request.cancels + 1
    -- Some transports can still dispatch callbacks when being cancelled.
    if request.on_cancel then request.on_cancel() end
  end
end

local Config = require("configuration_manager")
local configuration
Config.load = function() return Config.normalize(configuration) end
local Page = require("word_sense_page")
local Prompt = require("word_sense_prompt")
local View = require("word_sense_view")
local WordSense = require("word_sense")
local Chunk = require("word_sense_chunk")
local Reflowable = require("word_sense_reflowable")
local Fixed = require("word_sense_fixed")
local Source = require("word_sense_source")
local Cache = require("word_sense_cache")

local function pointer(index, ending) return tostring(index) .. (ending and "e" or "s") end
local function index_of(xp) return tonumber(xp:match("^(%d+)")) end
local function document(pages)
  local doc = { file = "book.EPUB", page = 1, hash = 1, texts = {}, ranges = {}, reads = 0, breaks = {} }
  for i, words in ipairs(pages) do
    doc.ranges[i] = { first = #doc.texts + 1 }
    doc.breaks[#doc.texts + 1] = true
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
  function doc:getPrevVisibleWordEnd(xp)
    local index = index_of(xp) - 1
    if index >= 1 then return pointer(index, true) end
  end
  function doc:compareXPointers(a, b)
    local av = index_of(a) * 2 + (a:sub(-1) == "e" and 1 or 0)
    local bv = index_of(b) * 2 + (b:sub(-1) == "e" and 1 or 0)
    return av < bv and 1 or av > bv and -1 or 0
  end
  function doc:isXPointerInCurrentPage(xp)
    local index, range = index_of(xp), self.ranges[self.page]
    return index >= range.first and index <= range.last
  end
  function doc:getTextFromXPointers(a, b)
    assert(not self.selection_active, "extraction must never clear a live selection")
    self.reads = self.reads + 1
    local text = {}
    for i = index_of(a), index_of(b) do
      if #text > 0 then text[#text + 1] = self.breaks[i] and "\n" or (self.joiners and self.joiners[i] or " ") end
      text[#text + 1] = self.texts[i]
    end
    return table.concat(text)
  end
  function doc:getScreenBoxesFromPositions(a, b)
    self.last_boxes = { a, b }
    if self.box_error then error("bad geometry") end
    if self.boxes then return self.boxes end
    local range = self.ranges[self.page]
    local offset = math.max(0, index_of(a) - range.first)
    return { { x = (offset % 50 + 1) * 10, y = 100 + math.floor(offset / 50) * 24,
      w = (index_of(b) - index_of(a) + 1) * 20, h = 20 } }
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
  local controller = assert(WordSense.new { ui = ui })
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
  assert(Config.normalize({}).word_sense_level == "Intermediate")
  assert(Config.normalize({ word_sense_level = "invalid" }).word_sense_level == "Intermediate")
  local plugin = { saveConfiguration = function(_, config) configuration = config; return true end }
  local items = require("settings_menu").get_items(plugin)
  local choices
  for _, item in ipairs(items) do
    if item.text:find("Word Sense reading level", 1, true) then choices = item.sub_item_table end
    assert(not item.text:find("Enable Word Sense", 1, true))
  end
  assert(choices and #choices == 3)
  for i, level in ipairs({ "Basic", "Intermediate", "Advanced" }) do
    assert(choices[i].text == level and choices[i].radio)
    choices[i].callback()
    assert(configuration.word_sense_level == level and choices[i].checked_func())
  end
end)

test("unsupported documents do not install hooks or schedule requests", function()
  local ui = make_ui(document({ { "word" } }))
  for _, file in ipairs({ "book.fb2", "book.azw", "book.cbz", "book.epub.zip", "book.epub.tmp", "book" }) do
    ui.document.file = file
    assert(not WordSense.new { ui = ui })
  end
  ui.document.file, ui.document.getNextVisibleWordEnd = "book.epub", false
  assert(not WordSense.new { ui = ui })
  assert(not next(scheduled) and not next(ui.view.view_modules))
end)

test("Word Sense model setting is optional, editable and saved as a string", function()
  assert(Config.normalize({}).word_sense_model == "")
  for _, invalid in ipairs({ false, {}, 12, " \t ", "bad\nmodel" }) do
    assert(Config.normalize({ word_sense_model = invalid }).word_sense_model == "")
  end
  local model = "deepseek/deepseek-v4.1-flash"
  local normalized = Config.normalize({ word_sense_model = "  " .. model .. "  " })
  assert(normalized.word_sense_model == model)
  local saved = assert(loadstring(Config.serialize_configuration(normalized)))()
  assert(saved.word_sense_model == model)
  assert(Config.display_value("word_sense_model", "") == "Use text model")
  local edited
  local items = require("settings_menu").get_items({
    editConfigurationValue = function(_, key, literal) edited = { key = key, literal = literal } end,
  })
  for _, item in ipairs(items) do
    if item.text == "Word Sense model: Use text model" then item.callback() end
  end
  assert(edited and edited.key == "word_sense_model" and edited.literal == false)
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

test("priority protects nearer work, and cancel callbacks cannot release replacement jobs", function()
  local pool = require("word_sense_requests").new(2)
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
  local zone = assert(ui._zones.ai_dictionary_word_sense_popup_tap)
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
  zone = ui._zones.ai_dictionary_word_sense_popup_tap
  local found
  for _, id in ipairs(zone.def.overrides) do if id == "custom_tap" then found = true end end
  assert(found)
  assert(zone.handler(word) == true and controller.overlay.popup, "marked-word taps can switch definitions")
  controller:close()
  assert(not ui._zones.ai_dictionary_word_sense_popup_tap and ui._zones.readerlink_tap)
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
  local view_file = assert(io.open("./AI_Dictionary.koplugin/word_sense_view.lua", "r"))
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

-- Chunk and document-range lifecycle regression checks.

local function vocabulary(count, prefix)
  local words = {}
  for i = 1, count do words[i] = (prefix or "word") .. i end
  return words
end

local function chunk_at(doc, index)
  local source = Reflowable.new(make_ui(doc))
  local chunk = Chunk.new(source, assert(source:word(pointer(index, true))))
  for _ = 1, 10000 do
    local done, err = Chunk.step(chunk)
    assert(not err, err)
    if done then return chunk end
  end
  error("chunk extraction stalled")
end

local function paragraph_pages(count)
  local pages = {}
  for i = 1, count do pages[i] = vocabulary(301, "p" .. i .. "w") end
  return pages
end

local function ready(pages)
  local controller, ui = start(pages or paragraph_pages(5))
  drain()
  return controller, ui
end

test("eligible reflowable formats share extraction caching and layout handling", function()
  for _, file in ipairs({ "book.epub", "book.EPUB", "book.epub3", "book.EPUB3",
    "book.kepub", "book.KEPUB", "book.kepub.epub", "book.KEPUB.EPUB",
    "book.mobi", "book.MOBI", "book.txt", "book.TXT", "book.htm", "book.HTM",
    "book.html", "book.HTML", "book.xhtml", "book.XHTML" }) do
    local doc = document({ { "difficult", "give", "way" } })
    doc.file = file
    local ui = make_ui(doc)
    local before = #requests
    local controller = assert(WordSense.new { ui = ui }, file)
    assert(getmetatable(controller.source) == Reflowable, file)
    controller:refresh(); drain()
    assert(#requests == before + 1 and #requests[#requests].page.tokens == 3, file)
    complete(requests[#requests], { { first = 2, last = 3, meaning = "stop resisting" } }); drain()
    assert(#controller.overlay.boxes == 1 and controller.overlay.boxes[1].entry.pos0 == "2s", file)
    doc.hash = 2
    controller:layout_changed(); drain()
    assert(#requests == before + 1 and #controller.overlay.boxes == 1, file)
    controller:close()
  end
end)

test("eligible extensions do not bypass missing text or view capabilities", function()
  for _, method in ipairs({ "getNextVisibleWordEnd", "getPrevVisibleWordEnd",
    "getPageFromXPointer", "compareXPointers", "getTextFromXPointers", "getScreenBoxesFromPositions" }) do
    local ui = make_ui(document({ { "word" } }))
    ui.document.file = "book.mobi"
    ui.document[method] = false
    assert(not Source.new(ui) and not WordSense.new { ui = ui }, method)
    assert(not next(ui.view.view_modules))
  end
  local ui = make_ui(document({ { "word" } }))
  ui.document.file = "book.kepub"
  ui.view.registerViewModule = false
  assert(not Source.new(ui))
  assert(not Source.new(nil) and not Source.new({}) and not Source.new({ document = {} }))
  assert(#requests == 0 and not next(scheduled))
end)

local function settle()
  for _ = 1, 100 do
    drain()
    local active
    for _, request in ipairs(requests) do
      if not request.done and request.cancels == 0 then active = request; break end
    end
    if not active then return end
    active.done = true
    complete(active)
  end
  error("request loop")
end

test("chunks include full paragraphs until strictly over 300 words", function()
  local doc = document({ vocabulary(150), vocabulary(150), { "extra" }, { "excluded" } })
  local chunk = chunk_at(doc, 1)
  assert(chunk.count == 301 and #chunk.words == 301 and chunk.pos1 == "301e")
  assert(chunk.context:find("\n", 1, true) and not chunk.context:find("excluded", 1, true))
  doc = document({ vocabulary(125), vocabulary(125), vocabulary(125), { "excluded" } })
  chunk = chunk_at(doc, 1)
  assert(chunk.count == 375 and #chunk.words == 375)
  -- A short final book passage still includes its one complete paragraph.
  chunk = chunk_at(document({ { "last", "paragraph" } }), 2)
  assert(chunk.count == 2 and chunk.pos0 == "1s")
end)

test("one oversized paragraph is never split at a word or page limit", function()
  local doc = document({ vocabulary(1600), { "excluded" } })
  local chunk = chunk_at(doc, 900)
  assert(chunk.count == 1600 and #chunk.words == 1600)
  assert(chunk.pos0 == "1s" and chunk.pos1 == "1600e")
end)

test("inline formatting fragments do not inflate the 300-word threshold", function()
  local first = { "hel", "lo" }
  for i = 1, 299 do first[#first + 1] = "word" .. i end
  local doc = document({ first, { "extra" }, { "excluded" } })
  doc.joiners = { [2] = "" }
  local chunk = chunk_at(doc, 1)
  assert(chunk.count == 301 and #chunk.words == 302)
  assert(chunk.context:sub(1, 5) == "hello" and chunk.pos1 == "302e")
end)

test("a paragraph spanning displayed pages is analyzed once with full context", function()
  local controller, ui = start({ { "give" }, { "way" }, vocabulary(301), { "after" } })
  ui.document.breaks[2], ui.document.breaks[3] = nil, nil
  drain()
  assert(#requests == 1 and #requests[1].page.tokens == 303)
  complete(requests[1], { { first = 1, last = 2, meaning = "stop resisting" } })
  drain() -- the next chunk is a separate query
  assert(#requests == 2)
  local scans = #requests
  turn(controller, ui, 2)
  assert(#requests == scans and #controller.overlay.boxes > 0)
  assert(controller.overlay.boxes[1].entry.pos0 == "1s" and controller.overlay.boxes[1].entry.pos1 == "2e")
  turn(controller, ui, 3)
  assert(#requests == scans, "reuse the whole paragraph on its third displayed page")
  controller:close()
end)

test("phrases spanning multiple pages remain visible between their endpoints", function()
  local doc = document({ { "a" }, { "long" }, { "phrase" } })
  doc.page = 2
  local source = Reflowable.new(make_ui(doc))
  local boxes = source:boxes({ { pos0 = "1s", pos1 = "3e", meaning = "simple meaning" } }, 600, 800)
  assert(#boxes == 1, "the middle page also needs the phrase underline")
end)

test("long paragraphs receive current-page priority even when starting far behind it", function()
  local controller, ui = start(many_pages(10))
  ui.document.page = 8
  assert(controller:priority_page({ pos0 = "1s", pos1 = "8e" }) == 8)
  assert(controller:priority_page({ pos0 = "9s", pos1 = "10e" }) == 9)
  assert(controller:priority_page({ pos0 = "1s", pos1 = "3e" }) == 3)
  controller:close()
end)

test("prefetch processes two chunks sequentially without turning pages", function()
  local controller, ui = ready()
  assert(#requests == 1 and #requests[1].page.tokens == 301)
  complete(requests[1]); drain(); assert(#requests == 2)
  complete(requests[2]); drain(); assert(#requests == 3)
  complete(requests[3]); drain()
  assert(#requests == 3 and active_count(controller) == 0 and ui.document.page == 1)
  assert(#controller.overlay.boxes == 1)
  turn(controller, ui, 2)
  assert(#controller.overlay.boxes == 1 and #requests == 4)
  assert(requests[4].page.tokens[1].text == "p4w1")
  controller:close()
end)

test("every visible chunk is processed before speculative chunks", function()
  local controller, ui = start({ vocabulary(903), vocabulary(301) })
  ui.document.breaks[302], ui.document.breaks[603] = true, true
  drain()
  assert(#requests[1].page.tokens == 301)
  complete(requests[1]); drain()
  assert(requests[2].page.tokens[1].text == "word302")
  complete(requests[2]); drain()
  assert(requests[3].page.tokens[1].text == "word603")
  complete(requests[3]); drain()
  assert(requests[4].page.tokens[1].text == "word1" and #controller.overlay.boxes == 3)
  controller:close()
end)

test("more than 40 pages remain annotated through repeated cache evictions", function()
  local controller, ui = ready(paragraph_pages(45))
  for page = 1, 43 do
    turn(controller, ui, page)
    settle()
    assert(#controller.overlay.boxes == 1, "missing visible definition on page " .. page)
    assert(controller.overlay.boxes[1].entry.pos0 == pointer(ui.document.ranges[page].first))
    assert(#controller.cache.order <= 16)
  end
  local count = #requests
  turn(controller, ui, 1); settle()
  assert(#requests > count and #controller.overlay.boxes == 1, "evicted content must query again")
  controller:close()
end)

test("cache uses recent access and protects visible ranges from late results", function()
  local source = Reflowable.new(make_ui(document({ vocabulary(30) })))
  local cache = Cache.new(16, source)
  local function put(i, protected)
    cache:put({ id = pointer(i), pos0 = pointer(i), pos1 = pointer(i, true) }, {}, protected)
  end
  for i = 1, 16 do put(i) end
  assert(cache:find({ pos0 = "1s", pos1 = "1e" }))
  put(17)
  assert(cache.records["1s"] and not cache.records["2s"])
  for i = 18, 30 do put(i, { ["1s"] = true }) end
  assert(cache.records["1s"] and #cache.order == 16)
end)

test("dense visible text can exceed the cache budget without a prefetch loop", function()
  local controller, ui = start({ vocabulary(903), vocabulary(301) })
  ui.document.breaks[302], ui.document.breaks[603] = true, true
  controller.cache.limit = 2
  settle()
  assert(#requests == 3 and #controller.cache.order == 3 and #controller.overlay.boxes == 3)
  assert(not next(scheduled), "speculative chunks must not be queried and immediately evicted")
  turn(controller, ui, 2); settle()
  assert(#requests == 4 and #controller.cache.order == 2 and #controller.overlay.boxes == 1)
  controller:close()
end)

test("scroll position and two-page spread changes reuse document ranges", function()
  local controller, ui = ready(paragraph_pages(5))
  settle()
  ui.view.view_mode = "scroll"
  controller:layout_changed(); drain()
  assert(#requests == 3 and #controller.overlay.boxes == 1)
  ui.view.view_mode = "page"
  ui.document.visible_pages = 2
  controller:layout_changed(); drain()
  assert(#requests == 4, "the spread is covered and only its following chunk needs a query")
  controller:close()
end)

test("font changes reuse completed and in-flight meanings and rebuild geometry", function()
  local controller, ui = ready()
  complete(requests[1]); drain()
  local active = requests[2]
  ui.document.hash = 2
  ui.document.boxes = { { x = 75, y = 200, w = 45, h = 24 } }
  controller:layout_changed(); drain()
  assert(#requests == 2 and active.cancels == 0 and controller.overlay.boxes[1].box.x == 75)
  complete(active); drain()
  assert(#requests == 3 and #controller.overlay.boxes == 1)
  ui.document.hash = 3
  controller:settings_changed(); drain()
  assert(#requests == 3 and requests[3].cancels == 0)
  controller:close()
end)

test("repagination exposes cached occurrences without a new query", function()
  local controller, ui = ready(paragraph_pages(3))
  complete(requests[1]); drain()
  -- Change a page boundary, keeping document positions intact.
  ui.document.ranges[1].last = 150
  ui.document.ranges[2].first = 151
  ui.document.page, ui.document.hash = 2, 2
  controller:layout_changed(); drain()
  assert(#requests == 2 and requests[2].cancels == 0)
  complete(requests[2], { { first = 1, last = 1, meaning = "contextual meaning" } }); drain()
  assert(#controller.overlay.boxes == 1 and #requests == 3)
  controller:close()
end)

test("meaning settings cancel all requests and reject late callbacks", function()
  local controller, ui = ready()
  for page = 2, 5 do turn(controller, ui, page) end
  assert(active_count(controller) == 5)
  configuration.word_sense_model, configuration.output_language = "different-model", "French"
  controller:settings_changed()
  for _, request in ipairs(requests) do
    assert(request.cancels == 1)
    complete(request)
  end
  assert(#controller.overlay.boxes == 0 and #controller.cache.order == 0)
  drain()
  assert(#requests == 6 and requests[6].callbacks.model == "different-model")
  assert(requests[6].messages[1].content:find("French", 1, true))
  controller:close()
end)

test("navigation caps active requests and reuses a pending chunk", function()
  local controller, ui = ready(paragraph_pages(10))
  for page = 2, 5 do turn(controller, ui, page) end
  assert(active_count(controller) == 5 and #requests == 5)
  turn(controller, ui, 2)
  assert(#requests == 5)
  turn(controller, ui, 6)
  assert(active_count(controller) == 5 and requests[1].cancels == 1 and #requests == 6)
  complete(requests[1]); assert(#controller.overlay.boxes == 0)
  complete(requests[6]); drain()
  assert(#controller.overlay.boxes == 1)
  controller:close()
end)

test("selection pauses every extraction batch and navigation abandons old extraction", function()
  local controller, ui = start(paragraph_pages(3))
  ui.highlight.selected_text, ui.document.selection_active = {}, true
  tick(); assert(ui.document.reads == 0 and #requests == 0)
  ui.highlight.selected_text, ui.document.selection_active = nil, false
  tick(); local reads = ui.document.reads
  assert(reads == 24 and #requests == 0)
  ui.highlight.hold_pos, ui.document.selection_active = {}, true
  tick(); assert(ui.document.reads == reads)
  ui.highlight.hold_pos, ui.document.selection_active = nil, false
  turn(controller, ui, 2)
  assert(#requests == 1 and requests[1].page.tokens[1].text == "p2w1")
  controller:close()
end)

test("empty responses cache coverage and failed requests retry only on a later visit", function()
  local controller, ui = ready(paragraph_pages(3))
  complete(requests[1], {}); drain()
  requests[2].callbacks.on_error("offline"); drain()
  complete(requests[3]); drain()
  assert(#requests == 3 and #controller.overlay.boxes == 0)
  turn(controller, ui, 2)
  assert(#requests == 4, "failed paragraph retries on its next visit")
  complete(requests[4]); drain()
  turn(controller, ui, 1)
  assert(#requests == 4 and #controller.overlay.boxes == 0, "empty successful response is cached")
  controller:close()
end)

test("startup errors and corrupt extraction stay quiet without automatic retry loops", function()
  requests.start_error = true
  local controller = ready(paragraph_pages(4))
  drain()
  assert(#requests == 3 and active_count(controller) == 0)
  controller:close()
  requests.start_error = nil
  controller = start()
  controller.ui.document.getTextFromXPointers = function() error("bad document") end
  drain()
  assert(controller.scan_failed and #warnings > 0 and not next(scheduled))
  controller:close()
end)

test("synchronous transport completion does not leave jobs or stale scan markers", function()
  requests.synchronous_success = true
  local controller = ready(paragraph_pages(4))
  drain()
  assert(#requests == 3 and active_count(controller) == 0 and #controller.overlay.boxes == 1)
  controller:close()
  requests.synchronous_success, requests.synchronous_error = nil, true
  controller = ready(paragraph_pages(4)); drain()
  assert(#requests == 6 and active_count(controller) == 0)
  controller:close()
end)

test("empty EPUB fragments are skipped and backwards navigation cannot loop", function()
  local doc = document({ { "before", " ", "after" } })
  local chunk = chunk_at(doc, 1)
  assert(#chunk.words == 2 and chunk.words[2].text == "after")
  local source = Reflowable.new(make_ui(doc))
  local last = source:word("3e")
  assert(source:previous(last).text == "before")
  doc.getPrevVisibleWordEnd = function(_, pos) return pos end
  assert(not pcall(source.previous, source, last))
end)

test("suspend and close cancel transport, timers and hooks while resume reuses cache", function()
  local controller, ui = ready()
  complete(requests[1]); drain()
  local tap, hold = controller.original_tap, controller.original_hold
  controller:suspend(); assert(requests[2].cancels == 1 and not next(scheduled))
  complete(requests[2]); assert(#controller.overlay.boxes == 0)
  controller:resume(); drain()
  assert(#requests == 3 and #controller.overlay.boxes == 1)
  controller:close(); controller:close()
  assert(requests[3].cancels == 1 and #controller.cache.order == 0 and not next(scheduled))
  assert(not next(ui.view.view_modules) and ui.highlight.onTap == tap and ui.highlight.onHold == hold)
end)

local function pdf_ui(pages)
  local ui = make_ui(document({ { "unused" } }))
  local doc = { file = "book.PDF", info = { number_of_pages = #pages }, configurable = {} }
  function doc:getPageTextBoxes(number) return pages[number] end
  function doc:nativeToPageRectTransform(_, box)
    if self.transform_error then error("bad transform") end
    if self.configurable.text_wrap == 1 then
      return { x = box.x + 20, y = box.y + 40, w = box.w, h = box.h }
    end
    return box
  end
  ui.document = doc
  ui.view.state = { page = 1, zoom = 1, rotation = 0, offset = { x = 0, y = 0 } }
  ui.view.visible_area = { x = 0, y = 0, w = 600, h = 800 }
  function ui.view:pageToScreenTransform(number, box)
    if not self.page_scroll and number ~= self.state.page then error("offscreen page transformed") end
    return { x = (box.x - self.visible_area.x) * self.state.zoom,
      y = (box.y - self.visible_area.y) * self.state.zoom, w = box.w * self.state.zoom, h = box.h * self.state.zoom }
  end
  return ui
end

local function pdf_line(texts, y, x)
  local line = { x0 = x or 10, y0 = y, x1 = (x or 10) + #texts * 15, y1 = y + 12 }
  for i, word in ipairs(texts) do
    line[i] = { word = word, x0 = line.x0 + (i - 1) * 15, y0 = y, x1 = line.x0 + i * 15, y1 = y + 12 }
  end
  return line
end

test("PDF chunks preserve paragraph boundaries and native occurrence coordinates", function()
  local ui = pdf_ui({ { pdf_line(vocabulary(150), 10), pdf_line(vocabulary(150), 50),
    pdf_line({ "extra" }, 90), pdf_line({ "excluded" }, 130) } })
  local source = Fixed.new(ui)
  local chunk = Chunk.new(source, source:word(1, 1))
  while not Chunk.step(chunk) do end
  assert(chunk.count == 301 and #chunk.words == 301 and chunk.pos0.index == 1)
  assert(chunk.context:find("\n\n", 1, true) and not chunk.context:find("excluded", 1, true))
  local entries = assert(Prompt.validate({ entries = { { first = 149, last = 152, meaning = "simple meaning" } } }, chunk.words))
  assert(#entries[1].positions == 4 and entries[1].pos0.page == 1)
end)

test("PDF continuation across physical pages includes the whole paragraph", function()
  local ui = pdf_ui({ { pdf_line({ "give" }, 10) }, { pdf_line({ "way" }, 10), pdf_line(vocabulary(301), 50) } })
  local source = Fixed.new(ui)
  local chunk = Chunk.new(source, source:word(2, 1))
  while not Chunk.step(chunk) do end
  assert(chunk.words[1].text == "give" and chunk.words[2].text == "way" and chunk.count == 303)
  local entries = assert(Prompt.validate({ entries = { { first = 1, last = 2, meaning = "stop resisting" } } }, chunk.words))
  assert(#entries[1].positions == 2)
  assert(#source:boxes(entries, 600, 800) == 1)
  ui.view.state.page = 2
  assert(#source:boxes(entries, 600, 800) == 1)
end)

test("PDF definitions survive zoom crop and reflow with transformed underlines", function()
  local ui = pdf_ui({ { pdf_line({ "difficult." }, 20) }, { pdf_line({ "another." }, 20) } })
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain()
  assert(#requests == 1 and #requests[1].page.tokens == 2)
  complete(requests[1]); drain()
  assert(controller.overlay.boxes[1].box.x == 10)
  ui.view.state.zoom = 2
  ui.view.visible_area.x = 5
  controller:refresh(); drain()
  assert(#requests == 1 and controller.overlay.boxes[1].box.x == 10 and controller.overlay.boxes[1].box.w == 30)
  ui.document.configurable.text_wrap = 1
  controller:layout_changed(); drain()
  assert(#requests == 1 and controller.overlay.boxes[1].box.x == 50)
  ui.document.transform_error = true
  controller:layout_changed(); drain(); assert(#controller.overlay.boxes == 0)
  controller:close()
end)

test("PDF scroll signatures include every visible page and its position", function()
  local ui = pdf_ui({ { pdf_line({ "first." }, 10) }, { pdf_line({ "second." }, 10) } })
  ui.view.page_scroll = true
  ui.view.page_states = { { page = 1, zoom = 1, visible_area = { y = 0 } },
    { page = 2, zoom = 1, visible_area = { y = 0 } } }
  local source = Fixed.new(ui)
  local viewport = source:viewport()
  assert(source:step_viewport(viewport) and #viewport.words == 2)
  local signature = source:signature(600, 800)
  ui.view.page_states[2].visible_area.y = 10
  assert(signature ~= source:signature(600, 800))
end)

local function forbid_pdf_ocr(doc)
  local function forbidden() error("Word Sense must only read embedded PDF text") end
  doc.getTextBoxes, doc.getOCRWord, doc.getOCRText = forbidden, forbidden, forbidden
  doc.koptinterface = { getNativeOCRWord = forbidden }
end

test("PDF and DjVu share embedded text extraction and never invoke OCR", function()
  for _, file in ipairs({ "book.pdf", "book.PDF", "book.djvu", "book.DjVu", "book.djv", "book.DJV" }) do
    local ui = pdf_ui({ { pdf_line({ "digital", "text" }, 10) } })
    ui.document.file = file
    forbid_pdf_ocr(ui.document)
    local before = #requests
    local controller = assert(WordSense.new { ui = ui }, file)
    assert(getmetatable(controller.source) == Fixed, file)
    controller:refresh(); drain()
    assert(#requests == before + 1 and requests[#requests].page.tokens[1].text == "digital", file)
    complete(requests[#requests]); drain()
    assert(#controller.overlay.boxes == 1, file)
    ui.view.state.zoom = 2
    controller:layout_changed(); drain()
    assert(#requests == before + 1 and controller.overlay.boxes[1].box.w == 30, file)
    controller:close()
  end
end)

test("alternate providers choose an adapter by document APIs instead of extension", function()
  for _, file in ipairs({ "book.epub", "book.epub3", "book.kepub", "book.mobi", "book.txt", "book.html", "book.xhtml" }) do
    local ui = pdf_ui({ { pdf_line({ "alternate", "provider" }, 10) } })
    ui.document.file = file
    forbid_pdf_ocr(ui.document)
    local before = #requests
    local controller = assert(WordSense.new { ui = ui }, file)
    assert(getmetatable(controller.source) == Fixed, file)
    controller:refresh(); drain()
    assert(#requests == before + 1, file)
    complete(requests[#requests]); drain()
    assert(#controller.overlay.boxes == 1, file)
    controller:close()
  end
end)

test("fixed text routing rejects incomplete APIs and image-only DjVu sends no queries", function()
  for _, method in ipairs({ "getPageTextBoxes", "nativeToPageRectTransform" }) do
    local ui = pdf_ui({ {} })
    ui.document.file = "book.djvu"
    ui.document[method] = false
    assert(not Source.new(ui) and not WordSense.new { ui = ui }, method)
  end
  local ui = pdf_ui({ {} })
  ui.document.file = "book.djvu"
  ui.view.pageToScreenTransform = false
  assert(not Source.new(ui))
  ui = pdf_ui({ {} })
  ui.document.file = "book.djvu"
  forbid_pdf_ocr(ui.document)
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain()
  assert(#requests == 0 and #controller.overlay.boxes == 0 and not controller.scan_failed)
  controller:close()
end)

test("image-only PDF regions are skipped without any recognition fallback", function()
  local line = pdf_line({ "placeholder" }, 10)
  line[1].word = nil
  local ui = pdf_ui({ { line } })
  forbid_pdf_ocr(ui.document)
  ui.document.configurable.text_wrap = 1
  local source = Fixed.new(ui)
  assert(not source:word(1, 1))
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain()
  assert(#requests == 0 and #controller.overlay.boxes == 0 and not controller.scan_failed)
  controller:close()
end)

test("embedded PDF text is used even when KOReader has forced OCR enabled", function()
  local ui = pdf_ui({ { pdf_line({ "digital", "text" }, 10) } })
  ui.document.configurable.forced_ocr = 1
  forbid_pdf_ocr(ui.document)
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain()
  assert(#requests == 1 and requests[1].page.tokens[1].text == "digital")
  complete(requests[1]); drain()
  ui.document.configurable.doc_language = "fra"
  controller:layout_changed(); drain()
  assert(#requests == 1 and #controller.overlay.boxes == 1)
  controller:close()
end)

test("mixed PDF regions keep only embedded words and nil text layers are empty", function()
  local line = pdf_line({ "digital", "placeholder", " ", "text" }, 10)
  line[2].word = nil
  local ui = pdf_ui({ { line }, {} })
  forbid_pdf_ocr(ui.document)
  local source = Fixed.new(ui)
  local viewport = source:viewport(); assert(source:step_viewport(viewport))
  assert(#viewport.words == 2 and source:text(viewport.words) == "digital text")
  assert(viewport.words[2].pos0.box.x == line[4].x0)
  ui.document.getPageTextBoxes = function() return nil end
  source = Fixed.new(ui)
  viewport = source:viewport(); assert(source:step_viewport(viewport) and #viewport.words == 0)
end)

test("PDF hyphenation joins line continuations while preserving paragraph breaks", function()
  local ui = pdf_ui({ { pdf_line({ "hyphen-" }, 10), pdf_line({ "ated" }, 25),
    pdf_line({ "paragraph-" }, 80), pdf_line({ "break" }, 130) } })
  local source = Fixed.new(ui)
  local viewport = source:viewport(); assert(source:step_viewport(viewport))
  assert(source:text(viewport.words) == "hyphenated\n\nparagraph-\n\nbreak")
end)

test("blank PDF pages send no requests and malformed coordinates do not crash the reader", function()
  local ui = pdf_ui({ {}, { pdf_line({ "word" }, 10) } })
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain(); assert(#requests == 0)
  ui.view.state.page = 2
  controller:refresh(); drain(); assert(#requests == 1)
  controller:close()
  local line = pdf_line({ "word" }, 10)
  line[1].x0 = nil
  ui = pdf_ui({ { line } })
  controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain()
  assert(controller.scan_failed and #requests == 1 and #warnings > 0)
  controller:close()
end)

for _, spec in ipairs(tests) do
  errors, warnings, requests, scheduled, decoded = {}, {}, {}, {}, {}
  configuration = { output_language = "English", word_sense_level = "Intermediate" }
  local ok, err = xpcall(spec[2], debug.traceback)
  assert(ok, spec[1] .. "\n" .. tostring(err))
  assert(#errors == 0, spec[1] .. "\n" .. table.concat(errors, "\n"))
  assert(not next(scheduled), spec[1] .. ": leaked scheduled work")
  print("PASS: " .. spec[1])
end
print("Word Sense: " .. #tests .. " isolated checks passed")
