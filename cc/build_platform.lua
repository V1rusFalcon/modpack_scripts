-- ComputerCraft: Platform builder – CLIENT
-- Connects to platform_server, receives a column-chunk assignment, and builds it.
--
-- Setup:
--   Attach a wireless modem to this turtle.
--   Place ALL turtles at the SAME bottom-left corner of the FULL platform area,
--   ONE BLOCK ABOVE ground, facing along the LENGTH direction.
--   Start platform_server on any computer first, then run this on each turtle.
--   Inventory: slots  1-8  = stone / cobblestone
--              slots  9-16 = dirt

local SERVER_PROTOCOL = "modpack_platform"
local SERVER_HOSTNAME  = "platform_server"

-- --------------------------------------------------------------------------
-- Connect to server and receive task
-- --------------------------------------------------------------------------
local modem = peripheral.find("modem")
if not modem then error("No modem found! Attach a wireless modem.") end
rednet.open(peripheral.getName(modem))

print("=== Platform Builder Client ===")
print("Slots  1-8 : stone / cobblestone")
print("Slots  9-16: dirt")
print("Looking up server (" .. SERVER_HOSTNAME .. ")...")

local server_id = rednet.lookup(SERVER_PROTOCOL, SERVER_HOSTNAME)
if not server_id then
    error("Server not found! Make sure platform_server is running first.")
end
print("Server found (ID " .. server_id .. "). Requesting task...")

rednet.send(server_id, {type = "REQUEST_TASK"}, SERVER_PROTOCOL)

local WIDTH, LENGTH, STONE_LAYERS, DIRT_LAYERS, Z_OFFSET
while true do
    local sender, msg = rednet.receive(SERVER_PROTOCOL, 30)
    if sender == nil then error("Timed out waiting for task assignment.") end
    if sender == server_id and type(msg) == "table" and msg.type == "TASK_ASSIGN" then
        WIDTH        = msg.width
        LENGTH       = msg.length
        STONE_LAYERS = msg.stone_layers
        DIRT_LAYERS  = msg.dirt_layers
        Z_OFFSET     = msg.z_offset
        break
    end
end

local TOTAL_LAYERS = STONE_LAYERS + DIRT_LAYERS
print(string.format(
    "Task: %d wide x %d long, %d stone + %d dirt, z_offset=%d.",
    WIDTH, LENGTH, STONE_LAYERS, DIRT_LAYERS, Z_OFFSET))

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
-- Navigate to this turtle's starting column (z_offset steps to the right)
-- --------------------------------------------------------------------------
if Z_OFFSET > 0 then
    face(1)  -- face +x (right when initially facing +z)
    for _ = 1, Z_OFFSET do stepForward() end
    face(0)  -- face back along length (+z)
    px, py, pz = 0, 0, 0  -- reset to local origin
end

-- --------------------------------------------------------------------------
-- Main
-- --------------------------------------------------------------------------
print(string.format(
    "Building %d x %d x %d platform (%d stone + %d dirt).",
    WIDTH, LENGTH, TOTAL_LAYERS, STONE_LAYERS, DIRT_LAYERS))

for layer = 1, TOTAL_LAYERS do
    local isStone = (layer <= STONE_LAYERS)
    local slots   = isStone and STONE_SLOTS or DIRT_SLOTS
    local mat     = isStone and "stone" or "dirt"

    print(string.format("  Layer %d/%d (%s)...", layer, TOTAL_LAYERS, mat))

    -- For layer N the turtle works at py = N-1 (one above the block row).
    goTo(0, layer - 1, 0)
    buildLayer(slots)

    -- Return to the start column at the same height before ascending.
    goTo(0, layer - 1, 0)
end

print("Section complete!")
rednet.send(server_id, {type = "TASK_DONE"}, SERVER_PROTOCOL)
print(string.format(
    "Done! Turtle is above layer %d of its assigned section.", TOTAL_LAYERS))
