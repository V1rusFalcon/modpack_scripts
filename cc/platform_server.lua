-- ComputerCraft: Platform Builder Server
-- Dynamic multi-turtle coordination: turtles may join at any time.
-- Work is assigned one column at a time from a queue; finished turtles
-- request new columns automatically until the queue is empty.
--
-- Setup:
--   Attach a wireless modem (and optionally a monitor) to this computer.
--   Run this server first, then run build_platform.lua on each turtle.
--   ALL turtles start at the SAME position, one block above the build surface,
--   facing along the LENGTH (+z) direction, with the supply chest directly in
--   front of them (+z, same height).
--   The work area is to the LEFT or RIGHT of the turtles' start position
--   (choose when the server starts).
--   Fill the chest with stone/cobblestone and lava buckets.

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

local function readChoice(prompt, choices, default)
    while true do
        io.write(prompt .. " [" .. table.concat(choices, "/") .. "] (" .. default .. "): ")
        local line = io.read()
        if line == nil or line == "" then return default end
        line = line:lower()
        for _, c in ipairs(choices) do
            if line == c then return c end
        end
        print("Please enter one of: " .. table.concat(choices, ", ") .. ".")
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
print("Turtles face +z; chest is directly in front of them (+z).")
print("Work area is to the LEFT or RIGHT of the turtles' start position.")
print("")
local WIDTH        = readNumber("Total width  (x, perpendicular to facing)",    10)
local LENGTH       = readNumber("Length (z, along turtles' facing)",             10)
local STONE_LAYERS = readNumber("Stone layers (bottom of platform)",              3)
local DIRT_LAYERS  = readNumber("Dirt layers  (top of platform)",                 2)
local LAYERS       = STONE_LAYERS + DIRT_LAYERS
local START_SIDE   = readChoice("Work area side (left/right of turtle start)",  {"left","right"}, "left")
local BUILD_DIR    = readChoice("Build direction (up=terrain, down=water/void)", {"up","down"},   "up")

local layer_materials = {}
for i = 1, STONE_LAYERS do layer_materials[i] = "stone" end
for i = 1, DIRT_LAYERS  do layer_materials[STONE_LAYERS + i] = "dirt" end

-- --------------------------------------------------------------------------
-- Work queue: one entry per column (global x = 0 … WIDTH-1)
-- --------------------------------------------------------------------------
local work_queue       = {}     -- unassigned column x-indices
local in_progress      = {}     -- [turtle_id] = col_x currently building
local done_count       = 0
local turtle_status    = {}     -- [turtle_id] = {fuel, pct, layer, idle}
local last_seen        = {}     -- [turtle_id] = os.epoch("utc")/1000 of last message
local HEARTBEAT_TIMEOUT = 30    -- seconds of silence before a turtle is considered dead

-- Chest access queue: only one turtle may use the chest at a time.
local chest_queue  = {}   -- ordered list of turtle IDs waiting for access
local chest_in_use = nil  -- turtle ID currently at the chest, or nil

for x = 0, WIDTH - 1 do
    work_queue[#work_queue + 1] = x
end

print(string.format(
    "\nJob: %d × %d, %d stone + %d dirt layers (%d col tasks, %s, %s). Listening for turtles…",
    WIDTH, LENGTH, STONE_LAYERS, DIRT_LAYERS, WIDTH, START_SIDE, BUILD_DIR))

-- --------------------------------------------------------------------------
-- Chest queue helper — grant access to the next waiting turtle if free.
-- --------------------------------------------------------------------------
local function tryGrantChest()
    if chest_in_use == nil and #chest_queue > 0 then
        chest_in_use = table.remove(chest_queue, 1)
        rednet.send(chest_in_use, {type = "CHEST_GRANT"}, SERVER_PROTOCOL)
        print(string.format("  Chest → turtle %d  (%d still waiting)", chest_in_use, #chest_queue))
    end
end

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
    -- Chest status line
    if chest_in_use then
        local s = "Chest: T" .. chest_in_use
        if #chest_queue > 0 then s = s .. " (+" .. #chest_queue .. " wait)" end
        mp(s)
    else
        mp("Chest: free")
    end
    mp("")
    -- Build a quick lookup: turtle id → chest queue position (0 = in use)
    local chest_pos = {}
    if chest_in_use then chest_pos[chest_in_use] = 0 end
    for i, id in ipairs(chest_queue) do chest_pos[id] = i end
    local now_ts = os.epoch("utc") / 1000
    local any_low_fuel = false
    for id, st in pairs(turtle_status) do
        local age = last_seen[id] and (now_ts - last_seen[id]) or 999
        local label
        if age > HEARTBEAT_TIMEOUT then
            label = "DEAD"
        elseif st.idle then
            label = "idle"
        else
            label = string.format("%3d%%", st.pct)
        end
        local fuel_tag = (st.fuel < 1000 and not st.idle) and "!" or " "
        if st.fuel < 1000 and not st.idle then any_low_fuel = true end
        -- Task column / chest position tag
        local col_info
        if chest_pos[id] == 0 then
            col_info = "CHEST"
        elseif chest_pos[id] then
            col_info = "Q" .. chest_pos[id]
        elseif in_progress[id] ~= nil then
            local lyr = st.layer and ("L" .. st.layer) or ""
            col_info = "C" .. tostring(in_progress[id]) .. lyr
        else
            col_info = "----"
        end
        mp(string.format("T%-3d%s F:%-5d %-5s %s", id, fuel_tag, st.fuel, col_info, label))
    end
    if any_low_fuel then mp("*** ADD FUEL! ***") end
end

-- --------------------------------------------------------------------------
-- Main event loop
-- Keep running until all columns are done AND the chest queue is fully drained,
-- so no turtle is left waiting for a CHEST_GRANT after tasks complete.
-- --------------------------------------------------------------------------
while done_count < WIDTH or chest_in_use ~= nil or #chest_queue > 0 do
    local sender, msg = rednet.receive(SERVER_PROTOCOL, 5)

    if sender and type(msg) == "table" then
        -- Any message counts as proof the turtle is alive.
        last_seen[sender] = os.epoch("utc") / 1000

        if msg.type == "REQUEST_TASK" then
            if not turtle_status[sender] then
                turtle_status[sender] = {fuel = 0, pct = 0, layer = nil, idle = false}
                print("New turtle: " .. sender)
            end
            if #work_queue > 0 then
                local col_x = table.remove(work_queue, 1)
                in_progress[sender] = col_x
                turtle_status[sender].pct   = 0
                turtle_status[sender].layer = 1
                turtle_status[sender].idle  = false
                rednet.send(sender, {
                    type            = "TASK_ASSIGN",
                    col_x           = col_x,
                    length          = LENGTH,
                    layers          = LAYERS,
                    layer_materials = layer_materials,
                    start_side      = START_SIDE,
                    build_dir       = BUILD_DIR,
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
                    turtle_status[sender].pct   = 100
                    turtle_status[sender].layer = nil
                    turtle_status[sender].idle  = true
                end
                print(string.format(
                    "  Turtle %d done. (%d/%d)", sender, done_count, WIDTH))
            end

        elseif msg.type == "CHEST_REQUEST" then
            -- Guard against duplicate entries (e.g. turtle retried the request).
            local already = (chest_in_use == sender)
            for _, id in ipairs(chest_queue) do
                if id == sender then already = true; break end
            end
            if not already then
                chest_queue[#chest_queue + 1] = sender
                print(string.format("  Turtle %d: chest request (queue: %d)", sender, #chest_queue))
                tryGrantChest()
            end

        elseif msg.type == "CHEST_DONE" then
            if chest_in_use == sender then
                chest_in_use = nil
                print(string.format("  Turtle %d: chest done.", sender))
                tryGrantChest()
            end

        elseif msg.type == "STATUS_UPDATE" then
            if turtle_status[sender] then
                turtle_status[sender].fuel  = msg.fuel  or 0
                turtle_status[sender].pct   = msg.pct   or 0
                turtle_status[sender].layer = msg.layer or turtle_status[sender].layer
                turtle_status[sender].idle  = false
            end

        elseif msg.type == "HEARTBEAT" then
            if turtle_status[sender] then
                turtle_status[sender].fuel = msg.fuel or turtle_status[sender].fuel
            end
        end

        refreshMonitor()
    else
        -- Poll timeout: check for turtles that have gone silent.
        local now = os.epoch("utc") / 1000
        local dead = {}
        for id, _ in pairs(in_progress) do
            if last_seen[id] == nil or (now - last_seen[id]) > HEARTBEAT_TIMEOUT then
                dead[#dead + 1] = id
            end
        end
        for _, id in ipairs(dead) do
            local col_x = in_progress[id]
            print(string.format("  Turtle %d timed out! Re-queuing col %d.", id, col_x))
            table.insert(work_queue, 1, col_x)
            in_progress[id] = nil
            if turtle_status[id] then
                turtle_status[id].pct  = 0
                turtle_status[id].idle = false
            end
            -- Release the chest if this dead turtle was holding or waiting for it.
            if chest_in_use == id then
                chest_in_use = nil
                print(string.format("  Turtle %d released chest (timed out).", id))
                tryGrantChest()
            end
            for i = #chest_queue, 1, -1 do
                if chest_queue[i] == id then table.remove(chest_queue, i) end
            end
        end
        refreshMonitor()
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
    monitor.write(string.format("%dx%dx%d (%dst+%ddi)!", WIDTH, LENGTH, LAYERS, STONE_LAYERS, DIRT_LAYERS))
end
rednet.unhost(SERVER_PROTOCOL)
