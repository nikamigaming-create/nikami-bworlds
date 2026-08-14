# FNV Pip-Boy, Inventory, and Held-Item Focus

Date: 2026-08-12

This work is deliberately split into two phases. Flat-screen behavior must pass
before any VR integration begins. Retail Fallout: New Vegas data and retained
native observations are the behavior and animation oracle; no hand-authored pose
or per-key hand gesture is accepted as parity.

## Phase 1: flat-screen acceptance order

1. **Physical Pip-Boy controls and lifecycle**
   - A documented key opens and closes the physical Pip-Boy.
   - STATS, ITEMS, DATA, and MAP are reachable with visible control guidance.
   - Both authored arms remain continuous during raise, held use, and lower.
   - The right arm uses the authored terminal Pip-Boy hold. It must not run a
     looping manipulation clip merely because the menu is open.
2. **First firearm vertical slice**
   - Select the 9mm pistol from ITEMS/WEAP.
   - The exact weapon and compatible ammunition records become selected.
   - Closing the Pip-Boy produces a visible first-person weapon.
   - Reload transfers ammunition from reserve into the magazine.
   - Fire consumes loaded ammunition and produces the authored attack action.
   - Reopening the Pip-Boy reports the same selected weapon and resulting counts.
3. **Remaining weapon families**
   - Firearms, melee, unarmed, and thrown weapons use their authored held model,
     equip/unequip, attack, aim, reload, and ammunition semantics where applicable.
4. **Wearables**
   - Armor and clothing change the correct equipment/body slots and third-person
     appearance. They are not treated as held weapons.
5. **Consumables and non-equipment items**
   - Aid/food consumes the item and applies its effect. A held-use presentation
     is required only when retail data demonstrates one.
   - Ammunition, keys, notes, and miscellaneous records are not forced into the
     hand merely because they can be selected in inventory.

Every action gate requires: input event, selected record identity, inventory or
equipment delta, first-person render state, relevant authored animation state,
post-close usability, reopen continuity, native frames, and retained logs.

## Phase 2: VR acceptance order

Only after Phase 1 passes:

1. Attach the Pip-Boy to the tracked wrist while retaining the proven native
   OpenMW VR hand skeleton and fingers.
2. Use the tracked opposite-hand pointer/finger for visible physical controls.
3. Select a firearm, close the Pip-Boy, and transition cleanly back to the weapon
   hand without losing either controller hand.
4. Prove tracked aim, fire, reload, Pip-Boy reopen, and inventory continuity with
   native VR frames and telemetry.

## Immediate gate

The only active implementation target is the Phase 1 firearm slice. The first
known runtime blocker is that an interrupted visual equip leaves the queued
reload unserviced. The first visual blocker is the held right arm being replaced
by a continuously looping `pipboymanipulate.kf`, despite retained retail input
telemetry showing navigation remained on the held waver. Fix and rerun these
before widening the item matrix.
