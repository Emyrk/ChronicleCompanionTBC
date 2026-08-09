# ChronicleCompanionTBC port notes

This directory was copied from ChronicleCompanionWoTLK and adapted for stock
WoW 2.4.3 APIs.

## Code changes

- Changed the TOC interface from 30300 to 20400 and renamed addon metadata.
- Renamed SavedVariables to ChronicleCompanionTBCDB and
  ChronicleCompanionTBCCharDB so the two client variants do not share state.
- Removed dual-spec handling. TBC exposes one talent build and uses the older
  talent API signatures without a talent-group argument.
- Removed Death Knight talent metadata; Death Knights do not exist in TBC.
- Replaced glyph capture with a compatibility shim that returns no data;
  glyphs do not exist in WoW 2.4.3.
- Replaced GetInstanceInfo with IsInInstance plus GetRealZoneText/GetZoneText.
- Corrected arena team reads to use TBC team slots 1-3, then key results by the
  returned team size (2v2, 3v3, or 5v5).
- Kept GetInventoryItemID optional because stock 2.4.3 does not expose it.
- Guarded UI methods that may not exist on stock 2.4.3 frames.
- Restricted the relay hijack list to SPELL_FAILED globals present in the
  Blizzard 2.4.3 GlobalStrings.lua reference.
- Guarded geterrorhandler because its availability varies on legacy clients.

## Production provider parity

The failed-spell relay and its 1023-character field boundary are confirmed live
on the target client. The production data path now ports the provider chain and
wire formats from `ChronicleCompanionWoTLK` main:

```text
Reset -> Zone -> Header -> Vehicle -> PlayerList -> Loot -> Meta
```

`PlayerList` emits the same `P<guid>;<segment>` records as WotLK. TBC omits only
the `Y` glyph segment and dual-spec events because those systems do not exist on
2.4.3. Gear, identity, talents, guild, pet, honor, arena, and inspected peers
retain the WotLK segment letters and formatting.

The `Vehicle` provider remains in its WotLK position, but stock TBC has no
vehicle unit or seat APIs. Its tracker is therefore a clean no-op and never
fabricates vehicle assignments. Zone records retain the WotLK ten-field shape;
fields unavailable on TBC are stable zero or empty values.

Encounter-specific scheduling and ChronicleClassic demultiplexer validation
remain future work.

## Confirmed live on August 9, 2026

The target 2.4.3 client wrote `[1hello]` verbatim into the failed-reason field of
a `SPELL_CAST_FAILED` row, and the relay observed the landing and restored the
localized failure strings immediately afterward. This confirms:

- COMBAT_LOG_EVENT_UNFILTERED fires on this client.
- The failed reason is CLEU argument 12.
- The engine reads overwritten SPELL_FAILED globals at emission time.
- The payload reaches WoWCombatLog.txt verbatim.
- Exact-match landing confirmation and eager restoration work.

The maximum safe failed-reason length is 1023 characters on this client. A
1023-character probe landed verbatim with its terminal marker; a 1024-character
probe was truncated and lost the marker. Normal relay chunks now use 1023 as
the total failed-reason field capacity.
