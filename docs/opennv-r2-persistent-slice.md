# OpenNV R2 persistent Goodsprings slice

This is the next active gameplay gate. It extends the accepted move-door-
container smoke into one ordinary, persistent Fallout: New Vegas interaction
loop. It is not a retail-parity, Pip-Boy, FO3, TTW, JAM, or VR claim.

## Non-negotiable route rules

- Use one manifested OpenMW runtime and one exact FNV profile.
- The engine owns movement, activation, dialogue selection, capture, save, and
  shutdown timing. No host input, window control, synthetic inventory, forced
  weather, camera driving, or proof-state mutation is allowed.
- Use production container, dialogue, barter, and save APIs. Do not open barter
  by directly pushing `GM_Barter`, and do not manufacture an item or caps.
- Retain native frames, logs, configuration hashes, save hashes, process exit,
  and post-reload assertions. Preserve failures in a unique output directory.

## Ordered implementation slices

### R2.0 — Observe Chet's live merchant inventory

Add an engine-owned route that reaches Chet normally, opens his authored
dialogue, resolves the production `ShowBarterMenu` result, and records the
live merchant and player item/caps candidates. It must select no item and make
no state change. This establishes a real, repeatable transaction candidate
instead of guessing an item FormID or injecting a fixture.

R2.0 is implemented and passed in the retained `opennv-r2-chet-20260814-005`
proof directory: six live merchant stacks (55 items) were observed after the
authored door, dialogue, and barter sequence. The route uses three native
frames plus exact-title video, exits cleanly, and records all host-control
flags as false. This is evidence for observation only, not a persistence
claim.

### R2.1 — Container transfer and barter cancellation

On the same route, transfer one ordinary item from an unlocked container
through the normal container UI model. Open Chet's barter through the authored
dialogue result, then cancel. Assert that the proposed transaction made no
merchant, player, or caps delta.

R2.1 is implemented and passed in the retained
`opennv-r2-persistent-20260814-001` proof directory. The normal cash-register
container model transferred one `FormId:0x1034067` item from a two-item stack
to the player (0→1, container 2→1). Chet barter then opened with six live
merchant stacks / 55 items; cancelling through the production trade window
left player items 777, merchant items 55, player caps 300, and merchant caps
37 unchanged. Six native frames, exact-title video, clean exit, and false
host-control flags are retained. This establishes the cancellation invariant;
it does not yet commit a sale or establish reload persistence.

### R2.2 — One live merchant transaction

Reopen barter and select one observed, eligible live item whose cost and caps
are sufficient at runtime. Commit the transaction through the production
barter path. Record item identity, stack/caps deltas, and the resulting UI
state. Any unavailable candidate is a route failure, not permission to seed
inventory.

R2.2 is implemented and passed in the retained
`opennv-r2-transaction-20260814-004` proof directory. The cash register again
transferred `FormId:0x1034067` normally (player 0→1, container 3→2), then
Chet's authored barter bought one live `FormId:0x108ed02` stack item for two
caps through the production offer path. The verified final deltas were player
item 0→1, merchant item 9→8, player caps 300→298, and merchant caps 42→44.
Six native frames, exact-title video, clean exit, and false host-control flags
are retained. This is a completed merchant transaction, not yet a save/reload
persistence claim.

### R2.3 — Native persistence

Request an OpenMW-native save through the production state manager, exit
normally, and cold-load that new save in a second process. Assert the container
transfer and merchant transaction remain, then repeat one ordinary interaction.

## Acceptance

Only R2.3 can promote R2. The report must state the capture method; state that
Windows app control and foreground input were unused; retain native source
frames and telemetry; and pass the relevant validator. Update
`catalog/openmw-fallout-playable-slices-plan.json` only after the retained
artifacts and hashes have been checked.
