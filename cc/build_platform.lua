-- ComputerCraft: Platform builder – CLIENT
-- Dynamically receives one-column tasks from platform_server.
-- All building material and lava bucket fuel come from the supply chest placed
-- directly behind turtle 1's start position (global z = -1, same height).
--
-- Setup:
--   Attach a wireless modem to this turtle.
--   ALL turtles start at the SAME bottom-left corner, one block above ground,
--   facing along the LENGTH (+z) direction.
--   Place the supply chest one block behind turtle 1 (at z = -1).
--   Fill it with stone/cobblestone and lava buckets.
--   Start platform_server first, then run this on every turtle.
--   Additional turtles can be added at any time — just start them the same way.

local SERVER_PROTOCOL = "modpack_platform"
local SERVER_HOSTNAME  = "platform_server"

local FUEL_THRESHOLD = 500    -- go resupply when fuel drops below this
local FUEL_TARGET    = 10000  -- desired fuel level after resupply
local MAT_THRESHOLD  = 16     -- go restock when fewer than this many blocks remain

-- --------------------------------------------------------------------------
-- Connect to server
-- --------------------------------------------------------------------------
local modem = peripheral.find("modem")
if not modem then error("No modem found! Attach a wireless modem.") end
rednet.open(peripheral.getName(modem))

print("=== Platform Builder Client ===")
print("Looking up server (" .. SERVER_HOSTNAME .. ")...")

local server_id = rednet.lookup(SERVER_PROTOCOL, SERVER_HOSTNAME)
if not server_id then
    error("Server not found! Start platform_server first.")
end
print("Server found (ID " .. server_id .. ").")

-- --------------------------------------------------------------------------
-- Global position / heading tracking
-- All turtles share the same origin (0, 0, 0).
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

-- Count non-bucket items (building blocks).
local function countBuildBlocks()
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

-- Select a non-bucket slot to place; returns true on success.
local function selectBuildBlock()
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
-- Resupply from the supply chest (global 0, 0, -1 — directly behind turtle 1)
-- Refuels with lava buckets (returns empty bucket to chest).
-- Restocks building blocks (stone / cobblestone).
-- --------------------------------------------------------------------------
local function resupply()
    local spx, spy, spz, spdir = px, py, pz, pdir
    print(string.format("Resupply (fuel=%d, blocks=%d)…",
        turtle.getFuelLevel(), countBuildBlocks()))

    goTo(0, 0, 0)
    face(2)  -- face -z so the chest at (0, 0, -1) is directly in front

    local loops = 0
    while (turtle.getFuelLevel() < FUEL_TARGET or countBuildBlocks() < MAT_THRESHOLD)
          and loops < 64 do
        local slot = findEmptySlot()
        if not slot then break end      -- inventory full
        turtle.select(slot)
        if not turtle.suck() then break end   -- chest empty or inaccessible

        local item = turtle.getItemDetail(slot)
        if item and item.name:find("lava_bucket") then
            turtle.refuel()   -- consumes lava; empty bucket stays in slot
            turtle.drop()     -- return empty bucket to the chest
        end
        -- Stone / cobblestone stays in inventory for building.
        loops = loops + 1
    end

    print(string.format("  → fuel=%d, blocks=%d",
        turtle.getFuelLevel(), countBuildBlocks()))
    goTo(spx, spy, spz)
    face(spdir)
end

local function checkResupply()
    if turtle.getFuelLevel() < FUEL_THRESHOLD or countBuildBlocks() < MAT_THRESHOLD then
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

-- --------------------------------------------------------------------------
-- Build a single column (1 wide × length long × layers tall).
-- Turtle navigates to (col_x, 0, 0) then builds each layer upward,
-- placing blocks below itself in a straight row along +z.
-- --------------------------------------------------------------------------
local function buildColumn(col_x, length, layers)
    local total = length * layers
    local placed = 0

    for layer = 1, layers do
        checkResupply()
        goTo(col_x, layer - 1, 0)
        face(0)  -- face +z along length

        for z = 1, length do
            checkResupply()
            while not selectBuildBlock() do resupply() end
            turtle.placeDown()
            placed = placed + 1
            if placed % 16 == 0 then
                sendStatus(math.floor(placed * 100 / total))
            end
            if z < length then stepForward() end
        end

        -- Return to column-start at this height before ascending.
        goTo(col_x, layer - 1, 0)
    end

    sendStatus(100)
end

-- --------------------------------------------------------------------------
-- Main task loop — keep requesting columns until the server has no more
-- --------------------------------------------------------------------------
checkResupply()
print("Requesting first task…")
rednet.send(server_id, {type = "REQUEST_TASK"}, SERVER_PROTOCOL)

while true do
    local sender, msg
    repeat
        sender, msg = rednet.receive(SERVER_PROTOCOL, 60)
        if sender == nil then error("Timeout waiting for task from server.") end
    until sender == server_id and type(msg) == "table"

    if msg.type == "NO_MORE_TASKS" then
        print("No more tasks. Returning to base.")
        break
    end

    if msg.type == "TASK_ASSIGN" then
        local col_x  = msg.col_x
        local length = msg.length
        local layers = msg.layers
        print(string.format("Col %d: %d × %d blocks.", col_x, length, layers))
        buildColumn(col_x, length, layers)
        print(string.format("Col %d done.", col_x))
        rednet.send(server_id, {type = "TASK_DONE",   col_x = col_x}, SERVER_PROTOCOL)
        rednet.send(server_id, {type = "REQUEST_TASK"},               SERVER_PROTOCOL)
    end
end

goTo(0, 0, 0)
face(0)
print("Done!")
