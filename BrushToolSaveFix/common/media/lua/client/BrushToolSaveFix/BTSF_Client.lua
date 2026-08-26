require "BrushToolSaveFix/BTSF_Shared"

local MODULE = BrushToolSaveFix.MODULE
local hookedCreate = false

-- A brush action that does nothing used to look exactly like one that worked.
-- That is how both indestructible half-objects and client-only ghost tiles went
-- unexplained for so long. Say something instead.
local function notify(character, text)
    BrushToolSaveFix.log(text)
    if HaloTextHelper and character then
        HaloTextHelper.addBadText(character, text)
    end
end

local function notifyRefused(character, sprite)
    notify(character, tostring(sprite) .. " spans several tiles and will not fit here")
end

-- The server could not find what it was asked to remove. Usually that means the
-- tile exists only in this client's copy of the world -- painted while the mod
-- was not running server-side -- in which case nothing can remove it and a
-- relog clears it.
local function notifyDestroyMissed(character, what)
    if what == "overlay" then
        notify(character, "that overlay is not on the tile the server has")
    elseif what == "attached" then
        notify(character, "that attached sprite is not on the tile the server has")
    else
        notify(character, "the server has no such tile here, nothing was removed")
    end
end

local function sendPlace(character, x, y, z, sprite)
    sendClientCommand(character, MODULE, "placeTile", {
        x = x,
        y = y,
        z = z,
        sprite = sprite,
    })
end

-- Coordinates plus the parent object's identity. The server re-resolves the
-- object from these rather than trusting anything the client hands it.
local function objectArgs(obj)
    local square = obj:getSquare()
    return {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        index = obj:getObjectIndex(),
        sprite = obj:getSprite():getName(),
    }
end

local function isAddressable(obj)
    return obj ~= nil and obj:getSquare() ~= nil and obj:getSprite() ~= nil
        and obj:getSprite():getName() ~= nil
end

local function sendDestroy(character, obj)
    if not isAddressable(obj) then
        return
    end

    sendClientCommand(character, MODULE, "destroyTile", objectArgs(obj))
end

local function destroyTile(obj, playerObj)
    if isClient() then
        sendDestroy(playerObj, obj)
        return
    end

    if obj and obj:getSquare() then
        obj:getSquare():transmitRemoveItemFromSquare(obj)
    end
end

local function destroyOverlay(obj, playerObj, overlay)
    if not isAddressable(obj) then
        return
    end

    local args = objectArgs(obj)
    args.overlay = overlay

    if isClient() then
        sendClientCommand(playerObj, MODULE, "destroyOverlay", args)
        return
    end

    BrushToolSaveFix.destroyOverlayOnSquare(obj:getSquare(), args.sprite, args.index, overlay)
end

local function destroyAttached(obj, playerObj, attachedIndex, attached)
    if not isAddressable(obj) then
        return
    end

    local args = objectArgs(obj)
    args.attachedIndex = attachedIndex
    args.attached = attached

    if isClient() then
        sendClientCommand(playerObj, MODULE, "destroyAttached", args)
        return
    end

    BrushToolSaveFix.destroyAttachedOnSquare(obj:getSquare(), args.sprite, args.index, attachedIndex, attached)
end

local function setTileCursor(tilename, playerObj)
    local cursor = ISBrushToolTileCursor:new(tilename, tilename, playerObj)
    getCell():setDrag(cursor, playerObj:getPlayerNum())
end

-- Vanilla defines ISBrushToolTileCursor in lua/server, which is not always
-- available when client mod scripts first load. Hook after it exists.
local function hookCreate()
    if hookedCreate then
        return true
    end
    if not ISBrushToolTileCursor or type(ISBrushToolTileCursor.create) ~= "function" then
        return false
    end

    local _create = ISBrushToolTileCursor.create
    function ISBrushToolTileCursor:create(x, y, z, north, sprite)
        if isClient() then
            sendPlace(self.character, x, y, z, sprite)
            return
        end

        -- Singleplayer, and any host whose client is world-authoritative, never
        -- send a command. Vanilla's create() would run here and skip the
        -- construction flag, so tiles vanish on chunk unload just like in MP.
        if x and y and z then
            local square = BrushToolSaveFix.getOrCreateSquare(math.floor(x), math.floor(y), math.floor(z))
            if square then
                local ok, reason = BrushToolSaveFix.placeTileOnSquare(square, sprite)
                if not ok and reason then
                    notifyRefused(self.character, sprite)
                end
                return
            end
        end

        return _create(self, x, y, z, north, sprite)
    end

    hookedCreate = true
    BrushToolSaveFix.announce("client hook installed on ISBrushToolTileCursor.create")
    return true
end

local function onTickHook()
    if hookCreate() then
        Events.OnTick.Remove(onTickHook)
    end
end

Events.OnGameStart.Add(hookCreate)
Events.OnCreatePlayer.Add(function()
    hookCreate()
end)
Events.OnTick.Add(onTickHook)
hookCreate()

-- Overlay and attached sprites live on their parent object, not in the square's
-- object list, so the server has no object packet to push their removal with.
-- It echoes the change it applied back to everyone, and each client repeats it.
local function onServerCommand(module, command, args)
    if module ~= MODULE or type(args) ~= "table" then
        return
    end

    -- Not tied to a square: the server refused a placement this client asked
    -- for, and only this client is told.
    if command == "placeRefused" then
        notifyRefused(getPlayer(), args.sprite)
        BrushToolSaveFix.log("server refused placement: " .. tostring(args.reason))
        return
    end

    if command == "destroyFailed" then
        notifyDestroyMissed(getPlayer(), args.what)
        return
    end

    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = tonumber(args.z)
    if not x or not y or not z then
        return
    end

    local square = BrushToolSaveFix.getExistingSquare(math.floor(x), math.floor(y), math.floor(z))
    if not square then
        return
    end

    if command == "destroyOverlay" then
        BrushToolSaveFix.destroyOverlayOnSquare(square, args.sprite, tonumber(args.index), args.overlay)
    elseif command == "destroyAttached" then
        BrushToolSaveFix.destroyAttachedOnSquare(square, args.sprite, tonumber(args.index),
            tonumber(args.attachedIndex), args.attached)
    end
end

Events.OnServerCommand.Add(onServerCommand)

ISWorldObjectContextMenu.doBrushToolOptions = function(context, worldobjects, player)
    local playerObj = getSpecificPlayer(player)

    local addTooltip = function(option, spriteName)
        local tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip:setName("")
        tooltip:setTexture(spriteName)
        option.toolTip = tooltip
    end

    context:addOption("Brush Tool Manager", playerObj, BrushToolManager.openPanel)

    local copyOption = context:addOption("Copy tile", worldobjects)
    local copySubMenu = context:getNew(context)
    context:addSubMenu(copyOption, copySubMenu)

    local destroyOption = context:addOption("Destroy tile", worldobjects)
    local destroySubMenu = context:getNew(context)
    context:addSubMenu(destroyOption, destroySubMenu)

    for _, obj in ipairs(worldobjects) do
        -- Overlay and attached sprites are addressed through their parent, so
        -- the parent's own sprite name is what identifies them over the wire.
        -- Without one they can still be copied, just not destroyed.
        local mainSprite = obj:getSprite() ~= nil and obj:getSprite():getName() or nil

        if mainSprite then
            local opt = copySubMenu:addOption("[MAIN] " .. mainSprite, mainSprite, setTileCursor, playerObj)
            addTooltip(opt, mainSprite)
            opt = destroySubMenu:addOption(mainSprite, obj, destroyTile, playerObj)
            addTooltip(opt, mainSprite)
        end

        local overlaySprite = obj:getOverlaySprite() ~= nil and obj:getOverlaySprite():getName() or nil
        if overlaySprite then
            local opt = copySubMenu:addOption("[OVERLAY] " .. overlaySprite, overlaySprite, setTileCursor, playerObj)
            addTooltip(opt, overlaySprite)

            if mainSprite then
                opt = destroySubMenu:addOption("[OVERLAY] " .. overlaySprite, obj, destroyOverlay, playerObj, overlaySprite)
                addTooltip(opt, overlaySprite)
            end
        end

        local attachedSprites = obj:getAttachedAnimSprite()
        if attachedSprites ~= nil then
            for i = 0, attachedSprites:size() - 1 do
                local sprite = attachedSprites:get(i):getParentSprite()
                local attachedName = sprite and sprite:getName() or nil
                if attachedName then
                    local opt = copySubMenu:addOption("[ATTACHED] " .. attachedName, attachedName, setTileCursor, playerObj)
                    addTooltip(opt, attachedName)

                    if mainSprite then
                        opt = destroySubMenu:addOption("[ATTACHED] " .. attachedName, obj, destroyAttached, playerObj, i, attachedName)
                        addTooltip(opt, attachedName)
                    end
                end
            end
        end
    end
end
