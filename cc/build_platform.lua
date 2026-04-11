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
local MAT_TARGET      = 64     -- max blocks of each type to carry (one stack each)
local HEARTBEAT_EVERY = 8      -- send HEARTBEAT to server every N turtle operations

-- --------------------------------------------------------------------------
-- Monitor display (optional — attach a monitor to any side of the turtle)
-- --------------------------------------------------------------------------
local mon = peripheral.find("monitor")
if mon then
    mon.setTextScale(0.5)
    mon.clear()
end

-- Global completion percentage (0-100); updated by sendStatus during building.
local g_pct = 0

local function setStatus(state, task)
    -- Always print to the terminal as well so it shows in server logs.
    print(string.format("[STATUS] %s | %s", state, task or ""))
    if not mon then return end
    mon.clear()
    mon.setCursorPos(1, 1)
    mon.write("Turtle #" .. os.getComputerID())
    mon.setCursorPos(1, 2)
    mon.write("State: " .. state)
    mon.setCursorPos(1, 3)
    mon.write("Task:  " .. (task or ""))
    mon.setCursorPos(1, 4)
    mon.write("Fuel:  " .. turtle.getFuelLevel())
    mon.setCursorPos(1, 5)
    mon.write("Done:  " .. g_pct .. "%")
end

-- --------------------------------------------------------------------------
-- Connect to server
-- --------------------------------------------------------------------------
setStatus("STARTUP", "Finding modem — need wireless to reach server")
local modem = peripheral.find("modem")
if not modem then error("No modem found! Attach a wireless modem.") end
rednet.open(peripheral.getName(modem))

print("=== Platform Builder Client ===")
print("Looking up server (" .. SERVER_HOSTNAME .. ")...")
setStatus("STARTUP", "Looking up server — need task coordinator")

local server_id = rednet.lookup(SERVER_PROTOCOL, SERVER_HOSTNAME)
if not server_id then
    error("Server not found! Start platform_server first.")
end
print("Server found (ID " .. server_id .. ").")

-- Notify the server to clear any memorised state from a previous run of
-- this turtle (e.g. after a crash or manual reset).
setStatus("STARTUP", "Resetting server state — clearing previous run")
rednet.send(server_id, {type = "RESET"}, SERVER_PROTOCOL)
print("Server state reset sent.")

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
    if not turtle.down() then
        print(string.format("  [dbg] stepDown blocked at (%d,%d,%d) — digging", px, py, pz))
        while not turtle.down() do turtle.digDown(); turtle.attackDown() end
    end
    py = py - 1
end

-- Move X, then Y, then Z — but when descending, move X first so the turtle
-- leaves the built column before going down (prevents digging own blocks).
local function goTo(tx, ty, tz)
    print(string.format("  [dbg] goTo (%d,%d,%d) → (%d,%d,%d)", px, py, pz, tx, ty, tz))
    if py > ty then
        -- Descending: step off the column sideways before going down.
        if px ~= tx then
            face(px < tx and 1 or 3)
            while px ~= tx do stepForward() end
        end
        while py > ty do stepDown() end
        if pz ~= tz then
            face(pz < tz and 0 or 2)
            while pz ~= tz do stepForward() end
        end
    else
        -- Ascending or level: go up first (above any blocks), then X, then Z.
        while py < ty do stepUp() end
        if px ~= tx then
            face(px < tx and 1 or 3)
            while px ~= tx do stepForward() end
        end
        if pz ~= tz then
            face(pz < tz and 0 or 2)
            while pz ~= tz do stepForward() end
        end
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
-- Drop excess / unwanted items back into the chest the turtle is facing.
-- Keeps at most MAT_TARGET stone-type and MAT_TARGET dirt-type blocks;
-- returns everything else (empty buckets, unrecognised items, overstock).
-- Only call while the turtle is positioned and facing the supply chest.
-- --------------------------------------------------------------------------
local function cleanInventory()
    local stone_kept = 0
    local dirt_kept  = 0
    for s = 1, 16 do
        local item = turtle.getItemDetail(s)
        if item then
            local nm  = item.name:lower()
            local cnt = turtle.getItemCount(s)
            if matchesMat(nm, STONE_PATTERNS) then
                local keep = math.max(0, MAT_TARGET - stone_kept)
                if keep == 0 then
                    turtle.select(s); turtle.drop()
                elseif cnt > keep then
                    turtle.select(s); turtle.drop(cnt - keep)
                end
                stone_kept = stone_kept + math.min(cnt, keep)
            elseif matchesMat(nm, DIRT_PATTERNS) then
                local keep = math.max(0, MAT_TARGET - dirt_kept)
                if keep == 0 then
                    turtle.select(s); turtle.drop()
                elseif cnt > keep then
                    turtle.select(s); turtle.drop(cnt - keep)
                end
                dirt_kept = dirt_kept + math.min(cnt, keep)
            else
                -- Empty bucket, unrecognised item — return to chest.
                turtle.select(s); turtle.drop()
            end
        end
    end
end

-- --------------------------------------------------------------------------
-- Resupply from the supply chest (global 0, 0, +1 — directly in front).
-- Coordinates exclusive chest access with the server so multiple turtles
-- do not collide. Blocks until the chest has enough items (waits for a
-- player to refill it if necessary).
-- --------------------------------------------------------------------------
local function resupply()
    local spx, spy, spz, spdir = px, py, pz, pdir
    print(string.format("Resupply: requesting chest (fuel=%d, stone=%d, dirt=%d)…",
        turtle.getFuelLevel(), countBuildBlocks("stone"), countBuildBlocks("dirt")))
    setStatus("RESUPPLY", "Requesting chest access")

    -- 1. Ask the server for exclusive chest access; wait in place until granted.
    rednet.send(server_id, {type = "CHEST_REQUEST"}, SERVER_PROTOCOL)
    print("  Waiting in chest queue…")
    setStatus("RESUPPLY", "Waiting in chest queue")
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
    setStatus("RESUPPLY", "Navigating to chest")

    -- 2. Navigate to the chest.
    goTo(0, 0, 0)
    face(2)  -- face -z so the supply chest at (0, 0, -1) is directly in front

    -- 3. Wrap the chest peripheral so we can inspect its full inventory
    --    (works for chests of any size, not just 27 slots).
    local chest = peripheral.wrap("front")
    print("[DBG] peripheral.wrap('front') = " .. tostring(chest))
    if not chest then
        error("No chest peripheral found in front at (0,0,-1)!")
    end
    local chest_size = chest.size()
    print("[DBG] chest.size() = " .. tostring(chest_size))
    setStatus("RESUPPLY", "At chest (size=" .. chest_size .. ")")

    -- 4. Use chest.pushItems to pull exactly what is needed — by slot and count —
    --    so the turtle never accidentally receives empty buckets or overstock.
    --    chest.pushItems(targetName, fromSlot, limit, toSlot) returns the
    --    number of items actually moved. The turtle's peripheral name is
    --    "turtle_<id>" as seen by other peripherals on the wired network.
    local turtle_name = "turtle_" .. os.getComputerID()

    -- Loop until all needs are satisfied or we must wait for a player refill.
    while turtle.getFuelLevel() < FUEL_TARGET
          or countBuildBlocks("stone") < MAT_TARGET
          or countBuildBlocks("dirt")  < MAT_TARGET do

        local need_fuel  = turtle.getFuelLevel() < FUEL_TARGET
        local need_stone = MAT_TARGET - countBuildBlocks("stone")
        local need_dirt  = MAT_TARGET - countBuildBlocks("dirt")

        -- Snapshot the chest once per outer iteration.
        local items      = chest.list()
        local has_fuel   = false
        local has_stone  = false
        local has_dirt   = false
        print("[DBG] chest.list() scan:")
        for i = 1, chest_size do
            local it = items[i]
            if it then
                local nm = it.name:lower()
                print(string.format("  [DBG]  slot %d: %s x%d", i, it.name, it.count))
                if nm:find("lava_bucket")         then has_fuel  = true end
                if matchesMat(nm, STONE_PATTERNS) then has_stone = true end
                if matchesMat(nm, DIRT_PATTERNS)  then has_dirt  = true end
            end
        end
        print(string.format("[DBG] need_fuel=%s need_stone=%d need_dirt=%d",
            tostring(need_fuel), need_stone, need_dirt))
        print(string.format("[DBG] has_fuel=%s has_stone=%s has_dirt=%s",
            tostring(has_fuel), tostring(has_stone), tostring(has_dirt)))

        -- Build a list of what is still missing from the chest.
        local missing = {}
        if need_fuel  and not has_fuel  then missing[#missing+1] = "fuel"  end
        if need_stone > 0 and not has_stone then missing[#missing+1] = "stone" end
        if need_dirt  > 0 and not has_dirt  then missing[#missing+1] = "dirt"  end

        if #missing == 3 or (not has_fuel and not has_stone and not has_dirt) then
            -- Chest has nothing at all we want — wait for a refill.
            local msg = "Waiting: need " .. table.concat(missing, " + ")
            print("  " .. msg .. "…")
            setStatus("RESUPPLY", msg)
            rednet.send(server_id, {type = "HEARTBEAT", fuel = turtle.getFuelLevel()}, SERVER_PROTOCOL)
            os.sleep(3)
        else
            -- ── Stone ────────────────────────────────────────────────────────
            if need_stone > 0 and has_stone then
                local remaining = need_stone
                for i = 1, chest_size do
                    if remaining <= 0 then break end
                    local it = items[i]
                    if it and matchesMat(it.name:lower(), STONE_PATTERNS) then
                        local slot = findEmptySlot()
                        if not slot then break end
                        local count = math.min(remaining, it.count)
                        local moved = chest.pushItems(turtle_name, i, count, slot)
                        print(string.format("[DBG] pushItems stone slot %d x%d → turtle slot %d (moved %d)",
                            i, count, slot, moved))
                        remaining = remaining - moved
                    end
                end
                setStatus("RESUPPLY", "Pulled stone")
            end

            -- ── Dirt ─────────────────────────────────────────────────────────
            if need_dirt > 0 and has_dirt then
                local remaining = need_dirt
                for i = 1, chest_size do
                    if remaining <= 0 then break end
                    local it = items[i]
                    if it and matchesMat(it.name:lower(), DIRT_PATTERNS) then
                        local slot = findEmptySlot()
                        if not slot then break end
                        local count = math.min(remaining, it.count)
                        local moved = chest.pushItems(turtle_name, i, count, slot)
                        print(string.format("[DBG] pushItems dirt slot %d x%d → turtle slot %d (moved %d)",
                            i, count, slot, moved))
                        remaining = remaining - moved
                    end
                end
                setStatus("RESUPPLY", "Pulled dirt")
            end

            -- ── Lava buckets (fuel) ───────────────────────────────────────────
            if need_fuel and has_fuel then
                for i = 1, chest_size do
                    if turtle.getFuelLevel() >= FUEL_TARGET then break end
                    local it = items[i]
                    if it and it.name:lower():find("lava_bucket") then
                        local slot = findEmptySlot()
                        if not slot then
                            cleanInventory()
                            slot = findEmptySlot()
                        end
                        if not slot then break end
                        local moved = chest.pushItems(turtle_name, i, 1, slot)
                        print(string.format("[DBG] pushItems lava slot %d → turtle slot %d (moved %d)",
                            i, slot, moved))
                        if moved > 0 then
                            turtle.select(slot)
                            turtle.refuel()           -- lava consumed; empty bucket in slot
                            turtle.drop()             -- return empty bucket to chest
                            cleanInventory()          -- drop any overstock freed up
                            print(string.format("[DBG] refuelled → fuel=%d", turtle.getFuelLevel()))
                            setStatus("RESUPPLY", "Refuelled: fuel=" .. turtle.getFuelLevel())
                        end
                    end
                end
            end
        end
    end

    print(string.format("  → fuel=%d, stone=%d, dirt=%d",
        turtle.getFuelLevel(), countBuildBlocks("stone"), countBuildBlocks("dirt")))
    setStatus("RESUPPLY", string.format("Done — fuel=%d blk=%d", turtle.getFuelLevel(), countBuildBlocks()))

    -- 4. Step forward (+z) before releasing so the next queued turtle can
    --    navigate to (0,0,0) without bumping into us (stepping toward -z
    --    would put us into the chest).
    face(0)  -- face +z before stepping away
    local moved = turtle.forward()
    if moved then pz = pz + 1 end

    -- 5. Release the chest for the next turtle in the server queue.
    rednet.send(server_id, {type = "CHEST_DONE"}, SERVER_PROTOCOL)

    -- 6. Return to the original position.
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
local function sendStatus(pct, layer)
    g_pct = pct
    rednet.send(server_id, {
        type  = "STATUS_UPDATE",
        fuel  = turtle.getFuelLevel(),
        pct   = pct,
        layer = layer,
    }, SERVER_PROTOCOL)
    -- Refresh the percentage line on the monitor without a full redraw.
    if mon then
        mon.setCursorPos(1, 5)
        mon.write("Done:  " .. pct .. "%  ")
    end
end

-- Remembered from the most recent TASK_ASSIGN (used when parking after NO_MORE_TASKS).
local task_start_side = "left"

-- --------------------------------------------------------------------------
-- Park the turtle in the designated park zone.
-- The park zone is one block on the opposite side of the work area at the
-- origin height so the turtle stays clear of the chest path and other turtles.
-- --------------------------------------------------------------------------
local function parkTurtle()
    -- Opposite side of the work area avoids blocking the chest path.
    local park_x = (task_start_side == "left") and 1 or -1
    print(string.format("All tasks done. Moving to park zone (x=%d).", park_x))
    setStatus("PARKING", string.format("Going to park zone x=%d", park_x))
    goTo(park_x, 0, 0)
    face(0)  -- face +z (original start direction)
    print("Parked.")
    setStatus("PARKED", string.format("Park zone x=%d", park_x))
end

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
        print(string.format("  [dbg] col=%d layer=%d/%d mat=%s pos=(%d,%d,%d)",
            col_x, layer, layers, mattype, px, py, pz))
        setStatus("BUILDING", string.format("Col %d  Layer %d/%d  %s", col_x, layer, layers, mattype))
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
                sendStatus(math.floor(placed * 100 / total), layer)
            end
            if z < length then stepForward() end
        end

        -- Return to column-start at this height before ascending/descending.
        goTo(gx, y_sign * (layer - 1), 0)
    end

    sendStatus(100, layers)
end

-- --------------------------------------------------------------------------
-- Main task loop — keep requesting columns until the server has no more
-- --------------------------------------------------------------------------
-- Initial startup: ensure fuel and at least a minimal stock before first task.
setStatus("STARTUP", "Checking fuel — need >=" .. FUEL_THRESHOLD .. " to begin")
checkFuel()
setStatus("STARTUP", "Checking blocks — need >=" .. MAT_THRESHOLD .. " to begin")
if countBuildBlocks() < MAT_THRESHOLD then resupply() end
print("Requesting first task…")
setStatus("IDLE", "Requesting first task")
rednet.send(server_id, {type = "REQUEST_TASK"}, SERVER_PROTOCOL)

while true do
    local sender, msg
    repeat
        sender, msg = rednet.receive(SERVER_PROTOCOL, 60)
        if sender == nil then error("Timeout waiting for task from server.") end
    until sender == server_id and type(msg) == "table"

    if msg.type == "NO_MORE_TASKS" then
        parkTurtle()
        break
    end

    if msg.type == "TASK_ASSIGN" then
        local col_x      = msg.col_x
        local length     = msg.length
        local layer_mats = msg.layer_materials or {"stone"}
        local start_side = msg.start_side      or task_start_side
        local build_dir  = msg.build_dir        or "up"
        task_start_side  = start_side  -- remember for idle-parking
        g_pct = 0  -- reset progress for the new column task
        print(string.format("Col %d: %d positions × %d layers (%s, %s).",
            col_x, length, #layer_mats, start_side, build_dir))
        setStatus("BUILDING", string.format("Col %d  %d pos × %d layers", col_x, length, #layer_mats))
        buildColumn(col_x, length, layer_mats, start_side, build_dir)
        print(string.format("Col %d done.", col_x))
        rednet.send(server_id, {type = "TASK_DONE", col_x = col_x}, SERVER_PROTOCOL)
        -- Drain inventory across columns: only resupply when material is actually low.
        if countBuildBlocks() < MAT_THRESHOLD then resupply() end
        setStatus("IDLE", "Requesting next task")
        rednet.send(server_id, {type = "REQUEST_TASK"}, SERVER_PROTOCOL)
    end
end

print("Done!")
