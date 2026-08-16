local source = debug.getinfo(1, "S").source
local plugin_dir = source and source:match("^@(.+)/[^/]+$")
if plugin_dir then
  package.path = plugin_dir .. "/?.lua;" .. package.path
end

local ok, i18n = pcall(require, "plugin_i18n")
local _ = ok and i18n or function(s) return s end

return {
  name = "aidictionary",
  fullname = _("AI Dictionary"),
  description = _("AI dictionary and explainer"),
  version = 3.0,
}
