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
- Explicit remaining boundary: 994 files.

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

Confidence: `confirmed` for the hashed retail corpus and category counts.
Retail interaction masks and phantom event policy remain `unknown` until they
are mapped against a retail oracle.

## Behavioral contract

1. A NIF collision body remains a distinct runtime body when any authored
   filter, response, motion, phantom, or animation-owner field differs.
2. A collision file is accepted atomically. Failure to convert any active body
   rejects the authored resource; partial authored/generated mixtures are not
   permitted.
3. Raw Bethesda filter values are preserved losslessly in the resource layer.
   Mapping them to OpenMW collision groups/masks happens at physics-instance
   creation through an explicit game policy.
4. Solid bodies become Bullet collision objects. Phantoms become overlap-only
   objects and never enter the solid contact path.
5. Every hit identity contains body index, shape part, and triangle index.
   Material lookup is scoped by body before primitive identity is resolved.
6. Animated bodies retain an authored node record index. Missing rendered
   nodes keep the initial transform as static collision and stop polling that
   owner; they do not delete unrelated bodies.
7. Legacy one-shape OpenMW resources behave exactly as before.

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

An instance-time policy returns Bullet group, mask, collision flags, and
solid/overlap role for a raw filter plus the owning game record category. The
policy must be immutable for a loaded session and independently testable.

No numeric Fallout layer mapping is accepted from convention or enum names
alone. Each mapping needs one retail interaction experiment covering actor,
projectile, camera, and world contact as applicable.

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

## Acceptance gates

- synthetic tests for every ownership rule above;
- complete `components-tests` and `openmw-tests`;
- read-only production-loader sweep of both retail FNV and TTW/OpenMW archives;
- natural retail/OpenNV interaction differentials for each filter policy row;
- no Lua, MyGUI, capture, or proof-state dependency in the resource/physics
  implementation.
