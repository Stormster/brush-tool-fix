BrushToolSaveFix = BrushToolSaveFix or {}

BrushToolSaveFix.MODULE = "BrushToolSaveFix"
BrushToolSaveFix.VERSION = "1.2.0"

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

function BrushToolSaveFix.canUseBrush(player)
    if not player then
        return false
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

-- One sprite on one square, exactly the way vanilla's cursor does it. Returns
-- false when that sprite is already present, so a double-click or a laggy
-- repeat cannot stack duplicates.
local function placeSpriteOnSquare(square, sprite)
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
    props:placeMoveableInternal(square, instanceItem("Base.Plank"), sprite)

    if buildUtil and buildUtil.setHaveConstruction then
        buildUtil.setHaveConstruction(square, true)
    end

    return true
end

-- Work out every square/sprite pair a multi-square placement needs, before
-- anything is written to the world.
--
-- The engine only ever removes a multi-square object if it can re-find every
-- part of it. IsoObjectUtils.getAllMultiTileObjects walks the whole grid
-- outward from the sprite you clicked and, the moment one part is missing,
-- clears its list and returns false having removed nothing at all. Vanilla's
-- brush places only the single sprite you painted, which is why a brush-placed
-- tank section resists the brush, the admin panel and a sledgehammer alike.
--
-- So it is all parts or none. Returning nil here refuses the placement rather
-- than leaving an indestructible fragment on someone's map.
local function resolveGridParts(square, grid, spr)
    local px = grid:getSpriteGridPosX(spr)
    local py = grid:getSpriteGridPosY(spr)
    local pz = grid:getSpriteGridPosZ(spr)
    local x, y, z = square:getX(), square:getY(), square:getZ()

    local parts = {}
    for level = 0, grid:getLevels() - 1 do
        for gx = 0, grid:getWidth() - 1 do
            for gy = 0, grid:getHeight() - 1 do
                local cell = gx .. "," .. gy .. "," .. level

                -- getAllMultiTileObjects compares sprite instances and has no
                -- concept of an empty cell, so a hole in the grid means the
                -- object could never be walked back once placed.
                local partSprite = grid:getSprite(gx, gy, level)
                local name = partSprite and partSprite:getName() or nil
                if not name then
                    return nil, "grid has no sprite at " .. cell
                end

                local target = BrushToolSaveFix.getOrCreateSquare(x + gx - px, y + gy - py, z + level - pz)
                if not target then
                    return nil, "no square for grid cell " .. cell
                end

                parts[#parts + 1] = { square = target, sprite = name }
            end
        end
    end

    return parts
end

-- Returns placed, reason. A false with no reason is an ordinary skip (the
-- sprite was already there); a false with a reason is a refusal worth showing
-- to whoever asked for it.
function BrushToolSaveFix.placeTileOnSquare(square, sprite)
    if not square or not sprite or sprite == "" then
        return false
    end

    local grid, spr = BrushToolSaveFix.getSpriteGrid(sprite)
    if not grid then
        return placeSpriteOnSquare(square, sprite)
    end

    local parts, reason = resolveGridParts(square, grid, spr)
    if not parts then
        BrushToolSaveFix.log("refused multi-square " .. sprite .. ": " .. tostring(reason))
        return false, reason
    end

    local placed = false
    for _, part in ipairs(parts) do
        if placeSpriteOnSquare(part.square, part.sprite) then
            placed = true
        end
    end

    return placed
end

function BrushToolSaveFix.destroyTileOnSquare(square, sprite, index)
    local target = BrushToolSaveFix.findObject(square, sprite, index)
    if not target then
        return false
    end

    square:transmitRemoveItemFromSquare(target)
    return true
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
