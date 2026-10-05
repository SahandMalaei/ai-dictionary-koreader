-- File eligibility lives here; adapters describe text APIs, not file formats.
-- Add an extension to enable another format served by either existing adapter.
local Source = {}
local FORMATS = {
  epub = true, epub3 = true, kepub = true, mobi = true,
  txt = true, htm = true, html = true, xhtml = true,
  pdf = true, djvu = true, djv = true,
}
local ADAPTERS = {
  require("word_sense_reflowable"),
  require("word_sense_fixed"),
}

function Source.new(ui)
  local file = ui and ui.document and ui.document.file
  local extension = type(file) == "string" and file:lower():match("%.([^./\\]+)$")
  if not FORMATS[extension] then return end
  for _, adapter in ipairs(ADAPTERS) do
    if adapter.supported(ui) then return adapter.new(ui) end
  end
end

return Source
