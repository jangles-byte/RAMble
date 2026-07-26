# Engine Room

*Design philosophy for the Engine meters style — the second desktop widget.
Where the Bars style is a chart, Engine Room is a working diagram: a glass
cutaway of the machine itself, every part doing its actual job.*

**The job:** teach the system's mechanics at a glance. A viewer who watches
it for one minute should *understand* — memory fills, overfill spills to
swap, cores pump, the GPU spins, and stress crushes everything.

Engine Room believes the best explanation is a working model. RAM is a
glass reservoir: wired memory is bedrock at the bottom, compressed memory
sits above it as dense sediment, and app memory is the liquid that visibly
rises and falls, its surface alive. Memory pressure tints the liquid and
sends bubbles up through it. When the reservoir runs high, the overflow
pipe drips into the swap sump below — and the sump's rising red level is
the one alarm color in the room.

Work is motion with a mechanical cause. The CPU is a row of pistons, one
per core — performance cores and efficiency cores each pumping at their own
core's true pace, so a single busy core reads as exactly that. The GPU is a
turbine whose spin rate is its utilization; while a model streams tokens,
cyan sparks fly off the turbine rim — computation made kinetic. The disk is
a small platter spinning faster as throughput climbs.

Stress is gravity: a heavy press spans the ceiling, and as the composite
stress score rises it descends, visibly compressing the whole room — every
element squeezes into the shrinking space, and near the top of the scale
the housing rattles. Calm is tall and quiet; a crushed engine room is
unmistakable.

Color is earned by load, exactly as in the scenes: the machinery is ash
glass at rest, each part takes the green→amber→red severity ramp only as
its own signal climbs, swap alone owns standing red, and token sparks own
cyan. No decoration, no texture cosplay — geometry and motion carry it.

**Is not:** a dashboard, skeuomorphic texture-art, or busy at idle.
Kills on sight: numbers, gradients as decoration, motion without a
mechanical cause.
**Signature move:** the stress press — the whole room visibly crushed
smaller as the machine strains, rattling near the limit.
