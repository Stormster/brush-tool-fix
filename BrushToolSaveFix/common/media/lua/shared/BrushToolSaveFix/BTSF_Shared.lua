BrushToolSaveFix = BrushToolSaveFix or {}

BrushToolSaveFix.MODULE = "BrushToolSaveFix"
BrushToolSaveFix.VERSION = "1.2.5"

function BrushToolSaveFix.log(msg)
    if getDebug and getDebug() then
        print("[BrushToolSaveFix] " .. tostring(msg))
    end
end

-- Always printed, unlike log(). Users troubleshooting a broken setup have no
-- way to tell whether the mod loaded at all, and the client/server flags decide
-- which code path the brush tool takes.
function BrushToolSaveFix.announce(msg)
    print("[BrushToolSaveFix " .. BrushToolSaveFix.VERSION .. "] " .. tostring(msg)
        .. " (isClient=" .. tostring(isClient()) .. ", isServer=" .. tostring(isServer()) .. ")")
end

-- Always printed. Used for things a server admin needs to see without
-- running in debug mode, such as a refused request.
function BrushToolSaveFix.warn(msg)
    print("[BrushToolSaveFix] " .. tostring(msg))
end

-- Role capabilities are what the server actually assigns; the access level
-- name and the brush flag are older views of the same thing and stay as
-- fallbacks. A missing role or capability API just means false here.
local function roleHas(player, capabilityName)
    if not player.getRole or not Capability then
        return false
    end
    local capability = Capability[capabilityName]
    local role = player:getRole()
    if not capability or not role or not role.hasCapability then
        return false
    end
    return role:hasCapability(capability) == true
end

-- Whether vanilla would show this player the Debug menu the brush lives in.
-- Anyone without it never clicked the tool, so a refusal is not worth a reply.
function BrushToolSaveFix.canOpenDebugMenu(player)
    return player ~= nil and roleHas(player, "UseDebugContextMenu")
end

function BrushToolSaveFix.canUseBrush(player)
    if not player then
        return false
    end

    if roleHas(player, "UseBrushToolManager") then
        return true
    end

    if player.isCanUseBrushTool and player:isCanUseBrushTool() then
        return true
    end

    if player.getAccessLevel then
        local level = string.lower(tostring(player:getAccessLevel() or ""))
        if level == "admin" or level == "moderator" or level == "overseer" or level == "gm" then
            return true
        end
    end

    return false
end

function BrushToolSaveFix.getOrCreateSquare(x, y, z)
    local cell = getCell()
    if not cell then
        return nil
    end

    local square = cell:getGridSquare(x, y, z)
    if square == nil then
        square = cell:createNewGridSquare(x, y, z, true)
    end
    return square
end

-- Lookup without the create fallback, for the client side of a broadcast. A
-- client that has not streamed the square in must not fabricate one: the
-- server owns that geometry and will send it when the chunk loads.
function BrushToolSaveFix.getExistingSquare(x, y, z)
    local cell = getCell()
    if not cell then
        return nil
    end
    return cell:getGridSquare(x, y, z)
end

-- Only the world-authoritative side writes to the save. On a remote client
-- this would dirty a chunk whose contents the server is about to overwrite.
local function flagForSave(square, obj)
    if isClient() then
        return
    end
    if obj and obj.flagForHotSave then
        obj:flagForHotSave()
    end
    if square and square.flagForHotSave then
        square:flagForHotSave()
    end
end

-- Resolve the object a request refers to. The client-supplied index is
-- preferred, with a sprite-name scan as fallback for when indices shifted
-- between the click and this lookup.
function BrushToolSaveFix.findObject(square, sprite, index)
    if not square or not sprite then
        return nil
    end

    local objs = square:getObjects()

    if type(index) == "number" and index >= 0 and index < objs:size() then
        local candidate = objs:get(index)
        if candidate and candidate:getSprite() and candidate:getSprite():getName() == sprite then
            return candidate
        end
    end

    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        if obj:getSprite() ~= nil and obj:getSprite():getName() == sprite then
            return obj
        end
    end

    return nil
end

-- The grid a sprite belongs to, or nil when the sprite is a plain single tile.
function BrushToolSaveFix.getSpriteGrid(sprite)
    local spr = sprite and sprite ~= "" and getSprite(sprite) or nil
    if not spr or not spr.getSpriteGrid then
        return nil
    end
    return spr:getSpriteGrid(), spr
end

-- A refusal the client words differently from the multi-square one, so it
-- travels over the wire as-is.
BrushToolSaveFix.REFUSED_NO_FLOOR = "no floor under the overlay"

-- The wall a wall overlay hangs on, picked the way map loading picks it
-- (CellLoader.DoTileObjectCreation): by the edge the sprite says it attaches
-- to, falling back to a window frame or garage door on that edge, and for a
-- sprite that names no edge, the topmost wall on the square.
local function findWallOverlayHost(square, props)
    if props:has(IsoFlagType.attachedSE) then
        return square:getWallSE()
    end

    local west = props:has(IsoFlagType.attachedW)
    if west or props:has(IsoFlagType.attachedN) then
        local north = not west
        local host = square:getWall(north)
        if not host then
            local window = square:getWindow(north and GridSquareEdgeFacingDirection.NORTH_SOUTH
                or GridSquareEdgeFacingDirection.EAST_WEST)
            local windowProps = window and window:getProperties()
            if windowProps and windowProps:has(north and IsoFlagType.WindowN or IsoFlagType.WindowW) then
                host = window
            end
        end
        return host or square:getGarageDoor(north)
    end

    local objs = square:getObjects()
    for i = objs:size() - 1, 0, -1 do
        local obj = objs:get(i)
        local objProps = obj:getSprite() and obj:getSprite():getProperties()
        if objProps and (objProps:has(IsoFlagType.cutW) or objProps:has(IsoFlagType.cutN)) then
            return obj
        end
    end

    return nil
end

local function hasAttachedSprite(obj, sprite)
    local sprites = obj:getAttachedAnimSprite()
    if not sprites then
        return false
    end
    for i = 0, sprites:size() - 1 do
        local parent = sprites:get(i):getParentSprite()
        if parent and parent:getName() == sprite then
            return true
        end
    end
    return false
end

-- Properties that make an overlay sprite more than paint: it lights up, blocks,
-- can be scrapped, holds things, or is a named thing players interact with.
local OVERLAY_OBJECT_PROPS = { "IsMoveAble", "CustomName", "CanScrap", "BlocksPlacement", "IsoType", "signal" }
local OVERLAY_OBJECT_FLAGS = { "container", "windowN", "windowW", "WindowN", "WindowW",
    "collideN", "collideW", "HoppableN", "HoppableW", "cutN", "cutW" }

-- Whether an overlay sprite is decoration only. The overlay flags are also set
-- on neon lights, street lights, wall pieces and scrap, and the map loader
-- sorts those out by tile type and container before it ever reaches its
-- overlay case. Anything that would lose behaviour by becoming an attached
-- sprite stays an object, as it was before.
local function isDecorationOnly(spr, props)
    if spr:getType() ~= IsoObjectType.MAX then
        return false
    end
    for _, name in ipairs(OVERLAY_OBJECT_PROPS) do
        if props:has(name) then
            return false
        end
    end
    for _, name in ipairs(OVERLAY_OBJECT_FLAGS) do
        if props:has(IsoFlagType[name]) then
            return false
        end
    end
    return true
end

-- Grime, blood, graffiti, road markings and the like are not objects in a
-- mapped world. The map loader hangs them on the floor or wall they cover as
-- an attached sprite, and the renderer relies on that: an overlay sprite is
-- drawn at exactly the depth of the surface under it, so one placed as an
-- object of its own z-fights with that surface. placeMoveableInternal only
-- knows the attached form for moveable wall decoration and builds everything
-- else as a separate object.
--
-- Returns handled, placed, reason. Not handled means the sprite is no plain
-- overlay, or is a wall overlay with no wall on this square, which the map
-- loader also places as a plain object.
local function placeOverlayOnSquare(square, sprite)
    local spr = getSprite(sprite)
    local props = spr and spr:getProperties()
    if not props then
        return false
    end

    local wall = props:has(IsoFlagType.WallOverlay)
    if not wall and not (props:has(IsoFlagType.FloorOverlay) and not props:has(IsoFlagType.solidfloor)) then
        return false
    end
    if not isDecorationOnly(spr, props) then
        return false
    end

    -- An object with this sprite is already here, left by a version up to
    -- 1.2.2 or put there by the map. Leave it to the object path, which skips
    -- it as a duplicate. Destroying it and painting again gives the attached
    -- form.
    if BrushToolSaveFix.findObject(square, sprite, nil) then
        return false
    end

    local host
    if wall then
        host = findWallOverlayHost(square, props)
        if not host then
            return false
        end
    else
        host = square:getFloor()
        if not host then
            return true, false, BrushToolSaveFix.REFUSED_NO_FLOOR
        end
    end

    if hasAttachedSprite(host, sprite) then
        return true, false
    end

    host:AttachExistingAnim(spr, 0, 0, false, 0, false, 0)
    if isServer() then
        host:transmitUpdatedSpriteToClients()
    end
    flagForSave(square, host)

    if buildUtil and buildUtil.setHaveConstruction then
        buildUtil.setHaveConstruction(square, true)
    end

    return true, true
end

-- One sprite on one square, exactly the way vanilla's cursor does it. Returns
-- false when that sprite is already present, so a double-click or a laggy
-- repeat cannot stack duplicates.
--
-- 42.21 gave placeMoveableInternal a leading character parameter, which it
-- only uses to send halo notes about water and zone tiles. Passing nil is
-- fine; passing the square in that slot, as the 42.20 call did, is not.
local function placeSpriteOnSquare(square, sprite, character)
    if not square or not sprite or sprite == "" then
        return false
    end

    local objs = square:getObjects()
    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        if obj:getSprite() ~= nil and obj:getSprite():getName() == sprite then
            return false
        end
    end

    local spriteObj = getSprite(sprite)
    if not spriteObj then
        BrushToolSaveFix.log("missing sprite " .. tostring(sprite))
        return false
    end

    local props = ISMoveableSpriteProps.new(IsoObject.new(square, sprite):getSprite())
    props.rawWeight = 10
    props:placeMoveableInternal(character, square, instanceItem("Base.Plank"), sprite)

    if buildUtil and buildUtil.setHaveConstruction then
        buildUtil.setHaveConstruction(square, true)
    end

    return true
end

-- Whether the levels of a grid are really the same object turned round, not
-- storeys of one tall object, which means the definition cannot be trusted.
--
-- The upper level of a tall object stands on the lower one, so it has the same
-- footprint: of the 20 two-level grids in 42.21, 18 match exactly and the
-- Horse Statue overhangs by a cell. The Grey Chandelier is the odd one. Its
-- tile definitions file both orientations of a two-tile light under Facing=E
-- and tell them apart by level, so its upper level is the lower one with x and
-- y swapped, and the engine would put the second pair on the floor above the
-- first. Nor do its halves join on the squares the grid names: the art is cut
-- for two squares side by side on screen, which is a diagonal pair in the
-- world, so there is no layout the data supports. A grid like this is left
-- alone: its sprites are painted one at a time, as vanilla paints them, and
-- removed one at a time. That swapped footprint is what an orientation filed
-- as a level looks like, whichever tileset it turns up in.
local function levelsAreOrientations(grid)
    if grid:getLevels() < 2 then
        return false
    end

    local size = math.max(grid:getWidth(), grid:getHeight())
    for level = 1, grid:getLevels() - 1 do
        local turned = false
        for gx = 0, size - 1 do
            for gy = 0, size - 1 do
                local here = grid:getSprite(gx, gy, level) ~= nil
                if here ~= (grid:getSprite(gy, gx, 0) ~= nil) then
                    return false
                end
                if here ~= (grid:getSprite(gx, gy, 0) ~= nil) then
                    turned = true
                end
            end
        end
        if not turned then
            return false
        end
    end
    return true
end

-- Every sprite of a grid and where it sits relative to the given one, or nil
-- for a grid that cannot be trusted, whose sprites are then single tiles.
--
-- A grid can have empty cells: an L-shaped desk is filed as a 4x4 grid with
-- nine of them. Those are skipped, there is nothing to place or look for.
local function gridLayout(grid, spr)
    if levelsAreOrientations(grid) then
        return nil
    end

    local px = grid:getSpriteGridPosX(spr)
    local py = grid:getSpriteGridPosY(spr)
    local pz = grid:getSpriteGridPosZ(spr)

    local layout = {}
    for level = 0, grid:getLevels() - 1 do
        for gx = 0, grid:getWidth() - 1 do
            for gy = 0, grid:getHeight() - 1 do
                local partSprite = grid:getSprite(gx, gy, level)
                local name = partSprite and partSprite:getName() or nil
                if name then
                    layout[#layout + 1] = { sprite = name, dx = gx - px, dy = gy - py, dz = level - pz }
                end
            end
        end
    end

    return layout
end

-- Steps of a flight counted from the top, which is also how far each one sits
-- from the top step: along x for a flight climbing west, along y for north.
local STAIR_STEPS = {
    { type = "stairsTW", north = false, step = 0 },
    { type = "stairsMW", north = false, step = 1 },
    { type = "stairsBW", north = false, step = 2 },
    { type = "stairsTN", north = true, step = 0 },
    { type = "stairsMN", north = true, step = 1 },
    { type = "stairsBN", north = true, step = 2 },
}

local function stairStep(spr)
    local spriteType = spr and spr:getType()
    if not spriteType then
        return nil
    end
    for _, entry in ipairs(STAIR_STEPS) do
        if spriteType == IsoObjectType[entry.type] then
            return entry
        end
    end
    return nil
end

-- getSprite answers a name it does not know by creating a sprite under it,
-- which the next lookup then takes for a real tile. The sprite manager's own
-- map says whether one is loaded without that side effect.
local function knownSprite(name)
    local manager = getSpriteManager and getSpriteManager("")
    local named = manager and manager.getNamedMap and manager:getNamedMap()
    if named then
        return named:get(name)
    end
    return getSprite(name)
end

-- A flight of stairs is three sprites on three squares, but unlike other
-- multi-square objects nothing in the tile definitions ties them together: no
-- grid, no group, only the stairs type on each. What the tilesets do keep to
-- is the order, bottom-middle-top or the reverse on consecutive indexes, so
-- the other two steps are the neighbours either side of the middle one.
--
-- Returns the same layout gridLayout does, each part also naming its stairs
-- type, or nil when the sprite is no stair or its neighbours do not make up a
-- flight.
local function stairLayout(sprite, spr)
    local own = stairStep(spr or knownSprite(sprite))
    if not own then
        return nil
    end

    local tileset, index = string.match(sprite, "^(.+)_(%d+)$")
    index = tonumber(index)
    if not tileset or not index then
        return nil
    end

    local function stepAt(i)
        if i < 0 then
            return nil
        end
        local entry = stairStep(knownSprite(tileset .. "_" .. i))
        if entry and entry.north == own.north then
            return entry
        end
        return nil
    end

    local middles = own.step == 1 and { index } or { index + 1, index - 1 }
    for _, middle in ipairs(middles) do
        local mid = stepAt(middle)
        local before = mid and mid.step == 1 and stepAt(middle - 1) or nil
        local after = before and stepAt(middle + 1) or nil
        if after and before.step ~= 1 and before.step + after.step == 2 then
            local steps = { before, mid, after }
            local layout = {}
            for d = -1, 1 do
                local entry = steps[d + 2]
                local offset = entry.step - own.step
                layout[#layout + 1] = {
                    sprite = tileset .. "_" .. (middle + d),
                    type = entry.type,
                    dx = own.north and 0 or offset,
                    dy = own.north and offset or 0,
                    dz = 0,
                }
            end
            return layout
        end
    end

    return nil
end

-- Work out every square/sprite pair a multi-square placement needs, before
-- anything is written to the world.
--
-- Vanilla's brush places only the single sprite you painted. For a sprite grid
-- that leaves a piece the engine will not remove: its whole-object removal
-- gives up unless it can re-find every part. So it is all parts or none, and
-- returning nil here refuses the placement rather than leaving a fragment.
local function resolveParts(square, layout)
    local x, y, z = square:getX(), square:getY(), square:getZ()

    local parts = {}
    for _, part in ipairs(layout) do
        local target = BrushToolSaveFix.getOrCreateSquare(x + part.dx, y + part.dy, z + part.dz)
        if not target then
            return nil, "no square for " .. part.sprite
        end

        -- A step added to complete a flight gives way to a step of the same
        -- kind already on that square, whatever tileset it came from; the
        -- painted step is placed as it always was.
        local painted = part.dx == 0 and part.dy == 0 and part.dz == 0
        if not (part.type and not painted and target:has(IsoObjectType[part.type])) then
            parts[#parts + 1] = { square = target, sprite = part.sprite }
        end
    end

    return parts
end

-- Returns placed, reason. A false with no reason is an ordinary skip (the
-- sprite was already there); a false with a reason is a refusal worth showing
-- to whoever asked for it. The character is whoever is holding the brush; the
-- engine only uses it to send that player halo notes, so nil is acceptable.
function BrushToolSaveFix.placeTileOnSquare(square, sprite, character)
    if not square or not sprite or sprite == "" then
        return false
    end

    local grid, spr = BrushToolSaveFix.getSpriteGrid(sprite)
    local layout = grid and gridLayout(grid, spr) or stairLayout(sprite, spr)
    if not layout then
        local handled, placed, reason = placeOverlayOnSquare(square, sprite)
        if handled then
            return placed, reason
        end
        return placeSpriteOnSquare(square, sprite, character)
    end

    local parts, reason = resolveParts(square, layout)
    if not parts then
        BrushToolSaveFix.log("refused multi-square " .. sprite .. ": " .. tostring(reason))
        return false, reason
    end

    local placed = false
    for _, part in ipairs(parts) do
        if placeSpriteOnSquare(part.square, part.sprite, character) then
            placed = true
        end
    end

    return placed
end

-- Why a destroy found nothing to remove, or could not. Sent to the client
-- as-is, which words each one.
BrushToolSaveFix.DESTROY_MISSING = "missing"
BrushToolSaveFix.DESTROY_UNLOADED = "unloaded"
BrushToolSaveFix.DESTROY_STUCK = "stuck"

-- Remove an object and whatever else it is one piece of. Returns whether the
-- object is gone, and if not, why.
--
-- transmitRemoveItemFromSquare takes a multi-square object out whole, but only
-- if IsoObjectUtils.getAllMultiTileObjects can find every cell of its grid. On
-- the first cell with no matching object it clears its list and the call
-- returns -1 having removed nothing and said nothing. A single piece left by
-- vanilla's brush fails that, and so does any grid with an empty cell however
-- completely it was placed, because an empty cell can never match: the Grey
-- Chandelier and the L-shaped office desks resist the sledgehammer for the
-- same reason. The two-argument form skips that search and removes just the
-- object it is given, so the parts that are there are taken out one by one.
--
-- The search also fails when a part lies in a chunk that is not loaded. Taking
-- out the loaded parts then would leave the rest behind as fragments, so a
-- part whose chunk is missing stops the whole thing instead.
function BrushToolSaveFix.destroyObject(target)
    local square = target and target:getSquare()
    if not square then
        return false, BrushToolSaveFix.DESTROY_MISSING
    end

    square:transmitRemoveItemFromSquare(target)
    if target:getObjectIndex() == -1 then
        return true
    end

    local spr = target:getSprite()
    local grid = spr and spr:getSpriteGrid()
    local layout = grid and gridLayout(grid, spr)
    if layout then
        local x, y, z = square:getX(), square:getY(), square:getZ()
        local cell = getCell()
        local found = {}
        for _, part in ipairs(layout) do
            if part.dx ~= 0 or part.dy ~= 0 or part.dz ~= 0 then
                local px, py, pz = x + part.dx, y + part.dy, z + part.dz
                local partSquare = BrushToolSaveFix.getExistingSquare(px, py, pz)
                if not partSquare and cell.getChunkForGridSquare and not cell:getChunkForGridSquare(px, py, pz) then
                    return false, BrushToolSaveFix.DESTROY_UNLOADED
                end
                local partObj = BrushToolSaveFix.findObject(partSquare, part.sprite, nil)
                if partObj then
                    found[#found + 1] = { square = partSquare, obj = partObj }
                end
            end
        end
        for _, part in ipairs(found) do
            part.square:transmitRemoveItemFromSquare(part.obj, false)
        end
    end

    square:transmitRemoveItemFromSquare(target, false)
    if target:getObjectIndex() == -1 then
        return true
    end
    return false, BrushToolSaveFix.DESTROY_STUCK
end

function BrushToolSaveFix.destroyTileOnSquare(square, sprite, index)
    local target = BrushToolSaveFix.findObject(square, sprite, index)
    if not target then
        return false, BrushToolSaveFix.DESTROY_MISSING
    end

    return BrushToolSaveFix.destroyObject(target)
end

-- An overlay sprite is a field on its parent object, not an entry in the
-- square's object list, so transmitRemoveItemFromSquare cannot touch it.
-- Clearing the name empties the slot and leaves the parent in place.
function BrushToolSaveFix.destroyOverlayOnSquare(square, sprite, index, overlay)
    local target = BrushToolSaveFix.findObject(square, sprite, index)
    if not target then
        return false
    end

    local current = target:getOverlaySprite()
    if not current then
        return false
    end

    -- Refuse if the parent is not carrying the overlay the caller asked about,
    -- so a stale request cannot clear whatever happens to be there now.
    if overlay and current:getName() ~= overlay then
        return false
    end

    target:setOverlaySprite("")
    flagForSave(square, target)
    return true
end

-- Attached anim sprites are an indexed list on the parent object, removed by
-- position rather than by identity.
function BrushToolSaveFix.destroyAttachedOnSquare(square, sprite, index, attachedIndex, attached)
    local target = BrushToolSaveFix.findObject(square, sprite, index)
    if not target then
        return false
    end

    local sprites = target:getAttachedAnimSprite()
    if not sprites or sprites:size() == 0 then
        return false
    end

    local function nameAt(i)
        local instance = sprites:get(i)
        local parent = instance and instance:getParentSprite()
        return parent and parent:getName() or nil
    end

    local slot = nil
    if type(attachedIndex) == "number" and attachedIndex >= 0 and attachedIndex < sprites:size()
        and (not attached or nameAt(attachedIndex) == attached) then
        slot = attachedIndex
    elseif attached then
        for i = 0, sprites:size() - 1 do
            if nameAt(i) == attached then
                slot = i
                break
            end
        end
    end

    if not slot then
        return false
    end

    target:RemoveAttachedAnim(slot)
    flagForSave(square, target)
    return true
end
