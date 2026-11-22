# Standalone settings share codec

`ProfileShare.lua` here is the same code as the body of `addons/Baggler/ProfileShare.lua` (between the loader
envelope lines); `tests/test_packaging.py` checks that they match. It is a Lua 5.1 chunk returning a module and needs only
the Lua standard library: no globals, frames, events or SavedVariables.

```lua
local codec = ProfileShare.new({padDefaults = controllerDefaults})
local text, reason = codec:Export(profile)
local candidate, reason = codec:Import(text, currentProfile)
```

## Share text

`BAGGLER2:` followed by one JSON object (RFC 8259 subset: objects, arrays, strings, finite numbers, `true`,
`false`; no `null`). Export is canonical: keys sorted bytewise, no whitespace, numbers in the shortest of
`%.15g`/`%.16g`/`%.17g` that reads back to the same double, and `|` written as `\u007c` so the text is safe in an
edit box. Item-keyed maps (`favorites`, `junk`, `pinTop`, `pins`) are objects with decimal keys and come back with
number keys; `custom.<name>.patterns` is the only list.

Import trims surrounding whitespace, checks the prefix exactly, and parses strictly: trailing text, duplicate keys,
unterminated structures, malformed or non-finite numbers (`NaN`, `inf`, `1e9999`, `+1`, `1.`, `.1`, `0x10`, `01`),
nesting deeper than 8, more than 25 000 values (keys and values both count) or more than 200 000 untrimmed bytes
are refused. A `BAGGLER1:` text gets "This share code is from an older Baggler version; please export it again."
Nothing is ever executed.

Schema behaviour: known settings are validated and a single invalid one rejects the whole share;
unknown top-level keys are ignored; pad fields and button entries merge over the current pad (and injected
defaults); collections replace; the current profile and defaults are never mutated.

## Tests

```sh
luajit test.lua
luajit spec_tests.lua
```

Both also run as part of `tools/baggler test`. The shipping-TOC checks for import/export are in
`../../release_safety_test.lua`.
