---
name: mirai-assets
description: Mirai binary assets (.scene, .prefab, .mat, .mesh, .tex, .anim, .sound, .sound_set,
  .ui, .font, .strings, .prompts, .records and those of plugins, such as .terrain and .foliage),
  their container, `std/serial`, the registry and the `mirai asset` tool. Use when reading,
  creating or editing an asset, adding an asset type or a serialized component, or touching
  `asset/`, `std/serial/` or `tools/mirai/asset.odin`.
---

# Mirai assets

The packages are `std/serial` (streams, LZ4, schemas, migration, paths, JSON) and `asset`
(container, typed tables, asset types, scene/prefab, registry).

## Map

- Inspecting or editing a file: [cli.md](references/cli.md); three-way merge and git driver:
  [merge](references/cli.md#merge).
- Container, tables, `Asset`/`Document`, types, versions, registry and asset JSON:
  [formats.md](references/formats.md).
- Streams, LZ4, schemas, migration, paths, text: [serial.md](references/serial.md).
- Mesh, skeleton, texture, material, fracture, animation, sound, sound set, `.ui`, font, texts,
  prompts and game data tables (`.records`): [kinds.md](references/kinds.md). A plugin's types are
  its own: `.particle` ([vfx](../mirai-plugins/references/vfx.md#format)), `.terrain`, `.foliage`.
- Scenes, prefabs, instances and overrides: [scenes.md](references/scenes.md).

## Workflow

1. **Look before touching.** Inspect with the [CLI](references/cli.md); the file's schema allows
   reading any type.
2. **Editing an existing asset.** `mirai asset set` or `unpack`/`pack`
   ([CLI](references/cli.md)). From code: `asset.Document`, or `asset.Scene` for scenes and
   prefabs.
3. **Changing a serialized struct.** Adding, removing, reordering or changing the type of a field
   requires neither a version nor a converter: the reader migrates by field name.
   - Renaming a field makes it another one: the previous value is lost and the new one takes the
     default.
   - A new field that must not be zero needs a default in the read (`asset_row(..., &defaults)`),
     like `MATERIAL_DEFAULTS`.
   - A change in what a value means raises the type's `*_VERSION`: old files fail with `Version`
     and are imported again ([version rule](references/formats.md#versions)).
4. **Adding an asset type.** Choose a fourcc and extension, declare the flat structs of its tables,
   write them with `document_put`/`document_put_row` and read them with `asset_rows`/`asset_row`.
   Minimal example: `asset/texture.odin` (description, `*_document`, `*_view`, `*_check`).
   `mirai asset` reads it unchanged.
5. **`.ui` interfaces.** When changing their records, keep `host.ui_tree_document`/`ui_tree_view`
   and `asset.ui_check` in line with the expansion and validation of `ui.tree_load`
   ([contract](references/kinds.md#interface)).
6. **Animation, skeleton and skin.** Keep the bind contract of the [mesh](references/kinds.md#mesh),
   the independent `.skeleton` and the `Keyframe` tangents. The limits of clips, tracks, keys and
   markers are checked before building the document; a mesh and its skeleton are checked together
   with `mesh_skeleton_check`.
7. **Pre-authored fracture.** Follow [`.fracture`](references/kinds.md#fracture): `Fracture_Builder`
   for separate meshes and proximity, or explicit tables. The runtime consumes the source by
   persistent identity and validates its budgets before creating bodies.

## Invariants

- **Flat data.** A table keeps images of structs without pointers, strings or slices: texts are
  `[N]u8` with tag `mirai:"text"`. What varies in length is another table.
- **The image is canonical.** `serial.value_write` zeroes the padding, the `transient` fields and
  what follows a text's NUL: equal values are equal bytes and writing the same document twice gives
  the same file. Do not write raw memory into a column.
- The JSON view may omit fields (`text_write.omit_fields`, [serial.md](references/serial.md));
  hiding authoring fields does not remove them from the persistent image.
- **The header id is an asset's identity**: nothing derives it from its path, name or source;
  `owner` says which asset it is a part of ([container](references/formats.md#container)).
- **Persistent identity.** What is stored names entities by `Entity_Id` and assets by `Asset_Id`,
  never by runtime index. The only stored position is the `entity` column of a component table. In
  scenes and prefabs a `base.Entity` field contains the `Entity_Id` of its target.
- **Dependencies are derived** from the `Asset_Id`s the values name; there is no separate list.
- **Nothing in the file is trusted without validating.** `blob_open`, `schema_read` and
  `asset_open` validate header, directory, schema and tables; each `*_view` validates ranges of its
  type. Code that indexes with file data validates first or uses checked accesses. The decoders
  (`lz4_decompress`, `schema_read`, `text_read`) allocate no more than the input backs.
- `asset.Types` is the context with the schema of the program's types: it is created once and
  passed to reads and writes.
- **Atomic writing.** `document_save` and `scene_save` write a temporary and rename;
  `mirai asset set` does not leave the file half-written if a value is invalid.
- **A scene is one file**, not one per entity.
- **A guest mount never takes an id the registry has**: what the program shipped wins over what a
  player adds ([guest mounts](references/formats.md#registry)).

## Verification

- `mirai test std/serial` and `mirai test asset`, whose cases are named for what they check;
  generated assets, with `mirai asset verify`. Focal tests by topic:
  - merge: `asset/merge_test.odin`; with git, a repository with the driver and two branches that
    edit different fields and the same field of a scene;
  - prefab instances: the `prefab_*` and
    `stale_prefab_instances_resolve_against_the_files_of_their_prefabs` (`asset/scene_test.odin`),
    `mirai test engine/scene` (on loading) and
    `a_cook_brings_the_prefab_instances_of_what_it_ships_up_to_date` (`cook/build`, on cooking);
  - textures: `texture_round_trips_every_format_and_checks_level_sizes` and
    `texture_layers_keep_each_image_of_every_level` (`kinds_test.odin`), and the blocks in
    `texture_blocks_test.odin`;
  - animation, skeleton, skin and fracture: `content_test.odin`, `kinds_test.odin`,
    `skeleton_test.odin` and `fracture_test.odin` of `asset`; font, texts and prompts:
    `asset/interface_kinds_test.odin`; game data tables: `asset/records_test.odin`;
  - registry: `asset/registry_test.odin` and, in the editor,
    `content_lines_follow_registry_revisions_when_storage_and_count_are_reused`;
  - layers of an imported material:
    `an_imported_material_follows_its_source_except_the_fields_changed_after_the_import`, and the
    overrides shared with prefabs in the editor,
    `prefab_selection_and_file_overrides_share_the_undo_history`;
  - JSON inspection with transient fields: `std/serial/text_runtime_test.odin`.
- CLI: `asset/cli_test.odin` when touching `tools/mirai/asset.odin`, `asset/doc_text.odin`,
  `asset/locate.odin` or `asset/diff.odin`; `cli_reads_and_edits_assets_of_every_kind` needs
  `MIRAI_ROOT`, which `mirai test` defines.
- Readers: files truncated at every length and mutated bytes in `asset/fuzz_test.odin`, which a new
  format or chunk extends; `cli_commands_answer_for_damaged_files` requires exit 0, 1 or 2.
  `-sanitize:address` repeats the tests with the sanitizer.
- Out of memory: `std/serial/schema_memory_test.odin`, `asset/document_oom_test.odin` (both also
  with `--release`) and `asset/types_memory_test.odin`. If schema validation changes, add
  `hostile_schema_binary` and `hostile_random_schemas_validate` with `--release` and
  `-define:SERIAL_HOSTILE_ROUNDS=20000`.
- `.pose`, `.blend` and `.agraph` are verified in their [plugin](../mirai-plugins/SKILL.md).
- Benchmarks (not routine):
  `mirai test std/serial lz4_benchmark --release -define:SERIAL_BENCH=true` and
  `mirai test asset scene_file_against_a_file_per_entity --release -define:ASSET_BENCH=true`.
