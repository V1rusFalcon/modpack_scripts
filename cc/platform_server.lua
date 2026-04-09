-- ComputerCraft: Platform Builder Server
-- Dynamic multi-turtle coordination: turtles may join at any time.
-- Work is assigned one column at a time from a queue; finished turtles
-- request new columns automatically until the queue is empty.
--
-- Setup:
--   Attach a wireless modem (and optionally a monitor) to this computer.
--   Run this server first, then run build_platform.lua on each turtle.
--   ALL turtles start at the SAME bottom-left corner, one block above ground,
--   facing along the LENGTH (+z) direction.
--   Place a chest directly behind turtle 1 (one block in the -z direction,
--   same height). Fill it with stone/cobblestone and lava buckets.

local SERVER_PROTOCOL = "modpack_platform"
local SERVER_HOSTNAME  = "platform_server"

-- --------------------------------------------------------------------------
-- Prompt helper
-- --------------------------------------------------------------------------
local function readNumber(prompt, default)
    while true do
        io.write(prompt .. " [" .. tostring(default) .. "]: ")
        local line = io.read()
        if line == nil or line == "" then return default end
        local n = tonumber(line)
        if n and n > 0 and math.floor(n) == n then return math.floor(n) end
        print("Please enter a positive whole number.")
    end
end

-- --------------------------------------------------------------------------
-- Peripherals
-- --------------------------------------------------------------------------
local modem = peripheral.find("modem")
if not modem then error("No modem found! Attach a wireless modem.") end
rednet.open(peripheral.getName(modem))
rednet.host(SERVER_PROTOCOL, SERVER_HOSTNAME)

local monitor = peripheral.find("monitor")
if monitor then
    monitor.setTextScale(0.5)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Platform Builder starting...")
end

-- --------------------------------------------------------------------------
-- Parameters
-- --------------------------------------------------------------------------
print("=== Platform Builder Server ===")
print("Chest: stone/cobblestone + lava buckets, behind turtle 1 (z = -1).")
print("")
local WIDTH  = readNumber("Total width  (x, perpendicular to facing)", 10)
local LENGTH = readNumber("Length (z, along turtles' facing)",         10)
local LAYERS = readNumber("Total platform layers",                       5)

-- --------------------------------------------------------------------------
-- Work queue: one entry per column (global x = 0 … WIDTH-1)
-- --------------------------------------------------------------------------
local work_queue    = {}     -- unassigned column x-indices
local in_progress   = {}     -- [turtle_id] = col_x currently building
local done_count    = 0
local turtle_status = {}     -- [turtle_id] = {fuel, pct, idle}

for x = 0, WIDTH - 1 do
    work_queue[#work_queue + 1] = x
end

print(string.format(
    "\nJob: %d × %d × %d (%d column tasks). Listening for turtles…",
    WIDTH, LENGTH, LAYERS, WIDTH))

-- --------------------------------------------------------------------------
-- Monitor refresh
-- --------------------------------------------------------------------------
local function refreshMonitor()
    if not monitor then return end
    monitor.clear()
    local row = 1
    local function mp(text)
        monitor.setCursorPos(1, row)
        monitor.write(tostring(text))
        row = row + 1
    end
    local total_pct = math.floor(done_count * 100 / math.max(1, WIDTH))
    local bar_w = 26
    local filled = math.floor(done_count * bar_w / math.max(1, WIDTH))
    mp("=== Platform Builder ===")
    mp(string.format("Done: %d/%d cols  %d%%", done_count, WIDTH, total_pct))
    mp("[" .. string.rep("#", filled) .. string.rep("-", bar_w - filled) .. "]")
    mp("")
    for id, st in pairs(turtle_status) do
        local label = st.idle and "idle" or string.format("%3d%%", st.pct)
        mp(string.format("T%-4d Fuel:%-6d %s", id, st.fuel, label))
    end
end

-- --------------------------------------------------------------------------
-- Main event loop
-- --------------------------------------------------------------------------
while done_count < WIDTH do
    local sender, msg = rednet.receive(SERVER_PROTOCOL, 5)

    if sender and type(msg) == "table" then

        if msg.type == "REQUEST_TASK" then
            if not turtle_status[sender] then
                turtle_status[sender] = {fuel = 0, pct = 0, idle = false}
                print("New turtle: " .. sender)
            end
            if #work_queue > 0 then
                local col_x = table.remove(work_queue, 1)
                in_progress[sender] = col_x
                turtle_status[sender].pct  = 0
                turtle_status[sender].idle = false
                rednet.send(sender, {
                    type   = "TASK_ASSIGN",
                    col_x  = col_x,
                    length = LENGTH,
                    layers = LAYERS,
                }, SERVER_PROTOCOL)
                print(string.format(
                    "  Turtle %d → col %d  (%d left)", sender, col_x, #work_queue))
            else
                turtle_status[sender].idle = true
                rednet.send(sender, {type = "NO_MORE_TASKS"}, SERVER_PROTOCOL)
                print(string.format("  Turtle %d: no more tasks.", sender))
            end

        elseif msg.type == "TASK_DONE" then
            if in_progress[sender] ~= nil then
                in_progress[sender] = nil
                done_count = done_count + 1
                if turtle_status[sender] then
                    turtle_status[sender].pct  = 100
                    turtle_status[sender].idle = true
                end
                print(string.format(
                    "  Turtle %d done. (%d/%d)", sender, done_count, WIDTH))
            end

        elseif msg.type == "STATUS_UPDATE" then
            if turtle_status[sender] then
                turtle_status[sender].fuel = msg.fuel or 0
                turtle_status[sender].pct  = msg.pct  or 0
                turtle_status[sender].idle = false
            end
        end

        refreshMonitor()
    else
        refreshMonitor()   -- periodic refresh on timeout
    end
end

-- --------------------------------------------------------------------------
-- Finished
-- --------------------------------------------------------------------------
print("Platform complete!")
if monitor then
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("=== PLATFORM COMPLETE ===")
    monitor.setCursorPos(1, 2)
    monitor.write(string.format("%d x %d x %d built!", WIDTH, LENGTH, LAYERS))
end
rednet.unhost(SERVER_PROTOCOL)
