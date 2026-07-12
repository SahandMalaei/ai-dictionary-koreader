local http = require("socket.http")
local https = require("ssl.https")
local Blitbuffer = require("ffi/blitbuffer")
local json = require("json")
local RenderImage = require("ui/renderimage")
local socket_url = require("socket.url")

local WikipediaImage = {}

local REQUEST_TIMEOUT_SECONDS = 15
local MAX_IMAGE_BYTES = 8 * 2048 * 2048
local BOX_SIZE = 300
local BORDER_SIZE = 1
local METADATA_OPEN = "<aidictionary-wikipedia>"
local METADATA_CLOSE = "</aidictionary-wikipedia>"

WikipediaImage.prompt_suffix = [[

Before the user-visible answer, output exactly one metadata line in this form:
<aidictionary-wikipedia>English Wikipedia-style unambiguous FULL title plus disambiguation if necessary (e.g. (Video Game)) or None</aidictionary-wikipedia>
Choose a title only when the selected text can be represented accurately by one specific subject that definitely has an English Wikipedia article with a representative lead image (strong candidates: famous people, tools, companies, games, movies, books, food items, animals and vegetables). Otherwise use None. Output this metadata line first, then follow all the original answer instructions exactly.]]

https.TIMEOUT = REQUEST_TIMEOUT_SECONDS
http.TIMEOUT = REQUEST_TIMEOUT_SECONDS

local function paint_outline(bb)
  local color = Blitbuffer.COLOR_DARK_GRAY
  bb:paintRect(0, 0, BOX_SIZE, BORDER_SIZE, color)
  bb:paintRect(0, BOX_SIZE - BORDER_SIZE, BOX_SIZE, BORDER_SIZE, color)
  bb:paintRect(0, 0, BORDER_SIZE, BOX_SIZE, color)
  bb:paintRect(BOX_SIZE - BORDER_SIZE, 0, BORDER_SIZE, BOX_SIZE, color)
end

local function request_client(url)
  if url:lower():sub(1, 7) == "http://" then
    return http.request
  end
  return https.request
end

local function get(url, accept, cancelled)
  local chunks = {}
  local size = 0
  local _, code = request_client(url) {
    url = url,
    method = "GET",
    headers = {
      ["Accept"] = accept,
      ["User-Agent"] = "AI-Dictionary-KOReader/experimental-wikipedia-image",
    },
    sink = function(chunk)
      if cancelled() then
        return nil, "cancelled"
      end
      if not chunk then
        return 1
      end
      size = size + #chunk
      if size > MAX_IMAGE_BYTES then
        return nil, "image too large"
      end
      chunks[#chunks + 1] = chunk
      return 1
    end,
  }
  if cancelled() or tostring(code) ~= "200" then
    return nil
  end
  return table.concat(chunks)
end

local function clean_title(answer)
  if type(answer) ~= "string" then
    return nil
  end
  local title = answer:gsub("^%s+", ""):gsub("%s+$", "")
  title = title:gsub('^"(.-)"$', "%1")
  if title:lower() == "none" or title == "" or title:find("[\r\n]") or #title > 120 then
    return nil
  end
  return title
end

function WikipediaImage.parse_response(response)
  if type(response) ~= "string" then
    return nil, "", false
  end
  local start_at = response:find(METADATA_OPEN, 1, true)
  if not start_at then
    return nil, "", false
  end
  local value_start = start_at + #METADATA_OPEN
  local close_at = response:find(METADATA_CLOSE, value_start, true)
  if not close_at then
    return nil, "", false
  end
  local title = clean_title(response:sub(value_start, close_at - 1))
  local visible = response:sub(close_at + #METADATA_CLOSE):gsub("^[\r\n%s]+", "")
  return title, visible, true
end

function WikipediaImage.strip_metadata_fallback(response)
  response = tostring(response or "")
  local start_at = response:find(METADATA_OPEN, 1, true)
  if not start_at then return response end
  local close_at = response:find(METADATA_CLOSE, start_at + #METADATA_OPEN, true)
  if close_at then
    return (response:sub(1, start_at - 1) .. response:sub(close_at + #METADATA_CLOSE)):gsub("^[\r\n%s]+", "")
  end
  local line_end = response:find("\n", start_at, true)
  if line_end then
    return (response:sub(1, start_at - 1) .. response:sub(line_end + 1)):gsub("^[\r\n%s]+", "")
  end
  return response:sub(1, start_at - 1):gsub("%s+$", "")
end

function WikipediaImage.new_placeholder(title)
  local bb = Blitbuffer.new(BOX_SIZE, BOX_SIZE, Blitbuffer.TYPE_BBRGB32)
  bb:fill(Blitbuffer.COLOR_WHITE)
  paint_outline(bb)
  return {
    width = BOX_SIZE,
    height = BOX_SIZE,
    fixed_box_size = BOX_SIZE,
    bb = bb,
    title = title,
  }
end

local function find_thumbnail(title, cancelled)
  local api_url = "https://en.wikipedia.org/w/api.php?action=query&format=json&formatversion=2" ..
      "&redirects=1&prop=pageimages&piprop=thumbnail&pithumbsize=800&titles=" .. socket_url.escape(title)
  local body = get(api_url, "application/json", cancelled)
  if not body then
    return nil
  end
  local ok, result = pcall(json.decode, body)
  local page = ok and result and result.query and result.query.pages and result.query.pages[1]
  return page and not page.missing and page.thumbnail and page.thumbnail.source or nil
end

function WikipediaImage.fetch(title_answer, cancelled)
  local title = clean_title(title_answer)
  if not title or cancelled() then
    return nil
  end
  local image_url = find_thumbnail(title, cancelled)
  if not image_url or cancelled() then
    return nil
  end
  local data = get(image_url, "image/*", cancelled)
  if not data or cancelled() then
    return nil
  end
  local ok, source_bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
  if not ok or not source_bb or cancelled() then
    if source_bb and source_bb.free then source_bb:free() end
    return nil
  end

  local source_width = source_bb:getWidth()
  local source_height = source_bb:getHeight()
  if source_width < 1 or source_height < 1 then
    source_bb:free()
    return nil
  end
  local inner_size = BOX_SIZE - 2 * BORDER_SIZE
  local scale = math.min(inner_size / source_width, inner_size / source_height)
  local image_width = math.max(1, math.floor(source_width * scale + 0.5))
  local image_height = math.max(1, math.floor(source_height * scale + 0.5))
  local scaled_bb = RenderImage:scaleBlitBuffer(source_bb, image_width, image_height)
  local box_bb = Blitbuffer.new(BOX_SIZE, BOX_SIZE, Blitbuffer.TYPE_BBRGB32)
  box_bb:fill(Blitbuffer.COLOR_WHITE)
  box_bb:blitFrom(
    scaled_bb,
    BORDER_SIZE + math.floor((inner_size - image_width) / 2),
    BORDER_SIZE + math.floor((inner_size - image_height) / 2),
    0,
    0,
    image_width,
    image_height
  )
  scaled_bb:free()
  paint_outline(box_bb)

  -- TextBoxWidget reserves space from image.width/image.height, but paints the
  -- complete image.bb. Keep both dimensions tied to the actual final buffer so
  -- a decoder/scaler returning an unexpected size can never spill into text.
  if box_bb:getWidth() ~= BOX_SIZE or box_bb:getHeight() ~= BOX_SIZE then
    box_bb = RenderImage:scaleBlitBuffer(box_bb, BOX_SIZE, BOX_SIZE)
  end

  return {
    width = box_bb:getWidth(),
    height = box_bb:getHeight(),
    fixed_box_size = BOX_SIZE,
    bb = box_bb,
    title = title,
  }
end

return WikipediaImage
