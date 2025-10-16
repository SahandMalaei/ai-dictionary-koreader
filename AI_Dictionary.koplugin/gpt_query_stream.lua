local socket = require("socket")
local ssl    = require("ssl")
local json   = require("json") or require("dkjson") -- KOReader usually has 'json'

-- Minimal JSON encode fallback (if neither json nor dkjson is present)
local function json_encode_fallback(tbl)
  local ok, s = pcall(function() return require("cjson").encode(tbl) end)
  if ok then return s end
  error("No JSON library available (json/dkjson/cjson).")
end
local function jencode(tbl)
  if json and json.encode then return json.encode(tbl) end
  return json_encode_fallback(tbl)
end

-- Tiny SSE line parser
local function iter_sse_lines(sock)
  local buffer = ""
  return function()
    while true do
      local nl = buffer:find("\n", 1, true)
      if nl then
        local line = buffer:sub(1, nl - 1)
        buffer = buffer:sub(nl + 1)
        return line
      end
      local chunk, err, partial = sock:receive(8192)
      if chunk then
        buffer = buffer .. chunk
      elseif partial and #partial > 0 then
        buffer = buffer .. partial
      else
        if err == "timeout" then
          return nil, "timeout"
        end
        if err == "closed" then
          -- flush remainder if any
          if #buffer > 0 then
            local last = buffer
            buffer = ""
            return last
          end
          return nil, "closed"
        end
        return nil, err
      end
    end
  end
end

-- Very small timer wrapper for KOReader:
-- KOReader exposes UIManager; we’ll use a repeating 30ms timer.
local function every_30ms(fn)
  local UIManager = require("ui/uimanager")
  local killed = false
  local function tick()
    if killed then return end
    local again = fn()
    if again == false then
      killed = true
      return
    end
    -- reschedule
    UIManager:scheduleIn(0.03, tick)
  end
  UIManager:scheduleIn(0.03, tick)
  return function() killed = true end
end

CONFIGURATION = require("configuration")

-- Public API
local function stream_to_inputcontainer(opts)
  local ic           = assert(opts.ic, "opts.ic (InputContainer) required")
  local messages     = assert(opts.messages, "opts.messages required")
  local api_key      = assert(CONFIGURATION and CONFIGURATION.api_key, "opts.api_key required")
  local on_error     = opts.on_error
  local on_done      = opts.on_done
  local max_tokens   = opts.max_tokens
  local system_text  = opts.system

  local mm = {}
  if system_text and #system_text > 0 then
    table.insert(mm, { role = "system", content = system_text })
  end
  for i = 1, #messages do table.insert(mm, messages[i]) end

  local body_tbl = {
    model = "gpt-5-nano",
    reasoning_effort = "minimal",
    verbosity = "low",
    messages = mm,
    stream = true,
  }

  local body = jencode(body_tbl)
  local host = "api.openai.com"
  local port = 443

  -- 1) TCP connect
  local tcp = assert(socket.tcp())
  local ok, err = tcp:connect(host, port)
  if not ok and err ~= "timeout" and err ~= "Operation already in progress" then
    if on_error then on_error("TCP connect failed: " .. tostring(err)) end
    return
  elseif not ok then
    on_error("TCP connect failed: " .. tostring(err))
    return
  else
    on_error("TCP connect success")
  end

  -- 2) TLS wrap
  local params = {
    mode = "client",
    protocol = "tlsv1_2",
    verify = "none",        -- or "none" while debugging
    options = "all",
    ciphers = "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!3DES:!RC4:!MD5",
    server_name = "api.openai.com"
  }
  local ssl_sock, serr = ssl.wrap(tcp, params)
  if not ssl_sock then
    if on_error then on_error("SSL wrap failed: " .. tostring(serr)) end
    return
  end

  -- 3) TLS handshake (non-blocking handshake pump)
  local handshake_done = false
  local function do_handshake()
    local ok2, herr = ssl_sock:dohandshake()
    if ok2 then
      handshake_done = true;
      tcp:settimeout(0)
      ssl_sock:settimeout(0)
      return true
    end
    if herr == "wantread" or herr == "wantwrite" or herr == "timeout" then
      return false
    end
    if on_error then on_error("TLS handshake failed: " .. tostring(herr)) end
    return false, "fatal"
  end

  -- Prepare request headers
  local req_lines = {
    string.format("POST /v1/chat/completions HTTP/1.1"),
    "Host: " .. host,
    "Authorization: Bearer " .. api_key,
    "Content-Type: application/json",
    "Accept: text/event-stream",
    "Connection: keep-alive",
    "Content-Length: " .. tostring(#body),
    "", -- end headers
    body
  }
  local request_blob = table.concat(req_lines, "\r\n")

  local sent_request = false
  local headers_read = false
  local sse_iter
  local accumulated = "" -- text being built up and pushed into the InputContainer

  local UIManager = require("ui/uimanager")





  -- pump() is called ~every 30ms by the UI timer; return false to stop
  local function pump()
    -- 1) TLS handshake
    if not handshake_done then
      local okh, fatal = do_handshake()
      if fatal == "fatal" then return false end
      return true -- keep pumping until handshake completes
    end

    -- 2) Send request
    if not sent_request then
      local n, werr, pn = ssl_sock:send(request_blob)
      if n then
        if n < #request_blob then
          request_blob = request_blob:sub(n + 1) -- send rest next tick
        else
          sent_request = true
        end
      elseif werr == "wantwrite" or werr == "timeout" then
        -- try again next tick
      else
        if on_error then on_error("Send failed: " .. tostring(werr)) end
        return false
      end
      return true
    end

    -- 3) Read & discard response headers once
    if not headers_read then
      -- read until we see \r\n\r\n
      local header_buf = ""
      while true do
        local chunk, rerr, partial = ssl_sock:receive(8192)
        local got = chunk or partial
        if got and #got > 0 then
          header_buf = header_buf .. got
          local sep = header_buf:find("\r\n\r\n", 1, true)
          if sep then
            headers_read = true
            local remainder = header_buf:sub(sep + 4)
            -- initialize SSE iterator with the remainder cached
            sse_iter = (function()
              local first = remainder
              local first_used = false
              local iter = iter_sse_lines(ssl_sock)
              return function()
                if not first_used and #first > 0 then
                  first_used = true
                  local line, rest = first:match("([^\n]*)\n?(.*)")
                  first = rest or ""
                  if line and #line > 0 then return line end
                end
                return iter()
              end
            end)()
            break
          end
        end
        if rerr == "timeout" or rerr == "wantread" then
          -- try again next tick
          return true
        end
        if rerr == "closed" then
          if on_error then on_error("Connection closed before headers") end
          return false
        end
        if chunk == nil and not partial and rerr then
          if on_error then on_error("Header read error: " .. tostring(rerr)) end
          return false
        end
      end
    end

    -- 4) Consume SSE lines
    if headers_read and sse_iter then
      while true do
        local line, err = sse_iter()
        if not line then
          if err == "timeout" then
            -- no new data this tick
            break
          end
          if err == "closed" then
            -- finalize
            if on_done then on_done() end
            return false
          end
          -- other errors
          if on_error then on_error("Read error: " .. tostring(err)) end
          return false
        end

        -- SSE spec: ignore comments/empty, parse 'data:' prefix
        if #line == 0 or line:sub(1,1) == ":" then
          -- heartbeat/comment
        elseif line:sub(1,5) == "data:" then
          local payload = line:sub(6):match("^%s*(.-)%s*$")
          if payload == "[DONE]" then
            if on_done then on_done() end
            return false
          else
            -- OpenAI stream chunk: { id, choices = { { delta = { content = "..." } } } ... }
            local okj, obj = pcall(function()
              if json and json.decode then return json.decode(payload) end
              return require("cjson").decode(payload)
            end)
            if okj and obj and obj.choices and obj.choices[1] and obj.choices[1].delta then
              local delta = obj.choices[1].delta
              if delta.content then
                accumulated = accumulated .. delta.content
                --ic:update(accumulated)
              end
            end
          end
        end
      end
    end

    return true
  end

  -- Kick off the repeating timer; keep a handle in case you want to cancel.
  local cancel = every_30ms(pump)
  return cancel
end

-- expose
return stream_to_inputcontainer
