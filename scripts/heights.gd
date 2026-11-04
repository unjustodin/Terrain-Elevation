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
##   cliffs  terraces: near the cliffs each texel blends the cliffs round it (which side of each
##           it is on, weighted by how near), so a chain of cliff pieces turning corners makes one
##           smooth edge; further out that is carried on from the nearest ground near a cliff and
##           smoothed, so a ring of cliffs stands up as a plateau and the high side of a line
##           stays high. The rock itself sits on the low ground: the step rises under it, from
##           CLIFF_STEP_FROM to CLIFF_STEP_TO tiles onto the high side, so the high ground stays
##           level right up into the rock and the rock's face is the drop.
##           Past the end of a line the raise ramps back down (Factorio's gaps in a chain).
##   water   everything eased down to 0 within `shore` tiles of water (or a platform's void), so
##           lakes and the sea stay at their level with the ground sloping down to them
##   edges   faded to 0 over the grid's last EDGE texels: past the grid the ground is flat
##
## The image has two channels: red the ground's height, green the same without the cliffs'
## terraces, which Zenith lifts the cliff models by so the rock sits on the low ground.

const SIZE := 768
const STEP := 2.0  # tiles a texel: 1,536 tiles of map; fine enough for a cliff's step to stay sharp
const EDGE := 48  # texels faded to flat at the grid's border
const CLIFF_REACH := 96.0  # tiles from a cliff its terrace reaches before fading back
const CLIFF_NEAR := 24.0  # tiles round a cliff in which the cliffs are blended
const CLIFF_END_RAMP := 16.0  # tiles past a line's end over which its raise ramps back down
const CLIFF_STEP_FROM := -1.2  # tiles onto the high side where the step starts (under the rock, behind its front)
const CLIFF_STEP_TO := -0.2  # and where it is at full height: the high ground runs flat right up to the rock
const CLIFF_BLUR := 6  # texels: how far the plateau beyond the cliffs is smoothed
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
	var r := PackedFloat32Array()  # the cliffs' terraces
	r.resize(n)
	_hills(h)
	if cliff_height > 0.0 and not cliffs.is_empty():
		_cliffs(r)
	if shore > 0.0 and not wet_chunks.is_empty():
		_shores(h, r)
	_edges(h, r)
	var rg := PackedFloat32Array()
	rg.resize(n * 2)
	for idx in n:
		rg[idx * 2] = h[idx] + r[idx]
		rg[idx * 2 + 1] = h[idx]
	image = Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGF, rg.to_byte_array())
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


## Terraces from the cliffs into `raise`. Near the cliffs (CLIFF_NEAR): every cliff splats which
## side of it each texel is on (0 low, 1 high, the step behind the rock), weighted by nearness, so
## the pieces of a chain blend into one edge. Beyond: each texel takes the blended value of the
## nearest texel near a cliff (a two-pass chamfer carrying it), box-blurred so the plateau's far
## edges are soft, faded out by CLIFF_REACH.
func _cliffs(raise: PackedFloat32Array) -> void:
	var n := SIZE * SIZE
	var wsum := PackedFloat32Array()
	wsum.resize(n)
	var ssum := PackedFloat32Array()
	ssum.resize(n)
	var near := PackedFloat32Array()  # tiles to the nearest cliff, in the near band
	near.resize(n)
	near.fill(1.0e9)
	# How much the texel lies beside a cliff's run rather than past a line's end: the most of any
	# cliff near it, so pieces in a chain cover each other's ends and only a real end ramps down.
	var cover := PackedFloat32Array()
	cover.resize(n)
	var rad := int(ceil(CLIFF_NEAR / STEP))
	for c in cliffs:
		var at: Vector2 = c[0]
		var up: Vector2 = c[1]
		var run := Vector2(-up.y, up.x)
		var ci := int(floor((at.x - origin.x) / STEP))
		var cj := int(floor((at.y - origin.y) / STEP))
		if ci < -rad or cj < -rad or ci >= SIZE + rad or cj >= SIZE + rad:
			continue
		for j2 in range(maxi(cj - rad, 0), mini(cj + rad + 1, SIZE)):
			for i2 in range(maxi(ci - rad, 0), mini(ci + rad + 1, SIZE)):
				var rel := _centre(i2, j2) - at
				var along := absf(rel.dot(run))
				var side := rel.dot(up)
				# Distance to the cliff's run (a 4-tile segment), not to its middle.
				var dd := Vector2(maxf(along - 2.0, 0.0), side).length()
				if dd > CLIFF_NEAR:
					continue
				var k := smoothstep(CLIFF_STEP_FROM, CLIFF_STEP_TO, side)
				var w := 1.0 / (1.0 + dd * dd * 0.25)
				var idx := j2 * SIZE + i2
				wsum[idx] += w
				ssum[idx] += w * k
				var cv := 1.0 - smoothstep(0.0, CLIFF_END_RAMP, along - 2.0)
				if cv > cover[idx]:
					cover[idx] = cv
				if dd < near[idx]:
					near[idx] = dd
	# The near band's blended side, carried outwards from the nearest band texel.
	var val := PackedFloat32Array()
	val.resize(n)
	var d := PackedFloat32Array()  # texels from the near band
	d.resize(n)
	d.fill(1.0e9)
	for idx in n:
		if wsum[idx] > 0.0:
			val[idx] = ssum[idx] / wsum[idx] * cover[idx]
			d[idx] = 0.0
	const A := 1.0
	const B := 1.4142
	for jj in SIZE:
		for ii in SIZE:
			var idx := jj * SIZE + ii
			if ii > 0 and d[idx - 1] + A < d[idx]:
				d[idx] = d[idx - 1] + A
				val[idx] = val[idx - 1]
			if jj > 0:
				if d[idx - SIZE] + A < d[idx]:
					d[idx] = d[idx - SIZE] + A
					val[idx] = val[idx - SIZE]
				if ii > 0 and d[idx - SIZE - 1] + B < d[idx]:
					d[idx] = d[idx - SIZE - 1] + B
					val[idx] = val[idx - SIZE - 1]
				if ii < SIZE - 1 and d[idx - SIZE + 1] + B < d[idx]:
					d[idx] = d[idx - SIZE + 1] + B
					val[idx] = val[idx - SIZE + 1]
	for jj in range(SIZE - 1, -1, -1):
		for ii in range(SIZE - 1, -1, -1):
			var idx := jj * SIZE + ii
			if ii < SIZE - 1 and d[idx + 1] + A < d[idx]:
				d[idx] = d[idx + 1] + A
				val[idx] = val[idx + 1]
			if jj < SIZE - 1:
				if d[idx + SIZE] + A < d[idx]:
					d[idx] = d[idx + SIZE] + A
					val[idx] = val[idx + SIZE]
				if ii < SIZE - 1 and d[idx + SIZE + 1] + B < d[idx]:
					d[idx] = d[idx + SIZE + 1] + B
					val[idx] = val[idx + SIZE + 1]
				if ii > 0 and d[idx + SIZE - 1] + B < d[idx]:
					d[idx] = d[idx + SIZE - 1] + B
					val[idx] = val[idx + SIZE - 1]
	var soft := _box_blur(val, CLIFF_BLUR)
	for idx in n:
		# Tiles to the nearest cliff: within the band its own, beyond it the band's edge and on.
		var tiles := near[idx] if d[idx] == 0.0 else CLIFF_NEAR + d[idx] * STEP
		if tiles > CLIFF_REACH:
			continue
		# Sharp near the cliffs, the smoothed plateau further out.
		var t := smoothstep(CLIFF_NEAR, CLIFF_NEAR * 2.0, tiles)
		var v := lerpf(val[idx], soft[idx], t)
		v *= 1.0 - smoothstep(CLIFF_REACH * 0.6, CLIFF_REACH, tiles)
		raise[idx] = cliff_height * v


## A separable box blur of `src` over `r` texels each way (running sums, clamped at the edges).
func _box_blur(src: PackedFloat32Array, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(src.size())
	var out := PackedFloat32Array()
	out.resize(src.size())
	var span := float(2 * r + 1)
	for jj in SIZE:
		var row := jj * SIZE
		var acc := 0.0
		for ii in range(-r, r + 1):
			acc += src[row + clampi(ii, 0, SIZE - 1)]
		for ii in SIZE:
			tmp[row + ii] = acc / span
			acc += src[row + mini(ii + r + 1, SIZE - 1)] - src[row + maxi(ii - r, 0)]
	for ii in SIZE:
		var acc := 0.0
		for jj in range(-r, r + 1):
			acc += tmp[clampi(jj, 0, SIZE - 1) * SIZE + ii]
		for jj in SIZE:
			out[jj * SIZE + ii] = acc / span
			acc += tmp[mini(jj + r + 1, SIZE - 1) * SIZE + ii] - tmp[maxi(jj - r, 0) * SIZE + ii]
	return out


## Distance to water in texels (a two-pass chamfer over the grid), then everything eased down to
## 0 within `shore` tiles of it.
func _shores(h: PackedFloat32Array, r: PackedFloat32Array) -> void:
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
		r[idx] *= k


func _edges(h: PackedFloat32Array, r: PackedFloat32Array) -> void:
	for j in SIZE:
		var fj := minf(j, SIZE - 1 - j)
		for i in SIZE:
			var f := minf(minf(i, SIZE - 1 - i), fj)
			if f < EDGE:
				var k := smoothstep(0.0, float(EDGE), f)
				h[j * SIZE + i] *= k
				r[j * SIZE + i] *= k
