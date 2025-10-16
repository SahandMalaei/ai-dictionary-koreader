-- Convert likely-UTF-16 strings (with/without BOM) to UTF-8.
-- If it doesn't look like UTF-16, returns the original string.
local function from_utf16_to_utf8(s)
  if not s or s == "" then return "" end

  local be, i
  local b1, b2 = s:byte(1, 2)
  if b1 == 0xFE and b2 == 0xFF then
    be, i = true, 3         -- UTF-16BE with BOM
  elseif b1 == 0xFF and b2 == 0xFE then
    be, i = false, 3        -- UTF-16LE with BOM
  else
    -- Heuristic: lots of NULs in odd or even positions -> looks like UTF-16
    local nul_odd, nul_even = 0, 0
    for k = 1, #s do
      if s:byte(k) == 0 then
        if (k % 2) == 1 then nul_odd = nul_odd + 1 else nul_even = nul_even + 1 end
      end
    end
    if (nul_odd + nul_even) <= (#s / 8) then
      return s  -- probably already UTF-8; bail out
    end
    be, i = (nul_odd > nul_even), 1
  end

  local function read_u16()
    if i + 1 > #s then return nil end
    local a, b = s:byte(i, i + 1); i = i + 2
    if be then
      return a * 256 + b        -- big-endian
    else
      return b * 256 + a        -- little-endian
    end
  end

  local out = {}
  while true do
    local u = read_u16(); if not u then break end

    -- handle surrogate pairs
    if u >= 0xD800 and u <= 0xDBFF then
      local u2 = read_u16()
      if u2 and u2 >= 0xDC00 and u2 <= 0xDFFF then
        u = 0x10000 + ((u - 0xD800) * 0x400) + (u2 - 0xDC00)
      else
        u = 0xFFFD -- replacement char
      end
    elseif u >= 0xDC00 and u <= 0xDFFF then
      u = 0xFFFD
    end

    -- encode codepoint u to UTF-8 using arithmetic
    if u < 0x80 then
      out[#out+1] = string.char(u)
    elseif u < 0x800 then
      out[#out+1] = string.char(0xC0 + math.floor(u / 0x40),
                                0x80 + (u % 0x40))
    elseif u < 0x10000 then
      out[#out+1] = string.char(0xE0 + math.floor(u / 0x1000),
                                0x80 + (math.floor(u / 0x40) % 0x40),
                                0x80 + (u % 0x40))
    else
      out[#out+1] = string.char(0xF0 + math.floor(u / 0x40000),
                                0x80 + (math.floor(u / 0x1000) % 0x40),
                                0x80 + (math.floor(u / 0x40) % 0x40),
                                0x80 + (u % 0x40))
    end
  end
  return table.concat(out)
end

local function strip_controls_ascii(s)
  s = tostring(s or "")
  local t = {}
  for i = 1, #s do
    local b = s:byte(i)
    if b == 9 or b == 10 or b >= 32 then t[#t+1] = string.char(b) end
  end
  return table.concat(t):gsub("\r", "\n")
end

-- replace illegal UTF-8 sequences with '?'
local function to_valid_utf8(s)
  s = tostring(s or "")
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    if c < 0x80 then
      out[#out+1] = string.char(c); i = i + 1
    elseif c >= 0xC2 and c <= 0xDF and i+1<=n then
      local c2 = s:byte(i+1)
      if c2 >= 0x80 and c2 <= 0xBF then out[#out+1]=s:sub(i,i+1); i=i+2 else out[#out+1]="?"; i=i+1 end
    elseif c == 0xE0 and i+2<=n then
      local c2,c3 = s:byte(i+1,i+2)
      if c2>=0xA0 and c2<=0xBF and c3>=0x80 and c3<=0xBF then out[#out+1]=s:sub(i,i+2); i=i+3 else out[#out+1]="?"; i=i+1 end
    elseif c >= 0xE1 and c <= 0xEF and i+2<=n then
      local c2,c3 = s:byte(i+1,i+2)
      if c2>=0x80 and c2<=0xBF and c3>=0x80 and c3<=0xBF then out[#out+1]=s:sub(i,i+2); i=i+3 else out[#out+1]="?"; i=i+1 end
    elseif c == 0xF0 and i+3<=n then
      local c2,c3,c4 = s:byte(i+1,i+3)
      if c2>=0x90 and c2<=0xBF and c3>=0x80 and c3<=0xBF and c4>=0x80 and c4<=0xBF then out[#out+1]=s:sub(i,i+3); i=i+4 else out[#out+1]="?"; i=i+1 end
    elseif c >= 0xF1 and c <= 0xF3 and i+3<=n then
      local c2,c3,c4 = s:byte(i+1,i+3)
      if c2>=0x80 and c2<=0xBF and c3>=0x80 and c3<=0xBF and c4>=0x80 and c4<=0xBF then out[#out+1]=s:sub(i,i+3); i=i+4 else out[#out+1]="?"; i=i+1 end
    elseif c == 0xF4 and i+3<=n then
      local c2,c3,c4 = s:byte(i+1,i+3)
      if c2>=0x80 and c2<=0x8F and c3>=0x80 and c3<=0xBF and c4>=0x80 and c4<=0xBF then out[#out+1]=s:sub(i,i+3); i=i+4 else out[#out+1]="?"; i=i+1 end
    else
      out[#out+1] = "?"; i = i + 1
    end
  end
  return table.concat(out)
end

local function clip(s, n)
  s = s or ""
  if #s > n then return s:sub(1, n) end
  return s
end

local function clean_up_string(s, len)
    return clip(to_valid_utf8(strip_controls_ascii(from_utf16_to_utf8(s))), len)
end

return clean_up_string