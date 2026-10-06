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
