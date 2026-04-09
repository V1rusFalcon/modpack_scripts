-- ComputerCraft: Platform builder – CLIENT
-- Dynamically receives one-column tasks from platform_server.
-- All building material and lava bucket fuel come from the supply chest placed
-- directly IN FRONT of the turtle's start position (global z = +1, same height).
--
-- Setup:
--   Attach a wireless modem to this turtle.
--   ALL turtles start at the SAME position, one block above the build surface,
--   facing along the LENGTH (+z) direction, with the chest directly in front.
--   The work area is to the LEFT or RIGHT (configured on the server).
--   Fill the chest with stone/cobblestone, dirt, and lava buckets.
--   Start platform_server first, then run this on every turtle.
--   Additional turtles can be added at any time — just start them the same way.

local SERVER_PROTOCOL = "modpack_platform"
local SERVER_HOSTNAME  = "platform_server"

local FUEL_THRESHOLD  = 1000   -- go resupply when fuel drops below this
local FUEL_TARGET     = 10000  -- desired fuel level after resupply
local MAT_THRESHOLD   = 16     -- go restock when fewer than this many blocks remain
local HEARTBEAT_EVERY = 8      -- send HEARTBEAT to server every N turtle operations

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
-- Material type helpers
-- "stone" matches cobblestone, stone, granite, andesite, diorite, deepslate …
-- "dirt"  matches dirt, grass_block, podzol, mud …
-- --------------------------------------------------------------------------
local STONE_PATTERNS = {"cobble", "stone", "granite", "diorite", "andesite", "deepslate", "blackstone", "smooth"}
local DIRT_PATTERNS  = {"dirt", "grass", "podzol", "mycelium", "mud"}

local function matchesMat(name, patterns)
    for _, p in ipairs(patterns) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

-- Count non-bucket items of a given type ("stone", "dirt") or all if type is nil.
local function countBuildBlocks(mattype)
    local n = 0
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and not item.name:find("bucket") then
            local nm = item.name:lower()
            if mattype == nil
               or (mattype == "stone" and matchesMat(nm, STONE_PATTERNS))
               or (mattype == "dirt"  and matchesMat(nm, DIRT_PATTERNS)) then
                n = n + turtle.getItemCount(slot)
            end
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

-- Select a block matching mattype ("stone" or "dirt"); returns true on success.
local function selectBlockByType(mattype)
    local patterns = (mattype == "dirt") and DIRT_PATTERNS or STONE_PATTERNS
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and turtle.getItemCount(slot) > 0 then
            local nm = item.name:lower()
            if not nm:find("bucket") and matchesMat(nm, patterns) then
                turtle.select(slot)
                return true
            end
        end
    end
    return false
end

-- --------------------------------------------------------------------------
-- Resupply from the supply chest (global 0, 0, +1 — directly in front).
-- Refuels with lava buckets (empty buckets are left inside the chest).
-- Restocks building blocks (stone, dirt, …).
-- --------------------------------------------------------------------------
local function resupply()
    local spx, spy, spz, spdir = px, py, pz, pdir
    print(string.format("Resupply (fuel=%d, stone=%d, dirt=%d)…",
        turtle.getFuelLevel(), countBuildBlocks("stone"), countBuildBlocks("dirt")))

    goTo(0, 0, 0)
    face(0)  -- face +z so the chest at (0, 0, 1) is directly in front

    local loops = 0
    while (turtle.getFuelLevel() < FUEL_TARGET or countBuildBlocks() < MAT_THRESHOLD)
          and loops < 64 do
        local slot = findEmptySlot()
        if not slot then break end      -- inventory full
        turtle.select(slot)
        if not turtle.suck() then break end   -- chest empty or inaccessible

        local item = turtle.getItemDetail(slot)
        if item and item.name:find("lava_bucket") then
            turtle.refuel()   -- consumes lava; empty bucket stays in the slot
            turtle.drop()     -- return empty bucket to the chest
        end
        -- Stone / dirt / cobblestone stays in inventory for building.
        loops = loops + 1
    end

    print(string.format("  → fuel=%d, stone=%d, dirt=%d",
        turtle.getFuelLevel(), countBuildBlocks("stone"), countBuildBlocks("dirt")))
    goTo(spx, spy, spz)
    face(spdir)
end

-- Only check/top-up fuel; used during active building to avoid mid-column
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
-- Build a single column (1 wide × length long × #layers tall).
-- col_x:           0-based column index from the server queue.
-- layer_materials: array of "stone"/"dirt" per layer (index = layer number).
-- start_side:      "left" or "right" — which side of origin the work area is on.
-- build_dir:       "up" (layers stack upward) or "down" (layers go deeper).
-- --------------------------------------------------------------------------
local function buildColumn(col_x, length, layer_materials, start_side, build_dir)
    local layers  = #layer_materials
    local gx      = (start_side == "left") and -(col_x + 1) or (col_x + 1)
    local y_sign  = (build_dir  == "up")   and  1           or -1
    local total   = length * layers
    local placed  = 0

    for layer = 1, layers do
        local mattype = layer_materials[layer] or "stone"
        checkFuel()
        goTo(gx, y_sign * (layer - 1), 0)
        face(0)  -- face +z along length

        for z = 1, length do
            checkFuel()
            -- Only resupply if this specific material type is completely exhausted.
            while not selectBlockByType(mattype) do resupply() end
            turtle.placeDown()
            sendHeartbeat()
            placed = placed + 1
            if placed % 16 == 0 then
                sendStatus(math.floor(placed * 100 / total))
            end
            if z < length then stepForward() end
        end

        -- Return to column-start at this height before ascending/descending.
        goTo(gx, y_sign * (layer - 1), 0)
    end

    sendStatus(100)
end

-- --------------------------------------------------------------------------
-- Main task loop — keep requesting columns until the server has no more
-- --------------------------------------------------------------------------
-- Initial startup: ensure fuel and at least a minimal stock before first task.
checkFuel()
if countBuildBlocks() < MAT_THRESHOLD then resupply() end
print("Requesting first task…")
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
        local layer_mats = msg.layer_materials or {"stone"}
        local start_side = msg.start_side      or task_start_side
        local build_dir  = msg.build_dir        or "up"
        task_start_side  = start_side  -- remember for idle-parking
        print(string.format("Col %d: %d positions × %d layers (%s, %s).",
            col_x, length, #layer_mats, start_side, build_dir))
        buildColumn(col_x, length, layer_mats, start_side, build_dir)
        print(string.format("Col %d done.", col_x))
        rednet.send(server_id, {type = "TASK_DONE", col_x = col_x}, SERVER_PROTOCOL)
        -- Drain inventory across columns: only resupply when material is actually low.
        if countBuildBlocks() < MAT_THRESHOLD then resupply() end
        rednet.send(server_id, {type = "REQUEST_TASK"}, SERVER_PROTOCOL)
    end
end

print("Done!")
