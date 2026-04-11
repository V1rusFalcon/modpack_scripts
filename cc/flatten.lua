-- ComputerCraft: Area Flattener – CLIENT
-- Dynamically receives one-column tasks from flatten_server.
-- Fuel and fill material come from the supply chest placed directly IN FRONT
-- of the turtle's start position (global z = +1, same height).
--
-- What this program does for every position in its assigned column:
--   * Removes all blocks above the target surface level.
--   * Places a fill block at the target surface level if the surface is missing.
--   (Deep holes are not backfilled below the surface layer.)
--
-- Setup:
--   Attach a wireless modem to this turtle.
--   ALL turtles start at the SAME position, one block above the target surface,
--   facing along the LENGTH (+z) direction, with the chest directly in front.
--   The work area is to the LEFT or RIGHT (configured on the server).
--   Fill the chest with fill material (stone/cobblestone) and lava buckets.
--   Start flatten_server first, then run this on every turtle.
--   Additional turtles can be added at any time.

local SERVER_PROTOCOL = "modpack_flatten"
local SERVER_HOSTNAME  = "flatten_server"

local FUEL_THRESHOLD  = 1000
local FUEL_TARGET     = 10000
local MAT_THRESHOLD   = 16
local HEARTBEAT_EVERY = 8      -- send HEARTBEAT to server every N turtle operations

-- --------------------------------------------------------------------------
-- Connect to server
-- --------------------------------------------------------------------------
local modem = peripheral.find("modem")
if not modem then error("No modem found! Attach a wireless modem.") end
rednet.open(peripheral.getName(modem))

print("=== Area Flattener Client ===")
print("Looking up server (" .. SERVER_HOSTNAME .. ")...")

local server_id = rednet.lookup(SERVER_PROTOCOL, SERVER_HOSTNAME)
if not server_id then
    error("Server not found! Start flatten_server first.")
end
print("Server found (ID " .. server_id .. ").")

-- --------------------------------------------------------------------------
-- Heartbeat
-- Sent every HEARTBEAT_EVERY turtle operations so the server can detect
-- when this turtle has been removed or has crashed.
-- --------------------------------------------------------------------------
local _hb_count = 0
local function sendHeartbeat()
    _hb_count = (_hb_count + 1) % HEARTBEAT_EVERY
    if _hb_count == 0 then
        rednet.send(server_id, {
            type = "HEARTBEAT",
            fuel = turtle.getFuelLevel(),
        }, SERVER_PROTOCOL)
    end
end

-- --------------------------------------------------------------------------
-- Global position / heading tracking
-- dir: 0=+z  1=+x  2=-z  3=-x
-- --------------------------------------------------------------------------
local px, py, pz = 0, 0, 0
local pdir = 0

local function turnLeft()  turtle.turnLeft();  pdir = (pdir + 3) % 4 end
local function turnRight() turtle.turnRight(); pdir = (pdir + 1) % 4 end

local function face(d)
    local delta = (d - pdir) % 4
    if     delta == 1 then turnRight()
    elseif delta == 2 then turnRight(); turnRight()
    elseif delta == 3 then turnLeft()
    end
end

local function stepForward()
    while not turtle.forward() do turtle.dig(); turtle.attack() end
    if     pdir == 0 then pz = pz + 1
    elseif pdir == 1 then px = px + 1
    elseif pdir == 2 then pz = pz - 1
    else                   px = px - 1
    end
    sendHeartbeat()
end

local function stepUp()
    while not turtle.up() do turtle.digUp(); turtle.attackUp() end
    py = py + 1
end

local function stepDown()
    while not turtle.down() do turtle.digDown(); turtle.attackDown() end
    py = py - 1
end

local function goTo(tx, ty, tz)
    while py < ty do stepUp()   end
    while py > ty do stepDown() end
    if px ~= tx then
        face(px < tx and 1 or 3)
        while px ~= tx do stepForward() end
    end
    if pz ~= tz then
        face(pz < tz and 0 or 2)
        while pz ~= tz do stepForward() end
    end
end

-- --------------------------------------------------------------------------
-- Inventory helpers
-- --------------------------------------------------------------------------
local function countFillBlocks()
    local n = 0
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and not item.name:find("bucket") then
            n = n + turtle.getItemCount(slot)
        end
    end
    return n
end

local function findEmptySlot()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then return slot end
    end
    return nil
end

local function selectFillBlock()
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and not item.name:find("bucket") and turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            return true
        end
    end
    return false
end

-- --------------------------------------------------------------------------
-- Resupply from chest (global 0, 0, +1 — directly in front of turtle start).
-- Coordinates exclusive chest access with the server so multiple turtles
-- do not collide. Blocks until the chest has enough items (waits for a
-- player to refill it if necessary).
-- --------------------------------------------------------------------------
local function resupply()
    local spx, spy, spz, spdir = px, py, pz, pdir
    print(string.format("Resupply: requesting chest (fuel=%d, blocks=%d)...",
        turtle.getFuelLevel(), countFillBlocks()))

    -- 1. Ask the server for exclusive chest access; wait in place until granted.
    rednet.send(server_id, {type = "CHEST_REQUEST"}, SERVER_PROTOCOL)
    print("  Waiting in chest queue...")
    while true do
        local s, m = rednet.receive(SERVER_PROTOCOL, 10)
        if s == nil then
            -- Timeout: re-announce liveness so the server doesn't drop us.
            rednet.send(server_id, {type = "HEARTBEAT", fuel = turtle.getFuelLevel()}, SERVER_PROTOCOL)
        elseif s == server_id and type(m) == "table" and m.type == "CHEST_GRANT" then
            break
        end
    end
    print("  Chest access granted.")

    -- 2. Navigate to the chest.
    goTo(0, 0, 0)
    face(0)  -- face +z; chest is at (0, 0, 1)

    -- 3. Pull items. If the chest is empty, sleep and retry indefinitely
    --    (with periodic heartbeats) until a player refills it.
    while turtle.getFuelLevel() < FUEL_TARGET or countFillBlocks() < MAT_THRESHOLD do
        local slot = findEmptySlot()
        if not slot then break end  -- inventory full — satisfied
        turtle.select(slot)
        if not turtle.suck() then
            -- Chest is empty: wait a few seconds then try again.
            print("  Chest empty, waiting for items...")
            rednet.send(server_id, {type = "HEARTBEAT", fuel = turtle.getFuelLevel()}, SERVER_PROTOCOL)
            os.sleep(3)
        else
            local item = turtle.getItemDetail(slot)
            if item and item.name:find("lava_bucket") then
                turtle.refuel()   -- consumes lava; empty bucket stays in slot
                turtle.drop()     -- return empty bucket to chest
            end
            -- Fill blocks stay in inventory.
        end
    end

    print(string.format("  -> fuel=%d, blocks=%d",
        turtle.getFuelLevel(), countFillBlocks()))

    -- 4. Step back one block before releasing so the next queued turtle can
    --    navigate to (0,0,0) without bumping into us.
    local moved = turtle.back()
    if moved then pz = pz - 1 end

    -- 5. Release the chest for the next turtle in the server queue.
    rednet.send(server_id, {type = "CHEST_DONE"}, SERVER_PROTOCOL)

    -- 6. Return to the original position.
    goTo(spx, spy, spz)
    face(spdir)
end

-- Only check/top-up fuel; used during active work to avoid mid-column
-- material trips to the chest.
local function checkFuel()
    if turtle.getFuelLevel() < FUEL_THRESHOLD then
        resupply()
    end
end

-- --------------------------------------------------------------------------
-- Status reporting
-- --------------------------------------------------------------------------
local function sendStatus(pct)
    rednet.send(server_id, {
        type = "STATUS_UPDATE",
        fuel = turtle.getFuelLevel(),
        pct  = pct,
    }, SERVER_PROTOCOL)
end

-- Remembered from the most recent TASK_ASSIGN (used when parking after NO_MORE_TASKS).
local task_start_side = "left"

-- --------------------------------------------------------------------------
-- Per-position flatten actions
-- --------------------------------------------------------------------------

-- Dig up through any blocks above the current level, then descend back.
local function clearAbove()
    local ascent = 0
    while turtle.detectUp() do
        turtle.digUp()
        stepUp()
        ascent = ascent + 1
    end
    for _ = 1, ascent do stepDown() end
end

-- Place fill below (at surface level) if the surface is missing.
local function fillSurface()
    if not turtle.detectDown() then
        if selectFillBlock() then
            turtle.placeDown()
        else
            print(string.format(
                "Warning: no fill material at (%d, %d) - skipping.", px, pz))
        end
    end
end

-- --------------------------------------------------------------------------
-- Flatten a single column (1 wide x length long strip along +z).
-- col_x:      0-based column index; start_side maps it to a signed global x.
-- --------------------------------------------------------------------------
local function flattenColumn(col_x, length, start_side)
    local gx = (start_side == "left") and -(col_x + 1) or (col_x + 1)
    local processed = 0

    goTo(gx, 0, 0)
    face(0)  -- face +z

    for z = 1, length do
        checkFuel()
        clearAbove()
        fillSurface()
        sendHeartbeat()
        processed = processed + 1
        if processed % 8 == 0 then
            sendStatus(math.floor(processed * 100 / length))
        end
        if z < length then stepForward() end
    end

    goTo(gx, 0, 0)
    sendStatus(100)
end

-- --------------------------------------------------------------------------
-- Main task loop
-- --------------------------------------------------------------------------
-- Initial startup: ensure fuel and at least a minimal stock before first task.
checkFuel()
if countFillBlocks() < MAT_THRESHOLD then resupply() end
print("Requesting first task...")
rednet.send(server_id, {type = "REQUEST_TASK"}, SERVER_PROTOCOL)

while true do
    local sender, msg
    repeat
        sender, msg = rednet.receive(SERVER_PROTOCOL, 60)
        if sender == nil then error("Timeout waiting for task from server.") end
    until sender == server_id and type(msg) == "table"

    if msg.type == "NO_MORE_TASKS" then
        -- Park one block on the opposite side of the work area so other turtles
        -- and the resupply path stay clear.
        local park_x = (task_start_side == "left") and 1 or -1
        print("No more tasks. Parking on opposite side (x=" .. park_x .. ").")
        goTo(park_x, 0, 0)
        face(0)
        print("Parked.")
        break
    end

    if msg.type == "TASK_ASSIGN" then
        local col_x      = msg.col_x
        local length     = msg.length
        local start_side = msg.start_side or task_start_side
        task_start_side  = start_side  -- remember for idle-parking
        print(string.format("Col %d: flatten %d positions (%s).", col_x, length, start_side))
        flattenColumn(col_x, length, start_side)
        print(string.format("Col %d done.", col_x))
        rednet.send(server_id, {type = "TASK_DONE",   col_x = col_x}, SERVER_PROTOCOL)
        -- Drain inventory across columns: only resupply when material is actually low.
        if countFillBlocks() < MAT_THRESHOLD then resupply() end
        rednet.send(server_id, {type = "REQUEST_TASK"}, SERVER_PROTOCOL)
    end
end

print("Done!")
