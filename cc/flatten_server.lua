-- ComputerCraft: Area Flattener Server
-- Dynamic multi-turtle coordination: turtles may join at any time.
-- Work is assigned one column at a time; finished turtles request new columns
-- automatically until the queue is empty.
--
-- Setup:
--   Attach a wireless modem (and optionally a monitor) to this computer.
--   Run this server first, then run flatten.lua on each turtle.
--   ALL turtles start at the SAME corner, one block above the target surface,
--   facing along the LENGTH (+z) direction.
--   Place a chest directly behind turtle 1 (z = -1, same height).
--   Fill it with fill material (stone/cobblestone) and lava buckets.

local SERVER_PROTOCOL = "modpack_flatten"
local SERVER_HOSTNAME  = "flatten_server"

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
    monitor.write("Area Flattener starting...")
end

-- --------------------------------------------------------------------------
-- Parameters
-- --------------------------------------------------------------------------
print("=== Area Flattener Server ===")
print("Chest: fill material + lava buckets, behind turtle 1 (z = -1).")
print("")
local WIDTH         = readNumber("Total width  (x, perpendicular to facing)", 10)
local LENGTH        = readNumber("Length (z, along turtles' facing)",         10)
local TARGET_HEIGHT = readNumber("Target surface height (for reference)",       5)

-- --------------------------------------------------------------------------
-- Work queue: one entry per column (global x = 0 … WIDTH-1)
-- --------------------------------------------------------------------------
local work_queue    = {}
local in_progress   = {}
local done_count    = 0
local turtle_status = {}

for x = 0, WIDTH - 1 do
    work_queue[#work_queue + 1] = x
end

print(string.format(
    "\nJob: flatten %d × %d to height %d (%d column tasks). Listening…",
    WIDTH, LENGTH, TARGET_HEIGHT, WIDTH))

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
    mp("=== Area Flattener ===")
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
                    type          = "TASK_ASSIGN",
                    col_x         = col_x,
                    length        = LENGTH,
                    target_height = TARGET_HEIGHT,
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
        refreshMonitor()
    end
end

-- --------------------------------------------------------------------------
-- Finished
-- --------------------------------------------------------------------------
print("Flattening complete!")
if monitor then
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("=== FLATTEN COMPLETE ===")
    monitor.setCursorPos(1, 2)
    monitor.write(string.format("%d x %d area done!", WIDTH, LENGTH))
end
rednet.unhost(SERVER_PROTOCOL)
