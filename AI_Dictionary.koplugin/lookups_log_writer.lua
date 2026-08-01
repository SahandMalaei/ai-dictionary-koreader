local logger = require("logger")

local BackgroundWorker = require("background_worker")
local save_lookup_entry = require("lookups_log")

local LookupsLogWriter = {}

local queue = {}
local active = false

local function start_next()
  if active or #queue == 0 then return end

  active = true
  local entry = table.remove(queue, 1)

  local function finish()
    active = false
    start_next()
  end

  BackgroundWorker.start(function()
    local ok, err = save_lookup_entry(entry.plugin_path, entry.lookup, entry.context)
    if not ok then
      error(err or "Unknown lookup log error.")
    end
  end, {
    on_complete = finish,
    on_error = function(err)
      logger.err("AI Dictionary: background lookup log write failed\n" .. tostring(err))
      finish()
    end,
  })
end

function LookupsLogWriter.enqueue(plugin_path, lookup, context)
  queue[#queue + 1] = {
    plugin_path = plugin_path,
    lookup = lookup,
    context = context,
  }
  start_next()
end

return LookupsLogWriter
