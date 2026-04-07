-- ComputerCraft: Flatten a WIDTH x LENGTH area to a uniform surface height.
-- Matches the top of a 5-layer platform (3 stone + 2 dirt) by default.
--
-- What this program does for every column in the area:
--   * Removes all blocks above the target surface level.
--   * Places a fill block at the target surface level if none is present.
--   (Deep holes are not backfilled below the surface layer.)
--
-- Setup:
--   Place the turtle ONE BLOCK ABOVE the target surface level,
--   at the corner of the area to flatten, facing along the LENGTH direction.
--   Load fill material (stone, cobblestone, dirt, …) into any inventory slots.

local WIDTH         = 10  -- columns perpendicular to initial facing
local LENGTH        = 10  -- columns along initial facing
local TARGET_HEIGHT = 5   -- desired surface level (informational; turtle is placed
                           -- manually at that height + 1 before running)

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

-- Select any non-empty slot; returns true on success, false if inventory empty.
local function selectFill()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            return true
        end
    end
    return false
end

-- --------------------------------------------------------------------------
-- Per-column flatten actions
-- Turtle is 1 block above the target surface before and after each call.
-- --------------------------------------------------------------------------

-- Dig up through any blocks above the turtle's current level, then return down.
local function clearAbove()
    local ascent = 0
    while turtle.detectUp() do
        turtle.digUp()
        stepUp()
        ascent = ascent + 1
    end
    for _ = 1, ascent do
        stepDown()
    end
end

-- Place a fill block below (at target surface level) if the surface is missing.
local function fillSurface()
    if not turtle.detectDown() then
        if selectFill() then
            turtle.placeDown()
        else
            print(string.format(
                "Warning: no fill material at column (%d, %d) – skipping.",
                px, pz))
        end
    end
end

-- --------------------------------------------------------------------------
-- Main
-- --------------------------------------------------------------------------
print(string.format(
    "Flattening %d x %d area to surface height %d.",
    WIDTH, LENGTH, TARGET_HEIGHT))
print("Turtle should be 1 block above the target surface, at the area corner.")
print("Fill material can be any block in any inventory slot.")
print("Starting...")

for row = 1, WIDTH do
    for col = 1, LENGTH do
        clearAbove()
        fillSurface()
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

goTo(0, 0, 0)
face(0)
print("Flattening complete!")
