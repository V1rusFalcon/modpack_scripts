-- ComputerCraft: Area Flattener – CLIENT
-- Connects to flatten_server, receives a column-chunk assignment, and flattens it.
--
-- Setup:
--   Attach a wireless modem to this turtle.
--   Place ALL turtles at the SAME corner of the FULL area,
--   ONE BLOCK ABOVE the target surface, facing along the LENGTH direction.
--   Start flatten_server on any computer first, then run this on each turtle.
--   Load fill material (stone, cobblestone, dirt, …) into any inventory slots.

local SERVER_PROTOCOL = "modpack_flatten"
local SERVER_HOSTNAME  = "flatten_server"

-- --------------------------------------------------------------------------
-- Connect to server and receive task
-- --------------------------------------------------------------------------
local modem = peripheral.find("modem")
if not modem then error("No modem found! Attach a wireless modem.") end
rednet.open(peripheral.getName(modem))

print("=== Area Flattener Client ===")
print("Fill material can be any block in any inventory slot.")
print("Looking up server (" .. SERVER_HOSTNAME .. ")...")

local server_id = rednet.lookup(SERVER_PROTOCOL, SERVER_HOSTNAME)
if not server_id then
    error("Server not found! Make sure flatten_server is running first.")
end
print("Server found (ID " .. server_id .. "). Requesting task...")

rednet.send(server_id, {type = "REQUEST_TASK"}, SERVER_PROTOCOL)

local WIDTH, LENGTH, TARGET_HEIGHT, Z_OFFSET
while true do
    local sender, msg = rednet.receive(SERVER_PROTOCOL, 30)
    if sender == nil then error("Timed out waiting for task assignment.") end
    if sender == server_id and type(msg) == "table" and msg.type == "TASK_ASSIGN" then
        WIDTH         = msg.width
        LENGTH        = msg.length
        TARGET_HEIGHT = msg.target_height
        Z_OFFSET      = msg.z_offset
        break
    end
end

print(string.format(
    "Task: %d wide x %d long, height=%d, z_offset=%d.",
    WIDTH, LENGTH, TARGET_HEIGHT, Z_OFFSET))

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
    "Flattening %d x %d section (surface height %d).",
    WIDTH, LENGTH, TARGET_HEIGHT))
print("Turtle should be 1 block above the target surface, at the area corner.")

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
print("Section complete!")
rednet.send(server_id, {type = "TASK_DONE"}, SERVER_PROTOCOL)
print("Done!")
