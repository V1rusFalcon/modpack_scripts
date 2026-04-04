-- ComputerCraft: 15x15 quarry to bedrock with auto-unload at base chest.
-- Place the turtle at one corner of the quarry, facing forward along the first row.
-- Place a chest directly behind the turtle's starting position.

local SIZE = 15

local x, y, z = 0, 0, 0
local dir = 0 -- 0=north, 1=east, 2=south, 3=west

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
    return true
end

local function isInventoryFull()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then
            return false
        end
    end
    return true
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
    local ok, reason = unloadAtHomeChest()
    if not ok then
        return false, reason
    end

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

print("Starting 15x15 quarry. Chest must be behind the starting position.")

local layer = 1
while true do
    print("Mining layer " .. layer)

    local ok, reason = mineLayer(SIZE)

    local okUnload, unloadReason = unloadAtHomeChest()
    if not okUnload then
        print("Stopped while unloading: " .. tostring(unloadReason))
        break
    end

    if not ok and reason == "bedrock" then
        print("Bedrock encountered while mining. Quarry complete.")
        break
    elseif not ok then
        print("Stopped while mining: " .. tostring(reason))
        break
    end

    local okDown, downReason = down()
    if not okDown and downReason == "bedrock" then
        print("Reached bedrock below base. Quarry complete.")
        break
    elseif not okDown then
        print("Stopped while descending: " .. tostring(downReason))
        break
    end

    layer = layer + 1
end

local okHome, reasonHome = goHome()
if not okHome then
    print("Warning: could not return home: " .. tostring(reasonHome))
end

print("Done.")
