extends RefCounted
## One height field, worked out on a worker thread from what the main thread gathered (main.gd):
## the hills' noise, flat ground along water, and steps up at Factorio's cliffs. Nothing here
## touches the scene or the API; `run()` fills `image`.
##
## The field is a square grid of SIZE x SIZE texels, STEP tiles each, its first texel's corner at
## `origin` (world x east, z south). Heights are in tiles.
##
## How a height is made, at each texel's centre:
##   hills   fractal noise over the map (`hill_size` tiles across), 0 to `height` tiles; small
##           bumps (`detail`) on top
##   cliffs  the high side of every cliff raised by `cliff_height`, fading back over CLIFF_REACH
##           tiles; where cliffs' raises overlap (a ring of cliffs round a hill top) the highest
##           counts, so the ground inside a ring stands up as a plateau
##   water   everything eased down to 0 within `shore` tiles of water (or a platform's void), so
##           lakes and the sea stay at their level with the ground sloping down to them
##   edges   faded to 0 over the grid's last EDGE texels: past the grid the ground is flat

const SIZE := 384
const STEP := 4.0  # tiles a texel: the hills are smooth, so 1,536 tiles of map in 147,456 texels
const EDGE := 24  # texels faded to flat at the grid's border
const CLIFF_REACH := 28.0  # tiles over which a cliff's raise fades back on its high side
const CHUNK := 32

# In:
var origin := Vector2.ZERO
var noise_seed := 0
var height := 4.0
var hill_size := 160.0
var detail := 0.35
var shore := 24.0
var cliff_height := 2.5
## Vector2i chunk -> PackedByteArray of its 32 x 32 tile kinds (0 land, 1 water, 2 void), only for
## chunks with water or void (land needs nothing).
var wet_chunks := {}
## [[Vector2 position, Vector2 high side (unit)], ...]
var cliffs: Array = []

# Out:
var image: Image
var millis := 0


func run() -> void:
	var t0 := Time.get_ticks_msec()
	var n := SIZE * SIZE
	var h := PackedFloat32Array()
	h.resize(n)
	_hills(h)
	if cliff_height > 0.0 and not cliffs.is_empty():
		_cliffs(h)
	if shore > 0.0 and not wet_chunks.is_empty():
		_shores(h)
	_edges(h)
	image = Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RF, h.to_byte_array())
	millis = Time.get_ticks_msec() - t0


## World x, z of texel (i, j)'s centre.
func _centre(i: int, j: int) -> Vector2:
	return origin + Vector2(i + 0.5, j + 0.5) * STEP


func _hills(h: PackedFloat32Array) -> void:
	var big := FastNoiseLite.new()
	big.noise_type = FastNoiseLite.TYPE_PERLIN
	big.seed = noise_seed
	big.frequency = 1.0 / maxf(hill_size, 8.0)
	big.fractal_type = FastNoiseLite.FRACTAL_FBM
	big.fractal_octaves = 3
	big.fractal_gain = 0.45
	var small := FastNoiseLite.new()
	small.noise_type = FastNoiseLite.TYPE_PERLIN
	small.seed = noise_seed + 7919
	small.frequency = 1.0 / 22.0
	small.fractal_type = FastNoiseLite.FRACTAL_NONE
	var bumps := detail * 0.15 * height
	for j in SIZE:
		var row := j * SIZE
		for i in SIZE:
			var p := _centre(i, j)
			# Perlin fBm sits mostly within -0.6..0.6: spread to 0..1, then a little flatter
			# in the valleys so there are open plains between the hills.
			var b := clampf(big.get_noise_2d(p.x, p.y) * 0.85 + 0.5, 0.0, 1.0)
			var v := height * b * b * (3.0 - 2.0 * b)
			if bumps > 0.0:
				v += bumps * small.get_noise_2d(p.x, p.y)
			h[row + i] = v


## Each cliff raises the texels on its high side within CLIFF_REACH; the highest raise counts.
func _cliffs(h: PackedFloat32Array) -> void:
	var raise := PackedFloat32Array()
	raise.resize(SIZE * SIZE)
	var reach := CLIFF_REACH
	var r := int(ceil(reach / STEP)) + 1
	for c in cliffs:
		var at: Vector2 = c[0]
		var up: Vector2 = c[1]
		var ci := int(floor((at.x - origin.x) / STEP))
		var cj := int(floor((at.y - origin.y) / STEP))
		if ci < -r or cj < -r or ci >= SIZE + r or cj >= SIZE + r:
			continue
		for j in range(maxi(cj - r, 0), mini(cj + r + 1, SIZE)):
			for i in range(maxi(ci - r, 0), mini(ci + r + 1, SIZE)):
				var d := _centre(i, j) - at
				# How far onto the high side (along `up`), and how far from the cliff at all.
				var side := d.dot(up)
				if side < -1.0:
					continue
				var dist := d.length()
				if dist > reach:
					continue
				var k := 1.0 - smoothstep(0.0, reach, maxf(side, 0.0) + 0.35 * absf(d.dot(Vector2(up.y, -up.x))))
				var v := cliff_height * k
				var idx := j * SIZE + i
				if v > raise[idx]:
					raise[idx] = v
	for idx in raise.size():
		h[idx] += raise[idx]


## Distance to water in texels (a two-pass chamfer over the grid), then everything eased down to
## 0 within `shore` tiles of it.
func _shores(h: PackedFloat32Array) -> void:
	var far := 1.0e9
	var d := PackedFloat32Array()
	d.resize(SIZE * SIZE)
	d.fill(far)
	var any := false
	for chunk in wet_chunks:
		var kinds: PackedByteArray = wet_chunks[chunk]
		var base := Vector2(chunk.x * CHUNK, chunk.y * CHUNK)
		for ty in CHUNK:
			for tx in CHUNK:
				if kinds[ty * CHUNK + tx] == 0:
					continue
				var i := int(floor((base.x + tx + 0.5 - origin.x) / STEP))
				var j := int(floor((base.y + ty + 0.5 - origin.y) / STEP))
				if i < 0 or j < 0 or i >= SIZE or j >= SIZE:
					continue
				d[j * SIZE + i] = 0.0
				any = true
	if not any:
		return
	const A := 1.0
	const B := 1.4142
	for j in SIZE:
		for i in SIZE:
			var idx := j * SIZE + i
			var v := d[idx]
			if i > 0:
				v = minf(v, d[idx - 1] + A)
			if j > 0:
				v = minf(v, d[idx - SIZE] + A)
				if i > 0:
					v = minf(v, d[idx - SIZE - 1] + B)
				if i < SIZE - 1:
					v = minf(v, d[idx - SIZE + 1] + B)
			d[idx] = v
	for j in range(SIZE - 1, -1, -1):
		for i in range(SIZE - 1, -1, -1):
			var idx := j * SIZE + i
			var v := d[idx]
			if i < SIZE - 1:
				v = minf(v, d[idx + 1] + A)
			if j < SIZE - 1:
				v = minf(v, d[idx + SIZE] + A)
				if i < SIZE - 1:
					v = minf(v, d[idx + SIZE + 1] + B)
				if i > 0:
					v = minf(v, d[idx + SIZE - 1] + B)
			d[idx] = v
	# A water texel's centre may be on land a tile or two from the water: start the slope a texel
	# out so the bank meets the water at 0.
	for idx in d.size():
		var tiles := maxf(d[idx] - 1.0, 0.0) * STEP
		var k := smoothstep(0.0, shore, tiles)
		h[idx] *= k


func _edges(h: PackedFloat32Array) -> void:
	for j in SIZE:
		var fj := minf(j, SIZE - 1 - j)
		for i in SIZE:
			var f := minf(minf(i, SIZE - 1 - i), fj)
			if f < EDGE:
				h[j * SIZE + i] *= smoothstep(0.0, float(EDGE), f)
