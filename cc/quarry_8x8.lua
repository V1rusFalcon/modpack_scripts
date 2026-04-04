-- ComputerCraft: 8x8 quarry to bedrock with auto-unload at base chest.
-- Place the turtle at one corner of the quarry, facing forward along the first row.
-- Place a chest directly behind the turtle's starting position.
-- Optional: attach a modem to broadcast status; run quarry_monitor.lua on a
-- separate computer with a monitor to display live output.

local SIZE = 8
local PROTOCOL = "quarry"

local x, y, z = 0, 0, 0
local dir = 0 -- 0=north, 1=east, 2=south, 3=west

-- Set to true by down() when it dug through a solid block to descend.
-- Used after goTo() to detect whether we arrived at solid rock or cave air.
local lastDownWasSolid = false

-- Running totals for debug output.
local totalBlocksMined = 0
local layerBlocksMined = 0

-- Modem / rednet (optional) -------------------------------------------------
-- Collect all attached modems and prefer a wireless one; rednet broadcasts
-- only travel between wireless modems, so a wired modem would prevent the
-- monitor from receiving messages.
local modemSide = nil
do
    local modems = {peripheral.find("modem")}
    for _, m in ipairs(modems) do
        if m.isWireless and m.isWireless() then
            modemSide = peripheral.getName(m)
            break
        end
    end
    -- Fall back to any modem if no wireless one is present.
    if not modemSide and #modems > 0 then
        modemSide = peripheral.getName(modems[1])
    end
end
if modemSide then
    rednet.open(modemSide)
end

local function log(msg)
    print(msg)
    if modemSide then
        rednet.broadcast(msg, PROTOCOL)
    end
end
-- ---------------------------------------------------------------------------

local function isBedrock(block)
    return block and type(block.name) == "string" and string.find(block.name, "bedrock", 1, true) ~= nil
end

local function turnLeft()
    turtle.turnLeft()
    dir = (dir + 3) % 4
end

local function turnRight()
    turtle.turnRight()
    dir = (dir + 1) % 4
end

local function face(targetDir)
    local delta = (targetDir - dir) % 4
    if delta == 1 then
        turnRight()
    elseif delta == 2 then
        turnRight()
        turnRight()
    elseif delta == 3 then
        turnLeft()
    end
end

local function digForwardSafe()
    while turtle.detect() do
        local ok, data = turtle.inspect()
        if ok and isBedrock(data) then
            return false, "bedrock"
        end

        turtle.dig()
        turtle.attack()
        totalBlocksMined = totalBlocksMined + 1
        layerBlocksMined = layerBlocksMined + 1
    end
    return true
end

local function digDownSafe()
    while turtle.detectDown() do
        local ok, data = turtle.inspectDown()
        if ok and isBedrock(data) then
            return false, "bedrock"
        end

        turtle.digDown()
        turtle.attackDown()
        totalBlocksMined = totalBlocksMined + 1
        layerBlocksMined = layerBlocksMined + 1
    end
    return true
end

local function forward()
    local ok, reason = digForwardSafe()
    if not ok then
        return false, reason
    end

    while not turtle.forward() do
        turtle.attack()
        local ok2, reason2 = digForwardSafe()
        if not ok2 then
            return false, reason2
        end
    end

    if dir == 0 then
        z = z - 1
    elseif dir == 1 then
        x = x + 1
    elseif dir == 2 then
        z = z + 1
    else
        x = x - 1
    end

    return true
end

local function down()
    -- Capture whether there is a solid block below *before* we dig it away.
    -- The flag is only committed to lastDownWasSolid after a successful descent
    -- so callers always see the state that corresponds to an actual move.
    local wasSolid = turtle.detectDown()

    local ok, reason = digDownSafe()
    if not ok then
        return false, reason
    end

    while not turtle.down() do
        turtle.attackDown()
        local ok2, reason2 = digDownSafe()
        if not ok2 then
            return false, reason2
        end
    end

    y = y - 1
    lastDownWasSolid = wasSolid  -- set only after the turtle actually descended
    return true
end

local function usedSlots()
    local used = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            used = used + 1
        end
    end
    return used
end

local function isInventoryFull()
    return usedSlots() > 16 * 0.6  -- unload when more than 60% of slots are occupied
end

local function dropAll()
    for slot = 1, 16 do
        turtle.select(slot)
        turtle.drop()
    end
    turtle.select(1)
end

local function goTo(tx, ty, tz)
    while y < ty do
        if not turtle.up() then
            turtle.digUp()
            turtle.attackUp()
        else
            y = y + 1
        end
    end

    while y > ty do
        local ok, reason = down()
        if not ok then
            return false, reason
        end
    end

    if x < tx then
        face(1)
        while x < tx do
            local ok, reason = forward()
            if not ok then
                return false, reason
            end
        end
    elseif x > tx then
        face(3)
        while x > tx do
            local ok, reason = forward()
            if not ok then
                return false, reason
            end
        end
    end

    if z < tz then
        face(2)
        while z < tz do
            local ok, reason = forward()
            if not ok then
                return false, reason
            end
        end
    elseif z > tz then
        face(0)
        while z > tz do
            local ok, reason = forward()
            if not ok then
                return false, reason
            end
        end
    end

    return true
end

local function goHome()
    local ok, reason = goTo(0, 0, 0)
    if not ok then
        return false, reason
    end
    face(0)
    return true
end

local function unloadAtHomeChest()
    local ok, reason = goHome()
    if not ok then
        return false, reason
    end

    turnRight()
    turnRight()
    dropAll()
    turnRight()
    turnRight()

    return true
end

local function unloadAndReturn(workX, workY, workZ, workDir)
    log(string.format("  Inventory %d/16 slots used — unloading at chest.", usedSlots()))
    local ok, reason = unloadAtHomeChest()
    if not ok then
        return false, reason
    end

    log(string.format("  Returning to pos (%d,%d,%d).", workX, workY, workZ))
    local ok2, reason2 = goTo(workX, workY, workZ)
    if not ok2 then
        return false, reason2
    end

    face(workDir)
    return true
end

local function mineLayer(size)
    for row = 1, size do
        for col = 1, size - 1 do
            local ok, reason = forward()
            if not ok then
                return false, reason
            end

            if isInventoryFull() then
                local workX, workY, workZ, workDir = x, y, z, dir
                local ok2, reason2 = unloadAndReturn(workX, workY, workZ, workDir)
                if not ok2 then
                    return false, reason2
                end
            end
        end

        if row < size then
            if row % 2 == 1 then
                turnRight()
                local ok, reason = forward()
                if not ok then
                    return false, reason
                end
                turnRight()
            else
                turnLeft()
                local ok, reason = forward()
                if not ok then
                    return false, reason
                end
                turnLeft()
            end
        end
    end

    return true
end

local function runQuarry()
    local layer = 1

    while true do
        layerBlocksMined = 0
        log(string.format("Layer %d | depth y=%d | fuel=%s | total mined=%d",
            layer, y,
            tostring(turtle.getFuelLevel()),
            totalBlocksMined))

        local ok, reason = mineLayer(SIZE)
        local lastY = y  -- save depth before going home; mineLayer only moves horizontally

        log(string.format("  Layer %d done: %d blocks mined (total %d).",
            layer, layerBlocksMined, totalBlocksMined))

        local okUnload, unloadReason = unloadAtHomeChest()
        if not okUnload then
            log("Stopped while unloading: " .. tostring(unloadReason))
            return
        end

        if not ok and reason == "bedrock" then
            log("Bedrock encountered while mining. Quarry complete.")
            return
        elseif not ok then
            log("Stopped while mining: " .. tostring(reason))
            return
        end

        -- Descend to exactly one block below the layer we just mined.
        -- goTo() calls down() for each step; after it returns, lastDownWasSolid
        -- reflects whether the final step dug through solid rock (true) or
        -- passed through existing air/cave (false).
        log(string.format("  Descending to y=%d.", lastY - 1))
        local okGo, goReason = goTo(0, lastY - 1, 0)
        if not okGo then
            if goReason == "bedrock" then
                log("Reached bedrock. Quarry complete.")
            else
                log("Stopped descending: " .. tostring(goReason))
            end
            return
        end

        -- If the last step was through air we are inside a cave.
        -- Keep descending until the floor is solid, then step into it.
        if not lastDownWasSolid then
            log(string.format("  Cave detected at y=%d — dropping to floor.", y))
            local caveTop = y
            -- Drop through cave air until there is a solid block directly below.
            while not turtle.detectDown() do
                local okD, dReason = down()
                if not okD then
                    if dReason == "bedrock" then
                        log("Reached bedrock. Quarry complete.")
                    else
                        log("Stopped descending through cave: " .. tostring(dReason))
                    end
                    return
                end
            end
            log(string.format("  Cave floor at y=%d (skipped %d air blocks).", y, caveTop - y))
            -- detectDown() is now true: solid block is one step below.
            -- Descend into it so the next mineLayer works on solid rock.
            local okD, dReason = down()
            if not okD then
                if dReason == "bedrock" then
                    log("Reached bedrock. Quarry complete.")
                else
                    log("Stopped entering solid layer: " .. tostring(dReason))
                end
                return
            end
        end

        log(string.format("  Starting next layer at y=%d | fuel=%s",
            y, tostring(turtle.getFuelLevel())))
        layer = layer + 1
    end
end

if modemSide then
    log("Rednet open on " .. modemSide .. " (protocol: " .. PROTOCOL .. ")")
end
log(string.format("Starting 8x8 quarry. Fuel=%s. Chest must be behind the starting position.",
    tostring(turtle.getFuelLevel())))
runQuarry()

local okHome, reasonHome = goHome()
if not okHome then
    log("Warning: could not return home: " .. tostring(reasonHome))
end

log("Done.")
if modemSide then
    rednet.close(modemSide)
end
