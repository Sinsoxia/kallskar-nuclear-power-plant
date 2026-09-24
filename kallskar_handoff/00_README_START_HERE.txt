KALLSKAR NUCLEAR POWER PLANT: CLAUDE CODE HANDOFF PACK
Design specification Rev A6, 24 September 2026
Display name: Kallskär Nuclear Power Plant. Use ASCII "Kallskar" in code, instance names and DataStore keys.

====================================================================================================
WHAT THIS PROJECT IS
====================================================================================================
A multiplayer Roblox simulator of a fictional Swedish nuclear power plant, Kallskär Nuclear Power
Plant, unit K1. Its reactor is the SFR-1000: a 2,380 MWt pool-type sodium-cooled fast reactor with
MOX fuel, feeding two 500 MWe turbine-generators through three secondary sodium loops. Loop 1 feeds
turbine A, loop 3 feeds turbine B, and loop 2 feeds both through splitter valves.

Players staff several separate control rooms and have to talk to each other and walk between rooms to
keep the plant running. The goal is realism that stays fun: hard but fair, never AFK-able on manual,
never soloable from one room.

Developer: Aqua (Roblox / Luau). Nothing has been built yet. These files describe the design only.

====================================================================================================
HOW TO USE THESE FILES
====================================================================================================
1. Read this file, then 01 (project brief and game rules), then 02 (design history and rationale).
2. Treat the spec files 10 to 16 as the source of truth for every number, setpoint, rule and name.
3. Values marked † are tuning values: realistic in size and expected to change in playtesting.
   Everything else was derived deliberately and agrees with the rest of the spec, so ask the developer
   before changing it.
4. If the spec and a newer instruction from the developer disagree, the developer wins. Point out the
   conflict so the spec can be updated.
5. File 20 holds the assumptions and Python source that produced the heat balance and derived tables.
6. A formatted HTML version of the same spec exists for humans; these text files carry the same content.

====================================================================================================
FILE INDEX
====================================================================================================
00_README_START_HERE.txt ........................ This file
01_project_brief_and_game_rules.txt ............. Goals, anti-goals, design principles, multiplayer rules, interface
02_design_history_and_rationale.txt ............. Why the plant is this way, rejected options, real events used
10_spec_conventions_overview_site.txt ........... Units, clocks, decisions, plant at a glance, topology, site, history, seasons
11_spec_core_and_physics.txt .................... Core map, fuel, thermal limits, kinetics, feedbacks, rods, instruments, decay heat
12_spec_primary_secondary_steam_generators.txt .. Pool, pumps, IHXs, cover gas, DRACS, secondary loops, SGs, splitter, reheat
13_spec_turbines_feedwater_electrical.txt ....... Turbines, trips, bypass, condensers, seawater, feedwater, electrical, Nordic grid
14_spec_control_protection_rooms_access.txt ..... Modes, part-load program, ownership, auto controllers, protection, limits,
                                                  rooms, desks, field actions, crew sizes, anti-AFK, hybrid rooms, access, guides
15_spec_dispatcher_damage_scenarios.txt ......... Grid dispatcher, scoring, fatigue and degradation, scenario director, 28 scenarios
16_spec_roblox_implementation_appendices.txt .... Tick loops, kinetics solver, thermal nodes, multiplayer checks, persistence,
                                                  modules, sodium properties, tags, glossary, revision log
20_derivations_and_calc_script.txt .............. Assumptions and Python source for the derived numbers

====================================================================================================
HARD CONSTRAINTS FOR THE CODE
====================================================================================================
- Roblox, Luau. The server runs the simulation authoritatively; clients render and send commands.
- Simulate numbers, never moving fluid geometry. Performance is an explicit design goal (file 01).
- Fixed-step loops: 10 Hz fast physics, 1 Hz slow processes, replication at 5 Hz and 1 Hz (file 16).
- Reactor physics is real-time 3D multigroup space-time kinetics: hexagonal-Z nodal diffusion, improved
  quasi-static method, coupled per assembly to thermal-hydraulics (file 11 section 3.7, file 16
  section 14.2). The amplitude uses the prompt-jump form; explicit integration at 10 Hz blows up.
  The heavy shape solve must be time-sliced across frames. Point kinetics stays as fallback and check.
- Modular: one ModuleScript per system behind a common interface (init, step, getState, applyCommand,
  faults), so failure end states, scenarios and later features plug in without touching the core loop.
- One shared config module holds every spec number; the simulation, guide boards and tests read it.
- Controls: any player within reach of a panel may use it, seated or standing. Critical controls also
  require minimum playtime. Every action is logged with player name and time.
- Plant condition persists per private server with an owner reset; public servers start fresh.

====================================================================================================
DECIDED BUT NOT YET DETAILED
====================================================================================================
- Interface: hybrid control rooms in the style of Temelín, analog panels plus plant computer screens.
- Scenario director: required; first rules and costs in file 15, section 13.1.
- Guide boards around the plant: file 14, section 10.8.
- Vote-kick after a player trips the plant; the justified-trip safeguard is proposed, not confirmed.

====================================================================================================
NOT DECIDED YET: DON'T ASSUME
====================================================================================================
- Build order and the first playable slice.
- Failure end states: core damage, losing a building to sodium fire, regulator-forced outages. Keep
  hooks for them; don't implement them.
- Playable refuelling. For now a refuelling outage is a timed wait.
- Panel-by-panel instrument layouts and full tag lists.
- Exact minimum playtime for critical controls (3 h suggested) and vote-kick thresholds.
