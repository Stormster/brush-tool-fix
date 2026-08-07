# Brush Tool Save Fix — Project Zomboid (Build 42, Multiplayer)

A small Lua mod for **Project Zomboid** that fixes a Build 42 multiplayer bug where admin Brush Tool tile edits were purely cosmetic: tiles you placed or destroyed looked correct on your screen, then vanished the moment the chunk unloaded, you relogged, or the server restarted.

Available on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3775272983). Requires Build 42.20+.

[![Steam Workshop stats](assets/steam-stats.svg)](https://steamcommunity.com/sharedfiles/filedetails/?id=3775272983)

---

## The problem

Project Zomboid's Brush Tool (an admin/debug tile painter) was written against the singleplayer world model. In multiplayer, `ISBrushToolTileCursor:create()` builds the `IsoObject` directly in the *client's* copy of the cell. Clients don't own world state in B42 — the server does — so nothing was ever transmitted or persisted. The same applied to tile removal, which called a local destroy instead of a replicated one.

The result: map edits that survived exactly as long as the chunk stayed loaded in your client's memory. For anyone building custom map content or repairing griefed tiles on a server, the tool was effectively unusable.

## The fix

The mod makes both operations server-authoritative while keeping the vanilla UI and workflow completely intact.

- **Client** (`BTSF_Client.lua`) wraps `ISBrushToolTileCursor:create()` and the context-menu destroy path. When `isClient()`, instead of mutating the local cell it fires a `sendClientCommand` with the target coordinates, sprite name, and object index.
- **Server** (`BTSF_Server.lua`) handles the command, re-validates the request, resolves (or creates) the grid square, and applies the change through the engine's replicated placement and `transmitRemoveItemFromSquare` paths so the edit is written to the save and pushed to every connected player.
- **Shared** (`BTSF_Shared.lua`) holds the placement/destroy logic, square lookup, and permission checks so client and server agree on behaviour, and so the mod still works in singleplayer where no round trip is needed.

Both branches end up in the same shared placement routine: a remote client's request is applied by the server, while a world-authoritative process (singleplayer, or a host whose client owns the world) applies it directly instead of falling back to vanilla's unflagged placement.

Details worth calling out:

- **Trust boundary.** The client command carries coordinates, so the server never trusts the sender. Every request is re-checked against `isCanUseBrushTool()` and access level (`admin`/`moderator`/`overseer`/`gm`), and all arguments are type-checked and floored before use. A non-admin replaying the packet gets nothing.
- **Load-order hardening.** Vanilla defines `ISBrushToolTileCursor` under `lua/server`, which isn't reliably loaded when client mod scripts first run. The hook is attempted immediately and retried on `OnGameStart`, `OnCreatePlayer`, and `OnTick`, then unsubscribes itself once it succeeds — so it binds exactly once regardless of load order.
- **Idempotent placement.** The server skips a placement if a matching sprite already exists on the square, preventing duplicate stacked objects from double-clicks or lag. Destroys prefer the client-supplied object index, then fall back to a sprite-name match if indices have shifted.
- **Persistence.** Placed tiles are registered as construction on the square so the world save keeps them, rather than relying on chunk-local state.

## Installation

Both the server and every connecting client need the mod.

**Dedicated server, co-op/hosted games**

1. Add `3775272983` to `WorkshopItems=` in your server config.
2. Add `BrushToolSaveFix` to `Mods=`.
3. Restart the server. Clients auto-download on join.

Then enable the Brush Tool as usual: Admin Powers in multiplayer, or `-debug` in singleplayer. This mod does not grant access to the tool, it only makes its edits persist.

## Repository layout

```
BrushToolSaveFix/
  42/mod.info                          # mod metadata (Build 42)
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

Intended as a stopgap until The Indie Stone patches the Brush Tool upstream. Tested on B42.20+ dedicated and hosted multiplayer.

## Permissions

Please do not reupload, mirror, or repackage this mod on the Steam Workshop or elsewhere. Link players to the [Workshop page](https://steamcommunity.com/sharedfiles/filedetails/?id=3775272983) instead — that keeps everyone on the same version. Bug reports and questions are welcome in the Workshop comments or discussions.

---

Mod ID: `BrushToolSaveFix`  
Workshop ID: `3775272983`
