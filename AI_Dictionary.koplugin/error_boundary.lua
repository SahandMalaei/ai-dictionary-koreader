local logger = require("logger")

local unpack_values = unpack or table.unpack

local ErrorBoundary = {}

local function pack(...)
  return { n = select("#", ...), ... }
end

local function traceback(err)
  local message = tostring(err)
  if debug and type(debug.traceback) == "function" then
    return debug.traceback(message, 2)
  end
  return message
end

function ErrorBoundary.call(label, fn, ...)
  local args = pack(...)
  local results = pack(xpcall(function()
    return fn(unpack_values(args, 1, args.n))
  end, traceback))

  if not results[1] then
    local err = results[2]
    logger.err("AI Dictionary: " .. tostring(label) .. " failed\n" .. tostring(err))
    return nil, err
  end

  return unpack_values(results, 2, results.n)
end

function ErrorBoundary.wrap(label, fn)
  return function(...)
    return ErrorBoundary.call(label, fn, ...)
  end
end

return ErrorBoundary
