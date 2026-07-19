local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local AIViewer = require("ai_viewer")
local ErrorBoundary = require("error_boundary")
local LookupsReport = require("lookups_report")
local QuerySession = require("query_session")

local LookupsReportUI = {}

local function show_message(text)
  UIManager:show(InfoMessage:new {
    text = text,
    timeout = 3,
  })
end

function LookupsReportUI.show_request_dialog(plugin, selected_index)
  selected_index = selected_index or 1
  local timeframe = LookupsReport.TIMEFRAMES[selected_index] or LookupsReport.TIMEFRAMES[1]
  local report_dialog

  report_dialog = ButtonDialog:new {
    title = "AI Dictionary Lookups Report",
    buttons = {
      {
        {
          text = "Timeframe: " .. timeframe.label,
          callback = function()
            UIManager:close(report_dialog)
            plugin:showLookupsReportTimeframeDialog(selected_index)
          end,
        },
      },
      {
        {
          text = "Generate Report",
          callback = function()
            UIManager:close(report_dialog)
            plugin:generateLookupsReport(timeframe)
          end,
        },
      },
    },
  }

  UIManager:show(report_dialog)
end

function LookupsReportUI.show_timeframe_dialog(plugin, selected_index)
  local selector_dialog
  local buttons = {}

  for index, timeframe in ipairs(LookupsReport.TIMEFRAMES) do
    table.insert(buttons, {
      {
        text = (index == selected_index and "* " or "") .. timeframe.label,
        callback = function()
          UIManager:close(selector_dialog)
          plugin:showLookupsReportRequestDialog(index)
        end,
      },
    })
  end

  selector_dialog = ButtonDialog:new {
    title = "Timeframe",
    buttons = buttons,
  }

  UIManager:show(selector_dialog)
end

function LookupsReportUI.generate(plugin, timeframe)
  local entries = LookupsReport.load_entries(plugin.path, timeframe)
  if #entries == 0 then
    show_message("No lookups found for " .. timeframe.label .. ".")
    return
  end

  local report_viewer = AIViewer:new {
    title = "AI Dictionary Lookups Report",
    text = "Generating report...",
    onAskQuestion = nil,
    benedict = plugin,
  }

  UIManager:show(report_viewer)

  UIManager:scheduleIn(0.01, ErrorBoundary.wrap("start lookups report", function()
    QuerySession.start_report(report_viewer, LookupsReport.build_prompt(entries, timeframe))
  end))
end

return LookupsReportUI
