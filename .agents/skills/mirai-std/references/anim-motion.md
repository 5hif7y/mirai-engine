# Motion matching, inertial transitions and motion adaptation

Functions of `std/anim` over caller buffers; they neither allocate nor store pointers in the
temporal state. The world integration and the authoring are in
[the motion profile](../../mirai-animation/references/animation-motion.md).

## Motion matching (`matching.odin`)

- `Match_Database` is a shared definition: one row of features per frame of each clip at `rate` rows
  per second (position and velocity of the feet, velocity of the hips, position and direction of the
  trajectory at `MATCH_HORIZON`), in the frame of the character (its place on the ground and its
  facing, +Z forward), normalized per type so that each type weighs what its weight says.
  `match_database_build` is a load transaction: it rejects with `Memory_Limit` a database larger
  than its cap (`match_database_bytes` estimates it before allocating) and leaves the database empty
  on any error.
- An in-place clip travels at the velocity with which its feet push; one with a root, at that of its
  root. `Match_Clip.speed`, when positive, replaces that speed (an in-place clip keeps its
  direction). A loop continues in its following passes and one without a loop retains its ends.
- `match_trajectory` predicts the trajectory with the acceleration and braking of the locomotion and
  the turn at its rate: the same numbers that move the body.
- `match_search` gives the lowest-cost row among the clips of the requested modes and the rate at
  which its clip plays (the trajectory is scaled per clip, so a few clips cover the velocities
  between theirs). The query is taken to the rate of each clip (the velocities of its pose, by the
  rate at which it sounds over that of the clip) and velocities and trajectory positions weigh the
  square of the rate: the cost is of what the body does, and a slow clip does not pay more than one
  at its own rate. It leaves out the last window of a clip without a loop and the rows near the one
  that is playing. The entry clips (`entry`) are searched only in their first `MATCH_ENTRY_SPAN`
  seconds and only with `Match_Request.entry`; the continuous search leaves them out.
- A database of more than `MATCH_LINEAR_ROWS` rows stores the minimum and maximum of its features
  per runs of rows, small and large; the search skips a run whose bound does not improve the best
  row found and gives the same row as the full walk. Without bounds, the walk is linear with
  `f32x4`. It does not allocate.

## Inertialization

- `Inertial_State` is plain; `[]Inertial_Bone` and `[]Inertial_Curve` store the offset and the
  residual velocity per bone or curve and are sized when preparing the rig.
- `inertial_capture` receives the previous, current and target poses (and optionally the previous
  target), their curves, `dt` and the duration.
  - `current` is the last already-blended output: capturing from it interrupts a fade without
    jumping to an earlier pose.
  - The residual velocity is the one observed in the output minus that of the target. The rotation
    one comes from the residual logarithm with aligned hemispheres: it keeps continuity when output
    and target turn on different axes or cross 180°.
  - Without a previous target, the target is still; with an almost-zero `dt` the velocities are
    zero, and with zero duration the target is taken.
- `inertial_pose_apply` adds to the target offsets that decay with a fifth-degree polynomial: it
  starts with the offset and its velocity and ends with offset, velocity and acceleration zero.
  Rotations use the logarithm of the short arc; a mask of weights regulates each bone (zero leaves
  the target exact). `inertial_curves_apply` does the same with floats and `filtered` leaves a curve
  at the target.
- Applying before advancing keeps the capture pose exactly, and the target is evaluated on each tick
  without continuing to evaluate the outgoing clip.
- Each output may coincide exactly with its target, not partially overlap. NaN, infinities,
  incompatible sizes, invalid states or overflows return `false`; the output may be left partly
  written, but the capture state is published only after validating and computing.

## Root motion directed at a target

`root_motion_warp` receives `actor` and `target` in world space, and `delta` and `remaining` (the
original movement from the start of the step to the end of the window) in the local space of the
rig; `fraction` is the part of the remaining time that this step consumes.

- It computes the expected endpoint of the original movement and distributes its error toward the
  target, over the channels and axes chosen by `Root_Warp`.
- A zero weight or fraction keeps the original delta exactly; with both at one, the active axes
  reach the target if the consumer applies the delta (physics may prevent it).
- It takes into account the scale of the actor, whose axes cannot be collapsed. It only corrects
  data: it does not write the position of the actor or query physics.

## Orientation and stride warping

- `orientation_warp_angle` gives the signed angle between two directions projected on the plane
  perpendicular to `up`, limited. `stride_warp_scale` gives the limited velocity ratio (one with an
  almost-zero source velocity). Degenerate directions, negative velocities, invalid ranges and
  non-finite values fail.
- `pose_warp` receives the mutable local pose and a separate global buffer:
  - It turns the pelvis and distributes the inverse compensation over the spine.
  - The stride scales the projection of each foot with respect to its own hip over the direction of
    travel, keeping the separation that comes from the pelvis.
  - The pole of the knee comes from the source flexion plane ([common pole](anim.md)), without
    configuring another plane.
  - It keeps the lengths and the world rotation of each foot after the pelvis turn.
  - An effective stride of one skips the IK; if the angle is also zero, or with zero weight, the
    local pose stays exact.
  - The limbs share no bones and the local and global buffers do not overlap. It is a pose
    adaptation, not a physical balance solver.

## Distance to time

- `Distance_Key` uses seconds and the distance units of the caller. `distance_track_validate`
  requires at least two keys, strictly increasing non-negative time and strictly monotonic
  distance: a plateau would make the inversion ambiguous.
- `distance_to_time` finds the segment by bisection and interpolates in `f64`; outside the range it
  gives the time of the nearest end.

## Verification

- `mirai test std/anim` with the affected cases of `inertial_test.odin`, `warp_test.odin` and
  `matching_test.odin`:
  `match_database_finds_each_frame_by_its_features_and_the_clip_a_trajectory_asks_for`,
  `match_search_skips_runs_by_their_bounds_and_enters_a_mode_by_its_entry_clips` and
  `match_trajectory_follows_a_walk_that_accelerates_brakes_and_turns_at_its_rates`.
- The hostile cases accept `ANIM_INERTIAL_HOSTILE_ROUNDS` and `ANIM_WARP_HOSTILE_ROUNDS`; when
  changing validations or state, repeat them with `--release` and 20000 rounds.
- Pose and stride warp are run with null allocators: e.g.
  `pose_warp_preserves_identity_and_rotates_the_source_knee_planes_without_ik` and
  `pose_stride_warp_scales_each_foot_from_its_hip_and_preserves_the_source_knee_side`.
