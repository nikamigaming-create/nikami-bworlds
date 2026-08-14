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

### R2.1 — Container transfer and barter cancellation

On the same route, transfer one ordinary item from an unlocked container
through the normal container UI model. Open Chet's barter through the authored
dialogue result, then cancel. Assert that the proposed transaction made no
merchant, player, or caps delta.

### R2.2 — One live merchant transaction

Reopen barter and select one observed, eligible live item whose cost and caps
are sufficient at runtime. Commit the transaction through the production
barter path. Record item identity, stack/caps deltas, and the resulting UI
state. Any unavailable candidate is a route failure, not permission to seed
inventory.

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
