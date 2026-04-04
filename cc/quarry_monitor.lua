-- ComputerCraft: Quarry monitor display.
-- Run this on a computer that has a modem and a monitor attached.
-- It listens for status broadcasts from quarry_8x8.lua and displays
-- them on the monitor in a scrolling log.

local PROTOCOL = "quarry"

-- Find and open modem -------------------------------------------------------
-- peripheral.find() / peripheral.getName() is the reliable modern
-- CC:Tweaked pattern; it handles multi-type peripherals correctly.
local modemSide = nil
local _modem = peripheral.find("modem")
if not _modem then
    error("No modem found. Attach a modem to this computer.", 0)
end
modemSide = peripheral.getName(_modem)
rednet.open(modemSide)

-- Find monitor --------------------------------------------------------------
local mon = peripheral.find("monitor")
if not mon then
    error("No monitor found. Attach a monitor to this computer.", 0)
end

mon.setTextScale(0.5)
mon.setBackgroundColor(colors.black)
mon.setTextColor(colors.white)
mon.clear()

local monW, monH = mon.getSize()
local contentH = monH - 1  -- rows available below the header
local lines = {}

local function header()
    mon.setCursorPos(1, 1)
    mon.setBackgroundColor(colors.blue)
    mon.setTextColor(colors.white)
    mon.clearLine()
    local title = " Quarry Monitor"
    mon.write(title .. string.rep(" ", monW - #title))
    mon.setBackgroundColor(colors.black)
    lines = {}
end

header()

local function appendLine(msg, color)
    table.insert(lines, {text = msg, color = color or colors.white})
    if #lines > contentH then
        table.remove(lines, 1)
    end
    mon.setBackgroundColor(colors.black)
    for i, entry in ipairs(lines) do
        mon.setCursorPos(1, i + 1)  -- +1 to leave room for header
        mon.setTextColor(entry.color or colors.white)
        local text = entry.text
        if #text > monW then
            text = text:sub(1, monW)
        end
        mon.clearLine()
        mon.write(text)
    end
end

appendLine("Listening on protocol: " .. PROTOCOL, colors.yellow)
appendLine("Modem: " .. modemSide, colors.gray)
appendLine(string.rep("-", monW), colors.gray)

-- Color-code certain keywords in messages.
local function msgColor(msg)
    local lower = msg:lower()
    if lower:find("complete") or lower:find("done") then
        return colors.lime
    elseif lower:find("bedrock") then
        return colors.orange
    elseif lower:find("stopped") or lower:find("warning") or lower:find("error") then
        return colors.red
    elseif lower:find("mining layer") then
        return colors.cyan
    end
    return colors.white
end

-- Main receive loop ---------------------------------------------------------
while true do
    local senderId, message, protocol = rednet.receive(PROTOCOL)
    if type(message) == "string" then
        local prefix = "[" .. senderId .. "] "
        appendLine(prefix .. message, msgColor(message))
    end
end
