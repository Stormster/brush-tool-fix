if isClient() then return end

require "BrushToolSaveFix/BTSF_Shared"

local MODULE = BrushToolSaveFix.MODULE

-- Tell only the admin who asked. A removal that found nothing is the signature
-- of a tile that exists solely in that client's world, so the person holding
-- the brush is the only one who needs to hear about it.
local function notifyMissed(player, what)
    sendServerCommand(player, MODULE, "destroyFailed", { what = what })
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then
        return
    end

    if not BrushToolSaveFix.canUseBrush(player) then
        -- A refusal used to be invisible outside debug mode, so a player whose
        -- role can open the Debug menu but lacks the brush capability saw the
        -- tool "do nothing". Log it for the admin, and tell the player when
        -- they could legitimately have clicked the tool. Anyone else, such as
        -- a replayed packet from a plain user, still gets silence.
        BrushToolSaveFix.warn("refused " .. tostring(command) .. " from "
            .. tostring(player and player:getUsername()) .. ": role lacks UseBrushToolManager")
        if BrushToolSaveFix.canOpenDebugMenu(player) then
            sendServerCommand(player, MODULE, "denied", {})
        end
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
        local ok, reason = BrushToolSaveFix.placeTileOnSquare(square, sprite, player)
        if not ok and reason then
            -- Tell only the admin who asked; nobody else's world changed.
            sendServerCommand(player, MODULE, "placeRefused", {
                sprite = sprite,
                reason = reason,
            })
        end
        BrushToolSaveFix.log((ok and "placed " or "skipped ") .. sprite .. " @ " .. x .. "," .. y .. "," .. z)
        return
    end

    if command == "destroyTile" then
        local sprite = args.sprite
        local index = tonumber(args.index)
        local ok = BrushToolSaveFix.destroyTileOnSquare(square, sprite, index)
        if not ok then
            notifyMissed(player, "tile")
        end
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
        else
            notifyMissed(player, "overlay")
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
        else
            notifyMissed(player, "attached")
        end
        BrushToolSaveFix.log((ok and "removed attached " or "missed attached ") .. attached .. " @ " .. x .. "," .. y .. "," .. z)
        return
    end
end

Events.OnClientCommand.Add(onClientCommand)
BrushToolSaveFix.announce("server command handler registered")
