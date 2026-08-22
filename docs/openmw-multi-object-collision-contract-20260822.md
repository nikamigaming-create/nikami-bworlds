# OpenMW / OpenNV Multi-Object Collision Contract — 2026-08-22

## Objective

Represent the remaining Fallout: New Vegas collision corpus without flattening
distinct Havok bodies into one Bullet object, discarding per-body filters, or
turning phantoms into solid collision. The destination must remain usable by
ordinary OpenMW objects that still own exactly one generated collision shape.

## Evidence boundary

- Retail archive: `Fallout - Meshes.bsa`, 1,061,624,491 bytes, SHA-256
  `054E299829FF24FD4BD4EDF69F6424346B400C87379CEE39BEC02E4D082BF85A`.
- All 14,881 retail NIFs parse on official-master commit `e318e7ac36`.
- Active collision denominator: 8,324 files.
- Clean authored selection at `f1cd77f276`: 7,330 files (88.06%).
- Downstream product selection at `25d120acbe`: the same 7,330 files, with
  14,881 / 14,881 parsed and 85 selected animated files after restoring the
  older NIF API's missing `bhkListShape::post` reference-resolution hook.
- Explicit remaining boundary: 994 files.
- Retail's packed-on-disk `.text` cannot support trustworthy static function
  recovery. An observe-only initialized process identifies the common pair
  evaluator at VA `0x00C84740`, a 43-row primary table at `0x01267F20`, and a
  32-row biped/dead-biped subfield table at `0x01268078`.
- The exact first 32 primary rows and all 32 subfield rows were captured from
  live memory. Both decoded matrices are symmetric. Rows 32–42 were recovered
  from the prior live output and have zero 43x43 symmetry mismatches; their
  tail-to-tail pairs remain probable pending uninterrupted recapture.
- All 12,942 retail `bhkRigidBody` records have identical world/body-info
  filters and authored group zero. Runtime instantiation therefore cannot be
  modeled as an unchanged copy into the observed live filter word.
- An isolated Goodsprings trace captured 8,192 natural evaluator calls over
  1,361 distinct words and 1,142 nonzero runtime groups. The clean decision
  contract reproduces all 8,192 returns with zero mismatches: 3,023 same-group,
  5,169 different-group, and 1,132 same-group biped calls. This confirms
  runtime system-group assignment and the pair evaluator for the sampled
  branches; bit-14 and zero-group branches remain instruction-only evidence.

Remaining families:

| Family | Files | Why one Bullet object is insufficient |
| --- | ---: | --- |
| Packed multi-body with heterogeneous filters | 491 | Bodies have distinct Havok layer/flags/group values |
| Non-packed rejected multi-body | 273 | Separate primitive bodies cannot be flattened without body/filter ownership |
| Packed plus unsupported mixed tree | 96 | Triangle and primitive bodies require one atomic multi-object resource |
| Non-fixed packed multi-body | 35 | Motion ownership is distinct per body |
| Phantom / trigger | 29 | Non-solid overlap behavior, not collision geometry |
| Animated packed mixed/multi | 28 | More than one live node/body owner |
| Nested mixed list/MOPP | 28 | Recursive child identity and filter namespaces |
| Other packed semantic mismatch | 13 | Contact/deactivation/body flags differ |
| Shared-node box topology | 1 | One authored body has more than one scene placement |

The categories total 994 and are mutually exclusive at the file level.

Confidence: `confirmed` for the hashed retail corpus, category counts, sampled
pair policy, and population-level runtime group assignment. The exact
record-to-collidable group allocator and phantom event policy remain unknown.

## Behavioral contract

1. A NIF collision body remains a distinct runtime body when any authored
   filter, response, motion, phantom, or animation-owner field differs.
2. A collision file is accepted atomically. Failure to convert any active body
   rejects the authored resource; partial authored/generated mixtures are not
   permitted.
3. Raw Bethesda filter values are preserved losslessly in the resource layer.
   Physics-instance creation owns the explicit, evidence-backed transform from
   authored tuple to runtime filter word and assigns object/system identity.
4. Solid bodies become Bullet collision objects. Phantoms become overlap-only
   objects and never enter the solid contact path.
5. Every hit identity contains body index, shape part, and triangle index.
   Material lookup is scoped by body before primitive identity is resolved.
6. Animated bodies retain an authored node record index. Missing rendered
   nodes keep the initial transform as static collision and stop polling that
   owner; they do not delete unrelated bodies.
7. Legacy one-shape OpenMW resources behave exactly as before.
8. Final Fallout body-pair admission is evaluated pairwise. Coarse OpenMW
   group/mask bits may prune impossible engine categories but cannot replace
   the 43-layer retail table or its group/subfield rules.

## Resource model

`Resource::BulletShape` should own an ordered vector of bodies rather than
forcing all collision into `mCollisionShape`:

```text
CollisionBody
  shape                       owned Bullet shape
  materials                   body-local material table
  filter                      raw layer / flags / group
  response                    solid or phantom role plus contact metadata
  initialTransform            body-to-resource transform
  animationRecordIndex        optional live scene-node owner
```

The existing `mCollisionShape` remains the compatibility representation for a
single legacy body during migration. A resource must not populate both forms.

Body ordering is deterministic active-tree traversal order. That order is the
stable body identity used by tests, hit results, and saved diagnostic output.

## Physics instance ownership

`MWPhysics::Object` owns one Bullet collision object per `CollisionBody`.
Every object stores the parent `Object*` as its user pointer and its body index
in Bullet's user index. The current primary-object accessor remains available
for legacy callers, while ignore/caster/removal paths must enumerate all owned
collision objects.

Required call-site migration:

- add/remove every body with the physics scheduler;
- ignore every body during ray and sweep queries;
- treat every body as the same `MWWorld::Ptr` for scripts and contacts;
- publish the struck body index in ray, convex, and projectile results;
- resolve materials through `(body, shapePart, triangleIndex)`;
- update each animated body independently.

## Filter policy

The generic resource stores raw values only:

```text
BethesdaCollisionFilter
  uint8 layer
  uint8 flags
  uint16 group
```

An instance-time policy returns coarse Bullet group/mask values, collision
flags, solid/overlap role, and an immutable authored-body filter record. It
also assigns any runtime system-group/subfield state at object scope. A custom
overlap-filter callback owns the final body-pair decision.

The live evaluator proves these pairwise inputs: low-seven-bit layer, five-bit
subfield, bits 14/15, and high-16-bit system group. Its primary 43-layer table
cannot fit one ordinary 32-bit Bullet mask without aliasing. The raw-to-runtime
instantiation transform and phantom role remain gated; neither may be guessed
from enum names.

## Port-side tests

1. Two static bodies with different filters create two Bullet objects and
   retain distinct raw filters.
2. Ignoring one game object ignores every owned Bullet body.
3. Hits on bodies with identical local primitive indices resolve different
   materials through body identity.
4. One animated and one fixed body update independently.
5. A missing animated scene node freezes only that body at its initial pose.
6. A phantom produces overlap state and no solid contact.
7. An unsupported third body rejects the entire resource.
8. Legacy one-shape Morrowind objects retain one collision object and unchanged
   group/mask behavior.
9. A pure policy fixture matches every confirmed retail layer/subfield bit and
   covers zero/different/equal system-group paths plus bits 14 and 15.
10. More than 32 Fallout layers remain distinct through the pair callback.

## Acceptance gates

- synthetic tests for every ownership rule above;
- complete `components-tests` and `openmw-tests`;
- read-only production-loader sweep of both retail FNV and TTW/OpenMW archives;
- natural retail/OpenNV interaction differentials for each filter policy row;
- no Lua, MyGUI, capture, or proof-state dependency in the resource/physics
  implementation.
