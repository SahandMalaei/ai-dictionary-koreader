-- Run from the repository root: luajit tests/word_sense_anchor_spec.lua
package.path = "./AI_Dictionary.koplugin/?.lua;" .. package.path
local Anchor = require("word_sense_anchor")
package.loaded.json = {}
local Prompt = require("word_sense_prompt")
local tests = {}
local function test(name, fn) tests[#tests + 1] = { name, fn } end

-- Positions are opaque strings; each navigation call moves one Unicode code
-- point, including across the pretend DOM nodes used in the pointer names.
local function source_for(text)
  local chars = {}
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = char end
  local positions, indices = {}, {}
  for i = 0, #chars do
    positions[i] = "node" .. math.floor(i / 3) .. ":" .. (i % 3)
    indices[positions[i]] = i
  end
  local source = { doc = {}, positions = positions, chars = chars }
  function source:compare(a, b)
    local x, y = assert(indices[a]), assert(indices[b])
    return x < y and -1 or x > y and 1 or 0
  end
  function source.doc:getNextVisibleChar(pos) return positions[indices[pos] + 1] end
  function source.doc:getPrevVisibleChar(pos) return positions[indices[pos] - 1] end
  function source.doc:getTextFromXPointers(a, b)
    return table.concat(chars, "", indices[a] + 1, indices[b])
  end
  return source
end

local function resolve(source, start, ending, target)
  return Anchor.resolve(source, { { pos0 = source.positions[start], pos1 = source.positions[ending] } }, 1, 1, target)
end

local function segmented_source(segments)
  local chars, nodes, indices, order, positions = {}, {}, {}, {}, {}
  for n, text in ipairs(segments) do
    local node = { first = #chars, positions = {} }
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = char end
    node.length = #chars - node.first
    for offset = 0, node.length do
      local pos = "node" .. n .. ":" .. offset
      node.positions[offset] = pos
      indices[pos] = { n = n, offset = offset, index = node.first + offset }
      order[pos] = n * 100 + offset
      positions[node.first + offset] = positions[node.first + offset] or pos
    end
    nodes[n] = node
  end
  local source = { positions = positions, doc = {} }
  function source:compare(a, b)
    return order[a] < order[b] and -1 or order[a] > order[b] and 1 or 0
  end
  function source.doc:getNextVisibleChar(pos)
    local p = indices[pos]
    if p.offset < nodes[p.n].length then return nodes[p.n].positions[p.offset + 1] end
    return nodes[p.n + 1] and nodes[p.n + 1].positions[0]
  end
  function source.doc:getPrevVisibleChar(pos)
    local p = indices[pos]
    if p.offset > 0 then return nodes[p.n].positions[p.offset - 1] end
    local previous = nodes[p.n - 1]
    return previous and previous.positions[previous.length - 1]
  end
  function source.doc:getTextFromXPointers(a, b)
    return table.concat(chars, "", indices[a].index + 1, indices[b].index)
  end
  return source
end

test("exact ranges retain their occurrence even when another is nearby", function()
  local source = source_for("cat cat")
  local entry = assert(resolve(source, 0, 3, "cat"))
  assert(entry.pos0 == source.positions[0] and entry.pos1 == source.positions[3])
end)

test("both endpoints can move five characters inward or outward", function()
  local source = source_for("xxxxxabcdefghijklmxxxxx")
  for _, range in ipairs({ { 0, 23 }, { 10, 13 }, { 0, 13 }, { 10, 23 } }) do
    local entry = assert(resolve(source, range[1], range[2], "abcdefghijklm"))
    assert(entry.pos0 == source.positions[5] and entry.pos1 == source.positions[18])
  end
end)

test("a six-character displacement of either endpoint is rejected", function()
  local source = source_for("xxxxxxabcdefghijklmxxxxxx")
  assert(not resolve(source, 0, 19, "abcdefghijklm"))
  assert(not resolve(source, 6, 25, "abcdefghijklm"))
  assert(not resolve(source, 12, 19, "abcdefghijklm"))
  assert(not resolve(source, 6, 13, "abcdefghijklm"))
end)

test("the tolerance counts Unicode characters rather than bytes", function()
  local source = source_for("ééééétarget漢漢漢漢漢")
  local entry = assert(resolve(source, 0, 16, "target"))
  assert(entry.pos0 == source.positions[5] and entry.pos1 == source.positions[11])
  source = source_for("éééééétarget")
  assert(not resolve(source, 0, 12, "target"))
end)

test("spelling and case must match and nearby duplicate candidates are skipped", function()
  local source = source_for("x cat cat y")
  assert(not resolve(source, 3, 8, "cat"))
  assert(not resolve(source, 2, 5, "Cat"))
  assert(not resolve(source, 2, 5, "missing"))
end)

test("whitespace and soft hyphens normalize without retaining endpoint padding", function()
  local source = source_for("give\194\160way")
  assert(resolve(source, 0, 8, "give way"))
  source = source_for("hy\194\173phen")
  assert(resolve(source, 0, 7, "hyphen"))
  source = source_for(" give\nway ")
  local entry = assert(resolve(source, 0, 10, "give way"))
  assert(entry.pos0 == source.positions[1] and entry.pos1 == source.positions[9])
end)

test("punctuation is trimmed by verified endpoints and inline nodes are crossed", function()
  local source = source_for('"hello!"')
  local entry = assert(resolve(source, 0, 8, "hello"))
  assert(entry.pos0 == source.positions[1] and entry.pos1 == source.positions[6])
end)

test("inline node transitions consume no tolerance and duplicate boundaries are equivalent", function()
  local source = segmented_source({ "x", "x", "x", "x", "x", "abc", "def", "ghijklm", "x", "x", "x", "x", "x" })
  local entry = assert(resolve(source, 0, 23, "abcdefghijklm"))
  assert(source.doc:getTextFromXPointers(entry.pos0, entry.pos1) == "abcdefghijklm")
  source = segmented_source({ "xx", "xxxx", "target" })
  assert(not resolve(source, 0, 12, "target"))
end)

test("document edges, unavailable navigation and engine failures are safe", function()
  local source = source_for("word")
  assert(not resolve(source, 0, 4, "absent"))
  source.doc.getNextVisibleChar = nil
  source.doc.getPrevVisibleChar = nil
  assert(resolve(source, 0, 4, "word"))
  assert(not resolve(source, 0, 4, "ord"))
  source.doc.getNextVisibleChar = function(_, pos) return pos end
  assert(not resolve(source, 0, 4, "absent"))
  source.doc.getTextFromXPointers = function() error("broken text layer") end
  assert(not resolve(source, 0, 4, "word"))
end)

test("missing target text is rejected and corrected spans cannot overlap", function()
  local source = source_for('"hello!"')
  local words = { { pos0 = source.positions[0], pos1 = source.positions[8] },
    { pos0 = source.positions[1], pos1 = source.positions[6] } }
  assert(not Prompt.validate({ entries = { { first = 1, last = 1, meaning = "greeting" } } }, words, source))
  local entries = assert(Prompt.validate({ entries = {
    { first = 1, last = 1, text = "hello", meaning = "greeting" },
    { first = 2, last = 2, text = "hello", meaning = "another greeting" },
  } }, words, source))
  assert(#entries == 1 and entries[1].pos0 == source.positions[1])
  entries = assert(Prompt.validate({ entries = {
    { first = 1, last = 1, text = "missing", meaning = "absent" },
    { first = 2, last = 2, text = "hello", meaning = "greeting" },
  } }, words, source))
  assert(#entries == 1 and entries[1].meaning == "greeting")
end)

for _, spec in ipairs(tests) do
  local ok, err = xpcall(spec[2], debug.traceback)
  assert(ok, spec[1] .. "\n" .. tostring(err))
  print("PASS: " .. spec[1])
end
print("Word Sense anchors: " .. #tests .. " isolated checks passed")
