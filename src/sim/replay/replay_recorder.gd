class_name ReplayRecorder
extends RefCounted

## Recording a battle, and playing it back.
##
## A battle is fully described by four things: the scenario it was fought in, the seed,
## the ordered log of commands that entered the simulation from outside, and nothing
## else. AI decisions are derived inside the simulation from state that is itself
## derived from those four, so they need no recording — which is the payoff for the
## rule that the AI steers through the movement system directly and never through the
## command queue. A recorded fleet action is a few kilobytes.
##
## Snapshots are taken every so often, and they are not needed for playback: they exist
## so that rewinding to an arbitrary point means restoring the nearest one and
## re-simulating forward instead of replaying from the beginning. The checksums beside
## them are what turns a silent divergence into a named tick.

const SCHEMA_VERSION: int = 1


class Header extends RefCounted:
	var schema_version: int = SCHEMA_VERSION
	var scenario_id: String = ""
	var seed_value: int = 0
	var recorded_ticks: int = 0

	func to_document() -> Dictionary:
		return {
			"schemaVersion": schema_version,
			"scenario": scenario_id,
			"seed": seed_value,
			"ticks": recorded_ticks,
		}


var header: Header = Header.new()

## Every command that entered the simulation, in order. This IS the recording.
var commands: Array = []

## Periodic full snapshots, for rewind, and periodic checksums, for divergence
## detection. Both are keyed by tick.
var snapshots: Array = []
var checksums: Dictionary = {}

var _snapshot_interval: int = 600
var _checksum_interval: int = 60
var _recording: bool = false


static func start(world: SimWorld, scenario_id: String, config: Dictionary) -> ReplayRecorder:
	var recorder: ReplayRecorder = ReplayRecorder.new()
	recorder.header.scenario_id = scenario_id
	recorder.header.seed_value = world.get_seed()
	var replay: Dictionary = (config.get("sim", {}) as Dictionary).get("replay", {}) as Dictionary
	recorder._snapshot_interval = maxi(int(replay.get("snapshotIntervalTicks", 600)), 1)
	recorder._checksum_interval = maxi(int(replay.get("checksumIntervalTicks", 60)), 1)
	recorder._recording = true
	# The opening snapshot is the one that makes a rewind to the start free, and it is
	# also the only one a replay strictly needs — everything after it is a convenience.
	recorder.snapshots.append(Snapshot.capture(world))
	return recorder


func is_recording() -> bool:
	return _recording


func stop() -> void:
	_recording = false


## Called once per tick, after the world has been stepped.
func observe(world: SimWorld) -> void:
	if not _recording:
		return
	header.recorded_ticks = world.clock.tick
	if world.clock.tick % _checksum_interval == 0:
		checksums[world.clock.tick] = world.checksum()
	if world.clock.tick % _snapshot_interval == 0 and world.clock.tick > 0:
		snapshots.append(Snapshot.capture(world))


## Take the command log off the world's queue. Called when the recording is finished:
## the queue has been keeping it all along, because that is what `_recording` on
## CommandQueue is for.
func take_log(world: SimWorld) -> void:
	commands = world.commands.serialize_log()


func to_document(world: SimWorld) -> Dictionary:
	take_log(world)
	var checksum_rows: Array = []
	for tick: int in Serializer.sorted_int_keys(checksums):
		checksum_rows.append({"tick": tick, "value": int(checksums[tick])})
	return {
		"header": header.to_document(),
		"commands": commands,
		"checksums": checksum_rows,
		"snapshots": snapshots,
	}


static func from_document(data: Dictionary) -> ReplayRecorder:
	var recorder: ReplayRecorder = ReplayRecorder.new()
	var head: Dictionary = data.get("header", {}) as Dictionary
	recorder.header.schema_version = int(head.get("schemaVersion", 0))
	recorder.header.scenario_id = str(head.get("scenario", ""))
	recorder.header.seed_value = int(head.get("seed", 0))
	recorder.header.recorded_ticks = int(head.get("ticks", 0))
	recorder.commands = (data.get("commands", []) as Array).duplicate(true)
	recorder.snapshots = (data.get("snapshots", []) as Array).duplicate(true)
	for entry: Variant in data.get("checksums", []) as Array:
		var row: Dictionary = entry as Dictionary
		recorder.checksums[int(row.get("tick", 0))] = int(row.get("value", 0))
	return recorder


## Play the recording back into a world built from the same scenario.
##
## Returns the tick at which the replay diverged from the recording, or -1 if it did
## not. A divergence is not a failure of this function — it is the thing this function
## exists to find, and the tick it names is where to look.
func replay_into(world: SimWorld, until_tick: int = -1) -> int:
	world.commands.clear()
	world.commands.load_log(commands)
	var target: int = header.recorded_ticks if until_tick < 0 else until_tick

	while world.clock.tick < target:
		world.step()
		if not checksums.has(world.clock.tick):
			continue
		if world.checksum() != int(checksums[world.clock.tick]):
			return world.clock.tick
	return -1


## The latest snapshot at or before `tick`, for a rewind.
func snapshot_at(tick: int) -> Dictionary:
	var best: Dictionary = {}
	for entry: Variant in snapshots:
		var row: Dictionary = entry as Dictionary
		if int(row.get("tick", 0)) <= tick:
			best = row
	return best
