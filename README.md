# Kallskär Nuclear Power Plant (K1, SFR-1000)

Multiplayer Roblox simulator of a fictional Swedish 2,380 MWt pool-type sodium fast reactor.
Design spec (source of truth for every number): [`kallskar_handoff/`](kallskar_handoff/00_README_START_HERE.txt),
also concatenated in `KALLSKAR_ALL_IN_ONE.txt`. Design decisions made during implementation: [`docs/DECISIONS.md`](docs/DECISIONS.md).

## Layout

| Path | Studio location (Rojo) | What |
|---|---|---|
| `src/shared/` | `ReplicatedStorage.Kallskar` | Client-safe code. `Config/` holds every spec number with provenance. |
| `src/server/` | `ServerScriptService.Kallskar` | Simulation, framework, systems. `Dev/` is Studio-only tooling. |
| `src/client/` | `StarterPlayer.StarterPlayerScripts.Kallskar` | Client rendering and input. |
| `tests/` | `ServerStorage.KallskarTests` | `Runner` + `*Spec` modules. |
| `tools/xsgen/` | — | OpenMC cross-section generation (runs in WSL). |
| `tools/derive/` | — | Reproducible derivations behind `derived` Config values. |
| `tools/studio/` | — | Disk↔Studio drift check (`manifest.ps1` + `hash_sources.luau`). |

Large data (nuclear data, OpenMC runs) lives on `D:\Roblox Projects\Kallinskar Nuclear Power Plant\`, not in git.

## Rules

- **No guesswork.** Every number in `Config` carries provenance: `spec`, `tuning` (spec †), `cited`, `derived`
  (script in `tools/derive/`), `engineering` (software parameter, with reason) or `decision` (`docs/DECISIONS.md`).
  A bare number fails at load time.
- **Metatables at system boundaries, never in numeric kernels.** Config is frozen with `table.freeze`.
- **Disk is the source of truth.** Rojo syncs `default.project.json`'s four folders only; Workspace is never touched.

## Running tests (Studio)

Set attribute `RunTests = true` on `ServerStorage.KallskarTests` (optional `TestFilter`), press Play.
Results print with the `[KSK-TEST]` prefix and are stored in `ServerStorage.KallskarTests.LastReport`.

Disk-side checks: `pwsh -File tools/check_provenance.ps1`, `pwsh -File tools/studio/manifest.ps1`.

## Syncing with Rojo

```
rojo plugin install      # once, then restart Studio
rojo serve               # in this folder; then Plugins → Rojo → Connect in Studio
```
