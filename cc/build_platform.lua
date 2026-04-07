-- ComputerCraft: Build a platform with configurable dimensions and layer counts.
-- The turtle sweeps each layer in a snake pattern and places blocks below itself.
--
-- Setup:
--   Place the turtle ONE BLOCK ABOVE the bottom-left corner of the intended platform,
--   facing forward along the LENGTH direction (the long axis).
--   Inventory: slots  1-8  = stone / cobblestone
--              slots  9-16 = dirt

-- --------------------------------------------------------------------------
-- Prompt helpers
-- --------------------------------------------------------------------------

local function readNumber(prompt, default)
    while true do
        io.write(prompt .. " [" .. tostring(default) .. "]: ")
        local line = io.read()
        if line == nil or line == "" then
            return default
        end
        local n = tonumber(line)
        if n and n > 0 and math.floor(n) == n then
            return math.floor(n)
        end
        print("Please enter a positive whole number.")
    end
end

-- --------------------------------------------------------------------------
-- Ask for parameters
-- --------------------------------------------------------------------------
print("=== Platform Builder ===")
print("Slots  1-8 : stone / cobblestone")
print("Slots  9-16: dirt")
print("")
local WIDTH        = readNumber("Width  (columns perpendicular to facing)", 10)
local LENGTH       = readNumber("Length (columns along facing)",            10)
local STONE_LAYERS = readNumber("Stone / cobblestone layers (bottom)",       3)
local DIRT_LAYERS  = readNumber("Dirt layers (top)",                         2)
local TOTAL_LAYERS = STONE_LAYERS + DIRT_LAYERS

local STONE_SLOTS, DIRT_SLOTS = {}, {}
for i = 1,  8 do STONE_SLOTS[#STONE_SLOTS + 1] = i end
for i = 9, 16 do DIRT_SLOTS[#DIRT_SLOTS  + 1] = i end

-- --------------------------------------------------------------------------
-- Position / heading tracking  (relative to starting position)
-- dir: 0=+z  1=+x  2=-z  3=-x
-- --------------------------------------------------------------------------
local px, py, pz = 0, 0, 0
local pdir = 0

local function turnLeft()
    turtle.turnLeft()
    pdir = (pdir + 3) % 4
end

local function turnRight()
    turtle.turnRight()
    pdir = (pdir + 1) % 4
end

local function face(d)
    local delta = (d - pdir) % 4
    if     delta == 1 then turnRight()
    elseif delta == 2 then turnRight(); turnRight()
    elseif delta == 3 then turnLeft()
    end
end

local function stepForward()
    while not turtle.forward() do
        turtle.dig()
        turtle.attack()
    end
    if     pdir == 0 then pz = pz + 1
    elseif pdir == 1 then px = px + 1
    elseif pdir == 2 then pz = pz - 1
    else                   px = px - 1
    end
end

local function stepUp()
    while not turtle.up() do
        turtle.digUp()
        turtle.attackUp()
    end
    py = py + 1
end

local function stepDown()
    while not turtle.down() do
        turtle.digDown()
        turtle.attackDown()
    end
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

-- Select a slot that contains material; block and prompt if all slots empty.
local function selectMaterial(slots)
    while true do
        for _, slot in ipairs(slots) do
            if turtle.getItemCount(slot) > 0 then
                turtle.select(slot)
                return
            end
        end
        print("Out of material! Refill inventory and press Enter to continue.")
        io.read()
    end
end

-- --------------------------------------------------------------------------
-- Layer builder
-- Turtle must already be at (0, layer-1, 0) facing +z before calling.
-- Blocks are placed one below the turtle; the layer's blocks end up at py-1.
-- --------------------------------------------------------------------------
local function buildLayer(slots)
    face(0)  -- ensure correct facing at row start
    for row = 1, WIDTH do
        for col = 1, LENGTH do
            selectMaterial(slots)
            turtle.placeDown()
            if col < LENGTH then
                stepForward()
            end
        end
        if row < WIDTH then
            if row % 2 == 1 then
                turnRight(); stepForward(); turnRight()
            else
                turnLeft();  stepForward(); turnLeft()
            end
        end
    end
end

-- --------------------------------------------------------------------------
-- Main
-- --------------------------------------------------------------------------
print(string.format(
    "Building %d x %d x %d platform (%d stone + %d dirt).",
    WIDTH, LENGTH, TOTAL_LAYERS, STONE_LAYERS, DIRT_LAYERS))
print("Starting...")

for layer = 1, TOTAL_LAYERS do
    local isStone = (layer <= STONE_LAYERS)
    local slots   = isStone and STONE_SLOTS or DIRT_SLOTS
    local mat     = isStone and "stone" or "dirt"

    print(string.format("Building layer %d/%d (%s) ...", layer, TOTAL_LAYERS, mat))

    -- For layer N the turtle works at py = N-1 (one above the block row).
    goTo(0, layer - 1, 0)
    buildLayer(slots)

    -- Return to the start column at the same height before ascending.
    goTo(0, layer - 1, 0)
end

print(string.format(
    "Platform complete! Turtle is at the top-left corner above layer %d.",
    TOTAL_LAYERS))
