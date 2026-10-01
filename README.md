# Crate Rush: Crate System

The server-authoritative enemy ("crate") system from **Crate Rush**, a Roblox tower defense game. The server runs the simulation, and clients only render it. It is written in strict Luau.

## Files

| File | Side | Role |
|---|---|---|
| `Crates.luau` | Shared | Crate definitions. Each entry is a tagged union on `Kind` (`Damage`, `Loot` or `Currency`), so invalid combinations fail type-checking. |
| `CrateReplication.luau` | Shared | The network contract: event names, tick rate and position-buffer layout. |
| `ServerCrate.luau` | Server | One crate's simulation state, plus waypoint movement and damage. |
| `CrateService.luau` | Server | Spawns, simulates, damages and removes crates, and replicates them to clients. |
| `ClientCrate.luau` | Client | A crate's visual twin. Handles interpolation, facing, hit shake and the health bar. |
| `CrateRenderController.luau` | Client | Decodes the network buffer and drives every `ClientCrate`. |
| `CrateEffectsController.luau` | Client | Pooled hit and death effects: damage numbers, dust, highlights, sounds and potion auras. |

## How it works

1. `CrateService` creates a `ServerCrate`, gives it a network id and sends a one-off **spawn** event to the players viewing that plot.
2. Every `Heartbeat`, the server moves each crate along its lane's waypoints. Crates that reach the end damage the base and despawn.
3. Every network tick (`TickRate = 1/20`), each player receives **one buffer** holding the positions of every crate on the plots they can see.
4. The client decodes the buffer and points each `ClientCrate` at its new target. Every frame it interpolates all crates toward their targets and moves them in a single call.
5. Damage and despawn are small events that trigger pooled effects on the client.

## Performance techniques

- **Binary packing:** a crate's position goes over the network as a 10-byte record in a Luau `buffer`: a `u16` id, then `f32` X and `f32` Z. Y is constant, so it is never sent. A table holding a number id and a `Vector3` would cost at least twice as much before any table overhead.
- **Batching:** all positions travel in one remote call per player per tick, not one call per crate. Spawn, damage and despawn are sent only when they happen.
- **Interest management:** each player only receives crates on the plots they are viewing (`GetVisiblePlotIds` / `GetViewers`).
- **Fixed network tick:** the server simulates every frame but only sends at 20 Hz. The client fills the gaps by **interpolating** between snapshots, so movement stays smooth while bandwidth stays bounded.
- **Network id recycling:** freed ids return to a FIFO free-list. A `u16` id therefore only limits how many crates are alive at once (65,535), not how many spawn over a session.
- **Batched movement:** every crate is moved with one `Workspace:BulkMoveTo` per frame instead of one `CFrame` write per part. Crates are anchored, so physics never touches them, and the parts and CFrames arrays are reused every frame to avoid garbage.
- **Object pooling:** crate models (`TemplatePool`, 15 prewarmed per type) and effects (`EffectPool` for damage numbers, dust and auras) are recycled instead of created and destroyed. Fade tweens are cached per pooled instance, and each highlight's tween is replayed rather than rebuilt.
- **Cheap math:** range checks compare squared distances, so there is no `sqrt`. Distance-to-end reads cached cumulative path lengths instead of walking the path each time.

## Test results

With **200 crates rendered at once**, the client's network receive (Recv) rate measured **20–28 KB/s**. That figure is the client's total receive, not just crate traffic.

The commonly cited soft limit for Roblox is about **50 KB/s per client**. Above that, ping starts climbing, and the Network Receive stat moves into its orange and then red warning colours. A full 200-crate wave therefore uses roughly half of that budget and stays in the safe range.

## Dependencies (not included)

These modules rely on the game's own framework and are shown for reference:

- **Framework:** `ServerSocket` / `ClientSocket` (a networking wrapper) and the `Loader` (Init → Start lifecycle).
- **Server services:** `PathService`, `PlotService`, `RewardService`, `PotionService`, `EndpointService`.
- **Client:** `TemplatePool`, `EffectPool`, `EffectsUtil`, `SoundController`.
- **Data:** `CurrencyReplication` and the `Potions` index.

## Testing screen shots

<img width="1071" height="51" alt="Screenshot 2026-10-01 at 19 49 16" src="https://github.com/user-attachments/assets/ba34c723-32fb-49f3-b4db-7c4875c1ea6d" />

<img width="1067" height="532" alt="Screenshot 2026-10-01 at 19 48 49" src="https://github.com/user-attachments/assets/886c33c9-096a-4a8e-a882-89c8890cb117" />

