-- ComputerCraft: Area Flattener Server
-- Prompts for job parameters and coordinates multiple turtle clients.
--
-- Setup:
--   Attach a wireless modem to this computer.
--   Run this program first, then run flatten.lua on each turtle.
--   All turtles must start at the SAME corner of the full area,
--   ONE BLOCK ABOVE the target surface, facing along the LENGTH direction.
--   The server assigns each turtle a WIDTH chunk and tells it how far right to
--   move before starting (z_offset).

local SERVER_PROTOCOL = "modpack_flatten"
local SERVER_HOSTNAME  = "flatten_server"

-- --------------------------------------------------------------------------
-- Prompt helper
-- --------------------------------------------------------------------------
local function readNumber(prompt, default)
    while true do
        io.write(prompt .. " [" .. tostring(default) .. "]: ")
        local line = io.read()
        if line == nil or line == "" then return default end
        local n = tonumber(line)
        if n and n > 0 and math.floor(n) == n then return math.floor(n) end
        print("Please enter a positive whole number.")
    end
end

-- --------------------------------------------------------------------------
-- Open modem
-- --------------------------------------------------------------------------
local modem = peripheral.find("modem")
if not modem then error("No modem found! Attach a wireless modem.") end
rednet.open(peripheral.getName(modem))
rednet.host(SERVER_PROTOCOL, SERVER_HOSTNAME)

-- --------------------------------------------------------------------------
-- Gather parameters
-- --------------------------------------------------------------------------
print("=== Area Flattener Server ===")
print("")
local WIDTH         = readNumber("Total width  (perpendicular to turtles' facing)", 10)
local LENGTH        = readNumber("Length (along turtles' facing)",                  10)
local TARGET_HEIGHT = readNumber("Target surface height (for reference)",             5)
local NUM_TURTLES   = readNumber("Number of turtles",                                1)

-- --------------------------------------------------------------------------
-- Divide WIDTH into chunks (one per turtle)
-- --------------------------------------------------------------------------
local chunks  = {}
local base    = math.floor(WIDTH / NUM_TURTLES)
local extra   = WIDTH % NUM_TURTLES
local z_off   = 0
for i = 1, NUM_TURTLES do
    local w   = base + (i <= extra and 1 or 0)
    chunks[i] = {width = w, z_offset = z_off}
    z_off     = z_off + w
end

print(string.format(
    "\nJob: flatten %d x %d to height %d, %d turtle(s).",
    WIDTH, LENGTH, TARGET_HEIGHT, NUM_TURTLES))
for i, c in ipairs(chunks) do
    print(string.format("  Chunk %d: width=%d, z_offset=%d", i, c.width, c.z_offset))
end
print("\nWaiting for turtles  (protocol: " .. SERVER_PROTOCOL ..
      "  host: " .. SERVER_HOSTNAME .. ")...")

-- --------------------------------------------------------------------------
-- Assign tasks to connecting turtles
-- --------------------------------------------------------------------------
local assigned = 0
local pending  = {}

while assigned < NUM_TURTLES do
    local sender, msg = rednet.receive(SERVER_PROTOCOL, 120)
    if sender == nil then
        print("Timeout – only " .. assigned .. "/" .. NUM_TURTLES .. " turtle(s) connected.")
        break
    end
    if type(msg) == "table" and msg.type == "REQUEST_TASK" and not pending[sender] then
        assigned        = assigned + 1
        local chunk     = chunks[assigned]
        pending[sender] = assigned
        rednet.send(sender, {
            type          = "TASK_ASSIGN",
            width         = chunk.width,
            length        = LENGTH,
            target_height = TARGET_HEIGHT,
            z_offset      = chunk.z_offset,
        }, SERVER_PROTOCOL)
        print(string.format(
            "  Turtle %d → chunk %d (width=%d, z_offset=%d)",
            sender, assigned, chunk.width, chunk.z_offset))
    end
end

-- --------------------------------------------------------------------------
-- Wait for all turtles to finish
-- --------------------------------------------------------------------------
print("All " .. assigned .. " turtle(s) assigned. Waiting for completion...")
local done = 0
while done < assigned do
    local sender, msg = rednet.receive(SERVER_PROTOCOL, 3600)
    if sender == nil then
        print("Timeout waiting for turtle completions.")
        break
    end
    if type(msg) == "table" and msg.type == "TASK_DONE" and pending[sender] then
        done            = done + 1
        pending[sender] = nil
        print(string.format(
            "  Turtle %d finished (%d/%d done).", sender, done, assigned))
    end
end

if done == assigned then
    print("Flattening complete!")
else
    print(string.format("Partial: %d/%d turtles finished.", done, assigned))
end

rednet.unhost(SERVER_PROTOCOL)
