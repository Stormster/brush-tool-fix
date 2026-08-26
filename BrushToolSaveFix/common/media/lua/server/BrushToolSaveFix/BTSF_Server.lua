if isClient() then return end

require "BrushToolSaveFix/BTSF_Shared"

local MODULE = BrushToolSaveFix.MODULE

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then
        return
    end

    if not BrushToolSaveFix.canUseBrush(player) then
        BrushToolSaveFix.log("denied " .. tostring(command) .. " from " .. tostring(player and player:getUsername()))
        return
    end

    if type(args) ~= "table" then
        return
    end

    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = tonumber(args.z)
    if not x or not y or not z then
        return
    end

    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    local square = BrushToolSaveFix.getOrCreateSquare(x, y, z)
    if not square then
        BrushToolSaveFix.log("no square for " .. x .. "," .. y .. "," .. z)
        return
    end

    if command == "placeTile" then
        local sprite = args.sprite
        if type(sprite) ~= "string" or sprite == "" then
            return
        end
        local ok = BrushToolSaveFix.placeTileOnSquare(square, sprite)
        BrushToolSaveFix.log((ok and "placed " or "skipped ") .. sprite .. " @ " .. x .. "," .. y .. "," .. z)
        return
    end

    if command == "destroyTile" then
        local sprite = args.sprite
        local index = tonumber(args.index)
        local ok = BrushToolSaveFix.destroyTileOnSquare(square, sprite, index)
        BrushToolSaveFix.log((ok and "destroyed " or "missed ") .. tostring(sprite) .. " @ " .. x .. "," .. y .. "," .. z)
        return
    end

    if command == "destroyOverlay" then
        local sprite = args.sprite
        local overlay = args.overlay
        if type(sprite) ~= "string" or type(overlay) ~= "string" then
            return
        end
        local index = tonumber(args.index)
        local ok = BrushToolSaveFix.destroyOverlayOnSquare(square, sprite, index, overlay)
        if ok then
            -- Removing an overlay mutates an existing object rather than the
            -- square's object list, so no engine packet covers it. Replay the
            -- applied change on every client, the sender included.
            sendServerCommand(MODULE, "destroyOverlay", {
                x = x,
                y = y,
                z = z,
                index = index,
                sprite = sprite,
                overlay = overlay,
            })
        end
        BrushToolSaveFix.log((ok and "cleared overlay " or "missed overlay ") .. overlay .. " @ " .. x .. "," .. y .. "," .. z)
        return
    end

    if command == "destroyAttached" then
        local sprite = args.sprite
        local attached = args.attached
        if type(sprite) ~= "string" or type(attached) ~= "string" then
            return
        end
        local index = tonumber(args.index)
        local attachedIndex = tonumber(args.attachedIndex)
        local ok = BrushToolSaveFix.destroyAttachedOnSquare(square, sprite, index, attachedIndex, attached)
        if ok then
            sendServerCommand(MODULE, "destroyAttached", {
                x = x,
                y = y,
                z = z,
                index = index,
                sprite = sprite,
                attachedIndex = attachedIndex,
                attached = attached,
            })
        end
        BrushToolSaveFix.log((ok and "removed attached " or "missed attached ") .. attached .. " @ " .. x .. "," .. y .. "," .. z)
        return
    end
end

Events.OnClientCommand.Add(onClientCommand)
BrushToolSaveFix.announce("server command handler registered")
