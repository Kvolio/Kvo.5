class_name SimClock
extends RefCounted

## Fixed-timestep clock with a selectable time scale.
##
## The simulation always advances in ticks of exactly `dt`. Time scaling changes how
## many ticks are run per rendered frame, never the size of a tick — which is what
## makes a battle fought at 10x produce byte-identical results to the same battle at
## 1x, and what makes a replay reproducible on a machine with a different frame rate.

const DEFAULT_RATE_HZ: float = 60.0
const DEFAULT_MAX_STEPS: int = 40

var tick: int = 0
var dt: float = 1.0 / DEFAULT_RATE_HZ
var time_scale: float = 1.0
var max_steps_per_frame: int = DEFAULT_MAX_STEPS

var _accumulator: float = 0.0


func configure(config: Dictionary) -> void:
	var tick_config: Dictionary = config.get("tick", {}) as Dictionary
	var rate: float = float(tick_config.get("rateHz", DEFAULT_RATE_HZ))
	dt = 1.0 / maxf(rate, 1.0)
	max_steps_per_frame = int(tick_config.get("maxStepsPerFrame", DEFAULT_MAX_STEPS))

	var scales: Dictionary = config.get("timeScales", {}) as Dictionary
	time_scale = float(scales.get("default", 1.0))


func is_paused() -> bool:
	return time_scale <= 0.0


## Elapsed simulated time in seconds.
func elapsed() -> float:
	return float(tick) * dt


## How many fixed ticks should run for this frame.
##
## The step count is clamped: when the requested speed is more than the machine can
## deliver, the simulation runs in slow motion rather than spending ever-longer
## frames trying to catch up, which is the classic spiral-of-death. Leftover time is
## discarded rather than banked, because banking it guarantees the next frame is
## worse.
func advance(real_delta: float) -> int:
	if is_paused():
		_accumulator = 0.0
		return 0
	_accumulator += real_delta * time_scale
	var steps: int = int(_accumulator / dt)
	if steps <= 0:
		return 0
	if steps > max_steps_per_frame:
		steps = max_steps_per_frame
		_accumulator = 0.0
	else:
		_accumulator -= float(steps) * dt
	return steps


## Advance one tick. Called by SimWorld, never by a renderer.
func consume_tick() -> void:
	tick += 1


func reset() -> void:
	tick = 0
	_accumulator = 0.0


func serialize() -> Dictionary:
	return {"tick": tick, "dt": dt, "timeScale": time_scale}


func deserialize(data: Dictionary) -> void:
	tick = int(data.get("tick", 0))
	dt = float(data.get("dt", dt))
	time_scale = float(data.get("timeScale", time_scale))
	_accumulator = 0.0
