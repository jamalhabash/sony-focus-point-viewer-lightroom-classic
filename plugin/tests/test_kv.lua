--[[
Standalone tests for FocusPointCore (pure Lua 5.1, no Lightroom needed).

Run from the repository root:
  nix shell nixpkgs#lua5_1 -c lua plugin/tests/test_kv.lua
Optionally pass the path of a real `focuspoint` binary and an image to also
round-trip the CLI's kv output through the parser:
  nix shell nixpkgs#lua5_1 -c lua plugin/tests/test_kv.lua ./result/bin/focuspoint testdata/x.ARW
]]

local scriptDir = string.match(arg and arg[0] or '', '^(.*)[/\\]') or '.'
package.path = scriptDir .. '/../focuspoint.lrplugin/?.lua;' .. package.path

local Core = require 'FocusPointCore'

local passed, failed = 0, 0

local function show(v)
	if type(v) == 'string' then
		return string.format('%q', v)
	end
	return tostring(v)
end

local function eq(actual, expected, name)
	if actual == expected then
		passed = passed + 1
	else
		failed = failed + 1
		print('FAIL: ' .. name .. '\n  expected: ' .. show(expected) .. '\n  actual:   ' .. show(actual))
	end
end

local function ok(cond, name)
	eq(not not cond, true, name)
end

-- unescape -------------------------------------------------------------------
eq(Core.unescapeValue('plain'), 'plain', 'unescape plain')
eq(Core.unescapeValue('a\\nb'), 'a\nb', 'unescape \\n -> newline')
eq(Core.unescapeValue('a\\\\b'), 'a\\b', 'unescape \\\\ -> backslash')
eq(Core.unescapeValue('a\\\\nb'), 'a\\nb', 'escaped backslash followed by n stays literal')
eq(Core.unescapeValue('a\\\\\\nb'), 'a\\\nb', 'backslash then newline')
eq(Core.unescapeValue('C:\\\\Users\\\\x'), 'C:\\Users\\x', 'windows path')
eq(Core.unescapeValue('trail\\'), 'trail\\', 'lone trailing backslash kept')
eq(Core.unescapeValue('a\\tb'), 'a\\tb', 'unknown escape kept verbatim')
eq(Core.unescapeValue('a\\rb'), 'a\rb', 'unescape \\r -> CR (the CLI escapes CR too)')
eq(Core.unescapeValue(''), '', 'unescape empty')

-- escape/unescape round trip
for _, s in ipairs({ '', 'x', 'a\nb', 'a\\b', '\\n', '\\\n\\\\', 'é · ü\n\\' }) do
	eq(Core.unescapeValue(Core.escapeValue(s)), s, 'round trip ' .. show(s))
	ok(not string.find(Core.escapeValue(s), '\n', 1, true), 'escaped has no newline ' .. show(s))
end

-- parseKv ---------------------------------------------------------------------
local kv = Core.parseKv(table.concat({
	'status=ok',
	'make=SONY',
	'model=ILCE-7M4',
	'af_area_mode=Flexible Spot: M',
	'message=line1\\nline2',
	'overview=/tmp/a b/it\'s=here.jpg',
	'',
	'garbage line without equals',
	'=novalue',
	'  spaced  =  v ',
	'empty=',
	'crlf=yes\r',
	'dup=1',
	'dup=2',
	'last=no-newline',
}, '\n'))
eq(kv.status, 'ok', 'kv status')
eq(kv.make, 'SONY', 'kv make')
eq(kv.model, 'ILCE-7M4', 'kv model')
eq(kv.af_area_mode, 'Flexible Spot: M', 'kv value with colon/space')
eq(kv.message, 'line1\nline2', 'kv escaped newline')
eq(kv.overview, '/tmp/a b/it\'s=here.jpg', 'kv value containing = and quote')
eq(kv['garbage line without equals'], nil, 'kv ignores lines without =')
eq(kv[''], nil, 'kv ignores empty key')
eq(kv.spaced, '  v ', 'kv trims key only')
eq(kv.empty, '', 'kv empty value')
eq(kv.crlf, 'yes', 'kv strips CR')
eq(kv.dup, '2', 'kv later duplicate wins')
eq(kv.last, 'no-newline', 'kv last line without newline')
eq(next(Core.parseKv('')), nil, 'kv empty input')
eq(next(Core.parseKv(nil)), nil, 'kv nil input')

-- parseKvBlocks (batch output) -------------------------------------------------
local blocks = Core.parseKvBlocks(table.concat({
	'noise before any block=ignored',
	'file=/photos/a b/DSC1.ARW',
	'status=ok',
	'overview=/c/k1-overview.jpg',
	'cached=true',
	'---',
	'file=/photos/it\'s=2.ARW',
	'status=error',
	'message=bad\\nfile',
	'---\r',
	'',
	'file=/photos/3.ARW',
	'status=unsupported',
	'file=/photos/4.ARW', -- new block without a terminator before it
	'status=no_focus',
}, '\n'))
eq(#blocks, 4, 'blocks: count')
eq(blocks[1].file, '/photos/a b/DSC1.ARW', 'blocks: file with space')
eq(blocks[1].status, 'ok', 'blocks: status')
eq(blocks[1].cached, 'true', 'blocks: cached')
eq(blocks[1].noise, nil, 'blocks: lines before first file= ignored')
eq(blocks[2].file, '/photos/it\'s=2.ARW', 'blocks: file with = and quote')
eq(blocks[2].message, 'bad\nfile', 'blocks: escaped value')
eq(blocks[2].overview, nil, 'blocks: keys do not leak between blocks')
eq(blocks[3].status, 'unsupported', 'blocks: unterminated block')
eq(blocks[4].file, '/photos/4.ARW', 'blocks: last block without ---')
eq(blocks[4].status, 'no_focus', 'blocks: last block status')
eq(#Core.parseKvBlocks(''), 0, 'blocks: empty')
eq(#Core.parseKvBlocks(nil), 0, 'blocks: nil')
eq(#Core.parseKvBlocks('status=ok\n---\n'), 0, 'blocks: no file= line')
eq(#Core.parseKvBlocks('file=/x\r\n---\r\nfile=/y\r\n---\r\n'), 2, 'blocks: CRLF')

-- prefetch ordering --------------------------------------------------------------
local function join(t)
	local parts = {}
	for i, v in ipairs(t) do
		parts[i] = tostring(v)
	end
	return table.concat(parts, ',')
end
eq(join(Core.prefetchOrder(20, 10, 10)), '11,9,12,13,8,14,7,15,16,6', 'order: forward bias 1.5')
eq(join(Core.prefetchOrder(20, 10, 6, 1)), '11,9,12,8,13,7', 'order: weight 1 alternates +1,-1,+2,-2')
eq(join(Core.prefetchOrder(5, 1, 100)), '2,3,4,5', 'order: at start only forward')
eq(join(Core.prefetchOrder(5, 5, 100)), '4,3,2,1', 'order: at end only backward')
eq(join(Core.prefetchOrder(6, 5, 100)), '6,4,3,2,1', 'order: forward exhausted then backward')
eq(join(Core.prefetchOrder(1, 1, 100)), '', 'order: single photo')
eq(join(Core.prefetchOrder(10, nil, 100)), '', 'order: unknown target')
eq(join(Core.prefetchOrder(10, 11, 100)), '', 'order: target out of range')
eq(join(Core.prefetchOrder(0, 1, 100)), '', 'order: empty list')
local big = Core.prefetchOrder(100000, 50000, 1000)
eq(#big, 1000, 'order: capped')
do
	local seen, dup, maxDist = {}, false, 0
	for _, i in ipairs(big) do
		if seen[i] or i == 50000 then
			dup = true
		end
		seen[i] = true
		maxDist = math.max(maxDist, math.abs(i - 50000))
	end
	ok(not dup, 'order: no duplicates, target excluded')
	ok(maxDist <= 600, 'order: cap keeps the closest photos')
end
do
	-- Every index except the target exactly once.
	local o = Core.prefetchOrder(37, 12, 1000)
	local seen = {}
	for _, i in ipairs(o) do
		seen[i] = (seen[i] or 0) + 1
	end
	local okAll = #o == 36
	for i = 1, 37 do
		if i ~= 12 and seen[i] ~= 1 then
			okAll = false
		end
	end
	ok(okAll, 'order: complete permutation without the target')
end

-- pickBatch
local order = Core.prefetchOrder(30, 10, 100)
local function classifyFrom(t)
	return function(i)
		return t[i]
	end
end
local groups = {}
for i = 1, 30 do
	groups[i] = 640
end
groups[11] = nil -- already cached
groups[9] = 480 -- portrait
local picked, g = Core.pickBatch(order, classifyFrom(groups), 4, 8)
eq(g, 480, 'pickBatch: group of the first eligible (index 9)')
eq(join(picked), '9', 'pickBatch: only same-group within lookahead')
groups[9] = 640
picked, g = Core.pickBatch(order, classifyFrom(groups), 4, 8)
eq(join(picked), '9,12,13,8', 'pickBatch: skips done, keeps order')
eq(g, 640, 'pickBatch: group')
picked, g = Core.pickBatch(order, function() return nil end, 4)
eq(#picked, 0, 'pickBatch: nothing eligible')
eq(g, nil, 'pickBatch: no group')

-- sizes / small helpers -------------------------------------------------------------
eq(Core.guessOverviewSize(1.5, 640, 480), 640, 'guess size landscape')
eq(Core.guessOverviewSize(2 / 3, 640, 480), 480, 'guess size portrait')
eq(Core.guessOverviewSize(1.25, 640, 480), 640, 'guess size cropped landscape quantised')
eq(Core.guessOverviewSize(nil, 640, 480), 640, 'guess size unknown')
eq(Core.guessOverviewSize(0.8, 800, 600), 600, 'guess size portrait modal')
eq(Core.preferredOverviewSize(1.5, 640, 480), 640, 'preferred landscape')
eq(Core.preferredOverviewSize(1, 640, 480), 480, 'preferred square')
eq(Core.leafName('/a/b/DSC1.ARW'), 'DSC1.ARW', 'leafName posix')
eq(Core.leafName('C:\\a\\DSC1.ARW'), 'DSC1.ARW', 'leafName windows')
eq(Core.leafName(nil), nil, 'leafName nil')
ok(Core.isHeifPath('/x/DSC1.HIF'), 'heif .HIF')
ok(Core.isHeifPath('/x/a.heic'), 'heif .heic')
ok(not Core.isHeifPath('/x.hif/a.ARW'), 'heif only extension')
ok(not Core.isHeifPath(nil), 'heif nil')
eq(Core.ms(0.0123), 12, 'ms')
eq(Core.ms(nil), -1, 'ms nil')
eq(Core.prefetchNote(3, 10, true), 'pre-rendered 3/10\226\128\166', 'prefetch note active')
eq(Core.prefetchNote(10, 10, false), '10 nearby photos pre-rendered', 'prefetch note done')
eq(Core.prefetchNote(0, 0, false), '', 'prefetch note empty')
eq(Core.renderNote({ cached = true }), 'cached', 'render note cached')
eq(Core.renderNote({ timing = { total = 0.314 } }), 'rendered in 0.31 s', 'render note time')

-- shell quoting ----------------------------------------------------------------
eq(Core.shellQuotePosix('abc'), "'abc'", 'posix simple')
eq(Core.shellQuotePosix("it's"), "'it'\\''s'", 'posix embedded quote')
eq(Core.shellQuotePosix('a b $HOME `x` "q" \\'), "'a b $HOME `x` \"q\" \\'", 'posix specials untouched')
eq(Core.shellQuotePosix(''), "''", 'posix empty')
eq(Core.shellQuotePosix("''"), "''\\'''\\'''", 'posix only quotes')
eq(Core.shellQuoteWindows('C:\\a b\\x.ARW'), '"C:\\a b\\x.ARW"', 'windows simple')
eq(Core.shellQuoteWindows('a"b'), '"ab"', 'windows drops double quote')

eq(Core.buildCommand('/p/bin/focuspoint', { 'info', "/v/it's.ARW", '--format', 'kv' }, '/t/o.txt', '/t/e.txt', false),
	"'/p/bin/focuspoint' 'info' '/v/it'\\''s.ARW' '--format' 'kv' > '/t/o.txt' 2> '/t/e.txt'",
	'buildCommand posix')
eq(Core.buildCommand('C:\\p\\focuspoint.exe', { 'info', 'D:\\x y.ARW' }, 'C:\\t\\o.txt', nil, true),
	'""C:\\p\\focuspoint.exe" "info" "D:\\x y.ARW" > "C:\\t\\o.txt""',
	'buildCommand windows wraps whole command')

-- If a POSIX shell is available, verify quoting really round-trips.
local function shellRoundTrip(s)
	local tmp = os.tmpname()
	local cmd = 'printf %s ' .. Core.shellQuotePosix(s) .. ' > ' .. Core.shellQuotePosix(tmp)
	local rc = os.execute(cmd)
	if rc ~= 0 and rc ~= true then
		os.remove(tmp)
		return nil
	end
	local f = io.open(tmp, 'rb')
	local out = f and f:read('*a')
	if f then
		f:close()
	end
	os.remove(tmp)
	return out
end
if package.config:sub(1, 1) == '/' then
	for _, s in ipairs({ "plain", "it's", "a'b'c", "$(echo pwned)", '`x`', 'sp ace', '"dq"', '\\back', "'", "''" }) do
		eq(shellRoundTrip(s), s, 'sh round trip ' .. show(s))
	end
end

-- exit codes -------------------------------------------------------------------
eq(Core.exitCode(0), 0, 'exit 0')
eq(Core.exitCode(256), 1, 'exit 256 -> 1')
eq(Core.exitCode(32512), 127, 'exit 32512 -> 127')
eq(Core.exitCode(1), 1, 'exit 1 (windows style)')
eq(Core.exitCode(nil), nil, 'exit nil')

-- JPEG size ----------------------------------------------------------------------
local function be16(n)
	return string.char(math.floor(n / 256), n % 256)
end
local jpeg = '\255\216' -- SOI
	.. '\255\224' .. be16(16) .. 'JFIF\0' .. string.rep('\0', 9) -- APP0 (len 16)
	.. '\255\219' .. be16(4) .. '\0\0' -- DQT (dummy)
	.. '\255\192' .. be16(17) .. '\8' .. be16(1707) .. be16(2560) .. '\3' .. string.rep('\0', 9) -- SOF0
	.. '\255\218' .. be16(2)
local w, h = Core.jpegSize(jpeg)
eq(w, 2560, 'jpeg width')
eq(h, 1707, 'jpeg height')
local pw, ph = Core.jpegSize('\255\216\255\255\255\194' .. be16(17) .. '\8' .. be16(640) .. be16(427) .. string.rep('\0', 10))
eq(pw, 427, 'progressive jpeg width (with fill bytes)')
eq(ph, 640, 'progressive jpeg height')
eq(Core.jpegSize('not a jpeg'), nil, 'jpeg garbage')
eq(Core.jpegSize('\255\216\255\196' .. be16(4) .. '\0\0\255\218'), nil, 'jpeg without SOF (DHT is not SOF)')
eq(Core.jpegSize(nil), nil, 'jpeg nil')

-- geometry ---------------------------------------------------------------------
local function close(a, b)
	return a and b and math.abs(a - b) < 1e-9
end
ok(close(Core.displayedAspect({ image_width = '7008', image_height = '4672', orientation = '1' }), 1.5), 'aspect landscape')
ok(close(Core.displayedAspect({ image_width = '7008', image_height = '4672', orientation = '6' }), 4672 / 7008), 'aspect rotated 90')
ok(close(Core.displayedAspect({ image_width = '7008', image_height = '4672' }), 1.5), 'aspect default orientation')
eq(Core.displayedAspect({ image_width = '0', image_height = '4672' }), nil, 'aspect invalid')
eq(Core.displayedAspect({}), nil, 'aspect unknown')

ok(Core.aspectMatches(2560 / 1707, 1.5), 'aspect match lr preview')
ok(not Core.aspectMatches(1707 / 2560, 1.5), 'aspect mismatch rotated')
ok(not Core.aspectMatches(16 / 9, 1.5), 'aspect mismatch 16:9')
ok(not Core.aspectMatches(nil, 1.5), 'aspect nil')

eq(Core.fitLongEdge(1.5, 640, 480), 640, 'fit landscape 3:2')
eq(Core.fitLongEdge(2 / 3, 640, 480), 480, 'fit portrait 2:3')
eq(Core.fitLongEdge(16 / 9, 640, 480), 640, 'fit 16:9')
eq(Core.fitLongEdge(1, 640, 480), 480, 'fit square')
eq(Core.fitLongEdge(4, 640, 100), 400, 'fit very wide in short box')
eq(Core.fitLongEdge(nil, 640, 480), 480, 'fit unknown aspect')

-- formatting ---------------------------------------------------------------------
eq(Core.formatFocusPoint({ norm_x = '0.523', norm_y = '0.41' }), '52%, 41%', 'focus point format')
eq(Core.formatFocusPoint({ norm_x = '0.005', norm_y = '1' }), '1%, 100%', 'focus point rounding')
eq(Core.formatFocusPoint({ norm_x = '0.5' }), nil, 'focus point incomplete')
eq(Core.summaryLine({ focus_mode = 'AF-C', af_area_mode = 'Zone', af_tracking = 'Face', face_eye = 'Right eye' }, 'DSC1.ARW'),
	'AF-C \194\183 Zone \194\183 Face, Right eye \194\183 DSC1.ARW', 'summary line')
eq(Core.summaryLine(nil, 'x.jpg'), 'x.jpg', 'summary file only')
eq(Core.summaryLine({}, nil), '', 'summary empty')
eq(Core.flagLabel(1), 'Picked', 'flag pick')
eq(Core.flagLabel(-1), 'Rejected', 'flag reject')
eq(Core.flagLabel(0), 'Unflagged', 'flag none')
eq(Core.flagLabel(nil), 'Unflagged', 'flag nil')
eq(Core.truncateUtf8('abc', 5), 'abc', 'truncate short')
eq(Core.truncateUtf8('abcdef', 3), 'abc', 'truncate ascii')
eq(Core.truncateUtf8('ab\195\169', 3), 'ab', 'truncate does not split UTF-8')
ok(string.find(Core.describeExecFailure(127, nil), '127', 1, true), 'describe 127')
ok(string.find(Core.describeExecFailure(1, 'boom\nmore'), 'boom', 1, true), 'describe stderr first line')

-- Optional: real CLI output -------------------------------------------------------
if arg and arg[1] and arg[2] then
	local bin, img = arg[1], arg[2]
	local tmp = os.tmpname()
	local outDir = tmp .. '.d'
	local cmd = Core.buildCommand(bin, { 'render', img, '--out-dir', outDir, '--format', 'kv' }, tmp, nil, false)
	print('running: ' .. cmd)
	os.execute(cmd)
	local f = io.open(tmp, 'rb')
	local text = f and f:read('*a') or ''
	if f then
		f:close()
	end
	os.remove(tmp)
	local res = Core.parseKv(text)
	for k, v in pairs(res) do
		print(string.format('  %s = %s', k, show(v)))
	end
	ok(res.status ~= nil, 'real CLI produced a status')
	if res.status == 'ok' then
		ok(res.overview and io.open(res.overview, 'rb'), 'real CLI overview exists')
		ok(Core.formatFocusPoint(res) ~= nil, 'real CLI focus point formats')
		print('  focus point: ' .. tostring(Core.formatFocusPoint(res)))
		print('  summary: ' .. Core.summaryLine(res, img))
		local of = io.open(res.overview, 'rb')
		if of then
			local data = of:read('*a')
			of:close()
			local ow, oh = Core.jpegSize(data)
			print(string.format('  overview jpeg: %sx%s', tostring(ow), tostring(oh)))
			ok(ow and oh, 'real overview jpeg size parsed')
		end
	end
end

print(string.format('%d passed, %d failed', passed, failed))
if failed > 0 then
	os.exit(1)
end
