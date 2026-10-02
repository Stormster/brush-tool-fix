# Brush Tool Save Fix — Project Zomboid (Build 42, Multiplayer)

A small Lua mod for **Project Zomboid** that fixes a Build 42 multiplayer bug where admin Brush Tool tile edits were purely cosmetic: tiles you placed or destroyed looked correct on your screen, then vanished the moment the chunk unloaded, you relogged, or the server restarted.

Available on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3775272983). Requires Build 42.21+.

[![Steam Workshop stats](assets/steam-stats.svg)](https://steamcommunity.com/sharedfiles/filedetails/?id=3775272983)

---

## The problem

Project Zomboid's Brush Tool (an admin/debug tile painter) was written against the singleplayer world model. In multiplayer, `ISBrushToolTileCursor:create()` builds the `IsoObject` directly in the *client's* copy of the cell. Clients don't own world state in B42 — the server does — so nothing was ever transmitted or persisted. The same applied to tile removal, which called a local destroy instead of a replicated one.

The result: map edits that survived exactly as long as the chunk stayed loaded in your client's memory. For anyone building custom map content or repairing griefed tiles on a server, the tool was effectively unusable.

## The fix

The mod makes both operations server-authoritative while keeping the vanilla UI and workflow completely intact.

- **Client** (`BTSF_Client.lua`) wraps `ISBrushToolTileCursor:create()` and the context-menu destroy paths. When `isClient()`, instead of mutating the local cell it fires a `sendClientCommand` with the target coordinates, sprite name, and object index.
- **Server** (`BTSF_Server.lua`) handles the command, re-validates the request, resolves (or creates) the grid square, and applies the change through the engine's replicated placement and `transmitRemoveItemFromSquare` paths so the edit is written to the save and pushed to every connected player.
- **Shared** (`BTSF_Shared.lua`) holds the placement/destroy logic, square lookup, and permission checks so client and server agree on behaviour, and so the mod still works in singleplayer where no round trip is needed.

Both branches end up in the same shared placement routine: a remote client's request is applied by the server, while a world-authoritative process (singleplayer, or a host whose client owns the world) applies it directly instead of falling back to vanilla's unflagged placement.

Details worth calling out:

- **Trust boundary.** The client command carries coordinates, so the server never trusts the sender. Every request is re-checked against the player's role capability (`UseBrushToolManager`), with `isCanUseBrushTool()` and the access level name (`admin`/`moderator`/`overseer`/`gm`) as fallbacks, and all arguments are type-checked and floored before use. A refusal is always logged on the server. The player is told only if their role can open the Debug menu; a plain user replaying the packet gets nothing.
- **Load-order hardening.** Vanilla defines `ISBrushToolTileCursor` under `lua/server`, which isn't reliably loaded when client mod scripts first run. The hook is attempted immediately and retried on `OnGameStart`, `OnCreatePlayer`, and `OnTick`, then unsubscribes itself once it succeeds — so it binds exactly once regardless of load order.
- **Idempotent placement.** The server skips a placement if a matching sprite already exists on the square, preventing duplicate stacked objects from double-clicks or lag. Destroys prefer the client-supplied object index, then fall back to a sprite-name match if indices have shifted.
- **Multi-square tiles are placed whole, or not at all.** Many tiles — tanks, large machinery, wide signage — are one square of a sprite grid spanning several. Vanilla's brush places just the sprite you painted, and the engine will only remove a multi-square object if it can re-find every part: `IsoObjectUtils.getAllMultiTileObjects` walks the grid outward from the clicked sprite and, on the first missing part, clears its list and returns having removed nothing. That is why a brush-placed tank section resists the brush, the admin panel and a sledgehammer alike — and vanilla only got away with it because the fragment evaporated on the next chunk unload. Now that edits persist, it would be permanent. So the placement resolves every square and sprite in the grid up front and places them all; if a square for one of them cannot be had the placement is refused, with a message to the admin who asked rather than a silent no-op.
- **Grids with empty cells.** Eleven vanilla grids are not full rectangles: the L-shaped Office 3 and Office 4 desks in all four facings, the Horse Statue, one `appliances_com_01` group and the Grey Chandelier. Versions up to 1.2.4 refused to place them, on the reasoning above, since `getAllMultiTileObjects` visits every cell and an empty one can never match. They are placed now, empty cells skipped, because the brush can take them out again (next point). The chandelier is a different case: its definition is wrong, not just incomplete. `lighting_indoor_03_0` to `_3` are the left and right halves of two different two-tile lights, but the tile definitions file all four under `Facing=E` and give the second pair grid level 1, so the engine builds a single 2x2x2 grid and would put the second pair on the floor above the first. Nor do the halves join on the squares the grid names: the art is cut for two squares side by side on screen, which on the isometric grid is a diagonal pair, not x+1, so vanilla's own pickup-and-place draws it broken too. The mod recognises an untrustworthy grid by shape rather than by name. The upper level of a genuinely tall object stands on the lower one and shares its footprint; an orientation filed as a level has the lower footprint with x and y swapped. Of the 831 grids in 42.21 only the chandelier fits that. Such a grid is left alone: its sprites paint as single tiles, as vanilla paints them, so the admin puts each half where it looks right, and each half can be destroyed on its own.
- **Destroy removes what the engine refuses.** `IsoGridSquare.transmitRemoveItemFromSquare(obj)` is the all-or-nothing path: when the grid search fails it returns -1, removes nothing and logs nothing, and versions up to 1.2.4 reported that as a successful destroy. That left three things nothing could delete: a grid with an empty cell however completely it was placed, a single piece left by vanilla's brush or an old version of this mod, and a mapped one of either. The whole-object call is still made first, since it also covers double doors, garage doors and entity-defined objects. If the object is still on its square afterwards, the mod removes the parts it can find one by one with the two-argument overload, `transmitRemoveItemFromSquare(obj, false)`, which skips the search and on a server goes straight to `GameServer.RemoveItemFromMap`. The search also fails when a part lies in a chunk the server has not loaded; removing the loaded parts then would leave the rest behind as fragments, so that case is refused with a message instead. A destroy that removed nothing now says which of the three it was: no such tile, part of it unloaded, or the engine would not let go of it.
- **Stairs are laid as a flight.** A staircase is three sprites on three squares, but no tile property links them: no `SpriteGridPos`, no group, only a stairs type (`stairsTW`, `stairsMW`, `stairsBW` or the north three) on each. So there is no grid to place and the brush put down the one step that was painted. The tilesets do keep the steps on consecutive indexes, bottom-middle-top or the reverse, so painting any step now finds the other two either side of the middle one and lays all three in the direction the type gives. A step added to complete the flight gives way to any step of the same kind already on its square, from whatever tileset, so painting one step into a gap repairs a flight rather than stacking a second one on it; the painted step itself is placed as vanilla would. Destroy still takes one step at a time, as vanilla's does, and the brush does not add the landing: the square the top step leads onto needs a floor painted on it like any other.
- **Overlays are attached, not stacked.** Grime, blood, graffiti, road markings and wall detailing are not objects in a mapped world: `CellLoader.DoTileObjectCreation` hangs a `FloorOverlay` sprite on the square's floor and a `WallOverlay` sprite on the wall it names, as an attached sprite. The renderer depends on that, because `IsoSprite` draws an overlay sprite at exactly the depth of the surface under it, so one built as an object of its own z-fights with that surface. `placeMoveableInternal` only knows the attached form for moveable wall decoration and builds every other overlay as a separate object, which is what versions up to 1.2.2 did. The mod now picks the host the way the loader does, attaches the sprite, and pushes it with `transmitUpdatedSpriteToClients`. A floor overlay with no floor under it is refused with a message; a wall overlay with no wall on its edge is still placed as a plain object, as the loader does. Only sprites that are decoration and nothing else are attached; 1.2.3 attached every overlay-flagged sprite, which turned the working ones into inert pictures. The overlay flags are also set on neon lights, street lights, wall pieces and scrap, which the loader sorts out by tile type and container before it reaches its overlay case, so anything typed, named, moveable, colliding, scrappable or holding a container is still built as an object. An overlay that an older version left as an object is skipped as already present; destroying it and painting again gives the attached form.
- **Edits that do nothing say so.** A destroy that finds nothing on the server now tells the admin who asked, instead of looking exactly like one that worked. That case usually means the tile exists only in that client's copy of the world — painted while the mod was not running server-side — so no tool can remove it and a relog clears it. Only the requesting player is told; a replayed packet from someone without brush access still gets nothing back.
- **Overlay and attached sprites can be destroyed.** Vanilla lists a tile's overlay and attached anim sprites under *Copy tile* but only ever its main sprite under *Destroy tile*, so blood decals and attached decoration could be copied around but never removed — in singleplayer either. Both now appear in the destroy submenu. They are fields on the parent object rather than entries in the square's object list, so `transmitRemoveItemFromSquare` cannot reach them and no engine packet covers the change: the server clears the field, flags the object for hot save, and replays the edit to every client with a `sendServerCommand`. Clients apply that replay only to squares they already have loaded, and a request naming an overlay the parent is no longer carrying is refused rather than clearing whatever is there now.
- **Persistence.** Placed tiles are registered as construction on the square so the world save keeps them, rather than relying on chunk-local state.

## Installation

Both the server and every connecting client need the mod.

**Hosted (co-op) games**

Subscribe on the Workshop, then enable the mod in the host's server settings editor like any other mod. Players auto-download it on join.

**Dedicated server**

1. Add `3775272983` to `WorkshopItems=` in your server config.
2. Add `BrushToolSaveFix` to `Mods=`.
3. Restart the server. Clients auto-download on join.

The tool itself is under right-click > Debug > Brush Tool. In multiplayer that submenu only appears for roles with the `UseDebugContextMenu` capability (admin, moderator, gm and observer by default), and the server accepts edits from roles with `UseBrushToolManager` (admin and moderator by default). The "Brush Tool" switch in Admin Powers does not reveal the menu. In singleplayer, launch the game with `-debug`. This mod does not grant access to the tool, it only makes its edits persist, and since 1.2.2 it tells a player whose role can see the menu but not use the brush why nothing happened.

## Repository layout

```
BrushToolSaveFix/
  42/mod.info                          # mod metadata (Build 42)
  42/media/, common/media/             # AnimSets/ and actiongroups/ placeholders, see Notes
  common/media/lua/
    client/BrushToolSaveFix/BTSF_Client.lua   # hooks vanilla cursor, sends commands
    server/BrushToolSaveFix/BTSF_Server.lua   # validates + applies world changes
    shared/BrushToolSaveFix/BTSF_Shared.lua   # shared logic, permissions, helpers
workshop/                              # Workshop listing metadata
tools/sync.ps1                         # copies into Zomboid mods + Workshop staging
```

### Local development

Run `./tools/sync.ps1` after editing to push the mod into `Zomboid\mods\` and the Workshop staging folder in one step, or `./tools/sync.ps1 -Watch` to keep syncing on every save.

Do not link these folders with a junction or symlink. Project Zomboid's mod scanner treats a reparse point as a file, so a linked mod folder silently fails to load and a linked staging folder is rejected on upload with *"Files are not allowed in the Contents/mods/ folder"*. The sync script copies for that reason, and removes any link it finds in a destination.

## Notes

Intended as a stopgap until The Indie Stone patches the Brush Tool upstream. Tested on B42.21 dedicated and hosted multiplayer.

The `AnimSets` and `actiongroups` folders hold a placeholder file each and nothing else. On a server or a multiplayer client, `AdvancedAnimator` walks `common/media/AnimSets`, `common/media/actiongroups` and the same two under `42/` for every active mod to build its animation checksum, without checking that they exist, and logs `AdvancedAnimator$1.visitFileFailed ... NoSuchFileException` for each one that does not. The error is harmless, and every mod without animations produces it, but it names the mod and turns up in bug reports. Only `.xml` files count towards the checksum, so the placeholders change nothing.

### What changed in Build 42.21

- `ISMoveableSpriteProps:placeMoveableInternal` now takes the placing character as its first argument. Mod versions before 1.2.1 error on every placement under 42.21, and 1.2.1 does not work on 42.20.
- On a client, `ISBuildingObject:tryBuild` no longer calls `create()` for a cursor whose `Type` is `ISBrushToolTileCursor`. It sends a new `AddObjectToMap` packet instead. The server answers that packet with `CellLoader.DoTileObjectCreation`, the same routine map loading uses, so the tile is built unflagged and is not written to the save. It then relays the packet to nearby clients, which fire `OnTileObjectAdded` and run `ISBrushToolTileCursor:create` locally on the class itself, with no character. That is vanilla's attempt at the same bug, and it still loses the edit on chunk unload.
- The server throws that packet away when it has no square at the target, logging `The packet AddObjectToMap is not consistent`. Above ground a square only exists where the server has had a reason to create one, and the packet handler never creates any, while the client creates squares under the cursor and so shows nothing wrong. Players see this as a tile landing next to existing ones and the next tile out from it failing until the area reloads. The mod's command resolves or creates the square on the server, so it is not affected.
- The mod's `tryBuild` wrapper hides the cursor's `Type` for the duration of the vanilla call, so vanilla takes its `self:create()` branch and the hooked `create` sends the mod's own command as before. A `create` call with no character, which only the `OnTileObjectAdded` relay produces, is passed straight through to vanilla.

## Permissions

Please do not reupload, mirror, or repackage this mod on the Steam Workshop or elsewhere. Link players to the [Workshop page](https://steamcommunity.com/sharedfiles/filedetails/?id=3775272983) instead — that keeps everyone on the same version. Bug reports and questions are welcome in the Workshop comments or discussions.

---

Mod ID: `BrushToolSaveFix`  
Workshop ID: `3775272983`
