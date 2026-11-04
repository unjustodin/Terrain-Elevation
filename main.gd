extends Node
## Terrain Elevation: hills under Factorio's flat world, for Zenith (Factorio in 3D). Drawn
## only: Factorio stays flat and nothing this add-on does changes the game. Zenith lifts what it
## draws by the height under it (add-on API 1.2, api.terrain): the ground, every building, belts
## and the items on them, ghosts, wires, icons and effects, and the mouse and camera follow.
##
## This script gathers what the heights depend on from the client's world, a few chunks a frame
## (each chunk's water and its cliffs, kept once read), and when that or the settings change it
## has scripts/heights.gd work out a new field on a worker thread and hands it to Zenith.

const Heights := preload("scripts/heights.gd")

## Chunks read from the world a frame (each is a 32 x 32 loop on the main thread).
const CHUNKS_PER_FRAME := 6
## Seconds between looking for chunks that arrived or went.
const SCAN_EVERY := 0.5
## A new field once the focus is this far (tiles) from the middle of the one shown.
const RECENTRE := 256.0
## Seconds a change waits before a new field is worked out (so a burst of chunks makes one).
const SETTLE := 0.8
## Chunks kept read (water and cliffs) at most; the farthest from the focus go first.
const KEEP_CHUNKS := 6000

var api

var _on := true
var _values := {}
var _planet := ""
var _seed := 0

var _read := {}  # Vector2i -> true: chunks whose water and cliffs were read
var _wet := {}  # Vector2i -> PackedByteArray: chunks with water or void
var _cliffs := {}  # Vector2i -> [[Vector2 position, Vector2 high side], ...]
var _queue: Array = []  # chunks to read
var _queued := {}  # the same, to look up
var _scan := 0.0

var _dirty := true
var _quiet := 0.0  # seconds since the last change
var _centre := Vector2.INF  # the middle of the field shown
var _job: Heights
var _task := -1


func addon_start(a) -> void:
	api = a
	if api.get("terrain") == null or api.get("settings") == null:
		api.note("needs Zenith's add-on API 1.2 (api.terrain): update Zenith")
		set_process(false)
		return
	var s = api.settings
	_values["enabled"] = s.add("enabled", "bool", true, "Hills", {"section": "Terrain",
		"note": "Draws hills under the factory. Factorio itself stays flat."})
	_values["height"] = s.add("height", "number", 4.0, "Hill height", {"min": 0.0, "max": 16.0, "step": 0.5, "unit": "tiles",
		"section": "Terrain", "note": "The highest the hills rise. Keep it low for belts and rails to look right on slopes."})
	_values["hill_size"] = s.add("hill_size", "number", 160.0, "Hill size", {"min": 48.0, "max": 480.0, "step": 8.0, "unit": "tiles",
		"section": "Terrain", "note": "How wide a hill is. Wider hills are gentler slopes."})
	_values["detail"] = s.add("detail", "number", 0.35, "Small bumps", {"min": 0.0, "max": 1.0, "step": 0.05,
		"section": "Terrain", "note": "Little rises and dips on top of the hills."})
	_values["shore"] = s.add("shore", "number", 24.0, "Flat ground by water", {"min": 0.0, "max": 96.0, "step": 4.0, "unit": "tiles",
		"section": "Terrain", "note": "How far from lakes and the sea the ground slopes down to the water's level."})
	_values["cliff_height"] = s.add("cliff_height", "number", 2.5, "Cliff height", {"min": 0.0, "max": 8.0, "step": 0.5, "unit": "tiles",
		"section": "Cliffs", "note": "How much higher the ground is on a cliff's high side. 0: cliffs on the hills as they are."})
	s.changed.connect(_on_setting)
	api.game_started.connect(_reset)
	api.game_ended.connect(_reset)


func addon_stop() -> void:
	_wait_job()
	if api != null and api.get("terrain") != null:
		api.terrain.clear()


func _on_setting(id: String, value) -> void:
	_values[id] = value
	if id == "enabled":
		if not bool(value):
			api.terrain.clear()
			_centre = Vector2.INF
	_changed()


func _reset() -> void:
	_wait_job()
	_read.clear()
	_wet.clear()
	_cliffs.clear()
	_queue.clear()
	_queued.clear()
	_centre = Vector2.INF
	_planet = ""
	_changed()


func _changed() -> void:
	_dirty = true
	_quiet = 0.0


func _process(delta: float) -> void:
	_finish_job()
	if not api.in_game() or not bool(_values.get("enabled", true)) or api.world.on_platform():
		if api.terrain.is_on():
			api.terrain.clear()
			_centre = Vector2.INF
		return
	var planet := str(api.world.planet())
	if planet != _planet:
		# Another planet: its own ground, its own hills.
		_wait_job()
		_read.clear()
		_wet.clear()
		_cliffs.clear()
		_queue.clear()
		_queued.clear()
		_planet = planet
		_seed = hash(str(api.storage.save_key()) + "/" + planet) & 0x7fffffff
		_centre = Vector2.INF
		_changed()
	_scan -= delta
	if _scan <= 0.0:
		_scan = SCAN_EVERY
		_look_for_chunks()
	_read_some()
	_quiet += delta
	var focus: Vector2 = api.world.focus()
	if _centre == Vector2.INF or focus.distance_to(_centre) > RECENTRE:
		if _centre == Vector2.INF:
			_quiet = SETTLE  # the first field at once
		_dirty = true
	if _dirty and _job == null and _quiet >= SETTLE:
		_start_job(focus)


## New chunks into the queue (nearest the focus first); chunks far beyond what is kept dropped.
func _look_for_chunks() -> void:
	var focus: Vector2 = api.world.focus()
	var fresh: Array = []
	for c in api.world.chunks():
		if not _read.has(c) and not _queued.has(c):
			fresh.append(c)
			_queued[c] = true
	if not fresh.is_empty():
		fresh.sort_custom(func(a, b): return _chunk_distance(a, focus) < _chunk_distance(b, focus))
		_queue.append_array(fresh)
	if _read.size() > KEEP_CHUNKS:
		var keys: Array = _read.keys()
		keys.sort_custom(func(a, b): return _chunk_distance(a, focus) > _chunk_distance(b, focus))
		for i in _read.size() - KEEP_CHUNKS:
			var c: Vector2i = keys[i]
			_read.erase(c)
			_wet.erase(c)
			_cliffs.erase(c)


static func _chunk_distance(c: Vector2i, focus: Vector2) -> float:
	return (Vector2(c) * 32.0 + Vector2(16.0, 16.0)).distance_squared_to(focus)


## A few queued chunks read: their water (kept only if they have any) and their cliffs. A chunk
## with neither changes nothing (unread chunks count as dry land with no cliffs).
func _read_some() -> void:
	var n := 0
	while n < CHUNKS_PER_FRAME and not _queue.is_empty():
		var c: Vector2i = _queue.pop_front()
		_queued.erase(c)
		n += 1
		var kinds: PackedByteArray = api.terrain.chunk_kinds(c)
		if kinds.is_empty():
			continue  # not loaded (yet): looked for again by the next scan
		_read[c] = true
		if kinds.has(1) or kinds.has(2):
			_wet[c] = kinds
			_changed()
		var found: Array = []
		for cl in api.terrain.cliffs_in_chunk(c):
			var up := _high_side(str(cl["orientation"]))
			if up != Vector2.ZERO:
				found.append([cl["position"], up])
		if not found.is_empty():
			_cliffs[c] = found
			_changed()


## Which way the high ground is from a cliff, from Factorio's orientation: the cliff runs from
## the middle of one edge of its cell to the middle of another (or its middle, for "none"), the
## high ground on its left.
static func _high_side(orientation: String) -> Vector2:
	var parts := orientation.split("-to-")
	if parts.size() != 2:
		return Vector2.ZERO
	var run := _edge(parts[1]) - _edge(parts[0])
	if run == Vector2.ZERO:
		return Vector2.ZERO
	run = run.normalized()
	# x east, z (here y) south: the left of a heading (x, z) is (z, -x).
	return Vector2(run.y, -run.x)


static func _edge(name: String) -> Vector2:
	match name:
		"west": return Vector2(-2.0, 0.0)
		"east": return Vector2(2.0, 0.0)
		"north": return Vector2(0.0, -2.0)
		"south": return Vector2(0.0, 2.0)
	return Vector2.ZERO


func _start_job(focus: Vector2) -> void:
	var span := Heights.SIZE * Heights.STEP
	var j := Heights.new()
	# The grid's corner on a 64-tile step, so the hills under a spot stay put as the grid moves.
	j.origin = ((focus - Vector2(span, span) * 0.5) / 64.0).floor() * 64.0
	j.noise_seed = _seed
	j.height = float(_values.get("height", 4.0))
	j.hill_size = float(_values.get("hill_size", 160.0))
	j.detail = float(_values.get("detail", 0.35))
	j.shore = float(_values.get("shore", 24.0))
	j.cliff_height = float(_values.get("cliff_height", 2.5))
	var area := Rect2(j.origin - Vector2(64.0, 64.0), Vector2(span + 128.0, span + 128.0))
	for c in _wet:
		if area.has_point(Vector2(c) * 32.0):
			j.wet_chunks[c] = _wet[c]
	for c in _cliffs:
		if area.has_point(Vector2(c) * 32.0):
			j.cliffs.append_array(_cliffs[c])
	_job = j
	_centre = j.origin + Vector2(span, span) * 0.5
	_dirty = false
	_task = WorkerThreadPool.add_task(j.run, false, "Terrain Elevation heights")


func _finish_job() -> void:
	if _job == null or not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	var j := _job
	_job = null
	_task = -1
	if j.image != null and api.in_game() and bool(_values.get("enabled", true)) and not api.world.on_platform():
		api.terrain.set_heights(j.image, j.origin, Heights.STEP)


func _wait_job() -> void:
	if _job != null:
		WorkerThreadPool.wait_for_task_completion(_task)
		_job = null
		_task = -1
