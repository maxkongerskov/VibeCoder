# Wave U1 `hl` — chat code-block syntax highlighting

## Files

- NEW `Sources/AgentCore/Diagnostics/CodeHighlighter.swift` — Sendable single-pass tokenizer
- EDIT `App/Views/Chat/CodeBlockView.swift` — `AttributedString` via tokens + `Theme.Palette`
- NEW `Tests/AgentCoreTests/ParityCodeHighlighterTests.swift`

Did not edit `Package.swift`, `App/project.yml`, or other sources.

## Behavior

- `tokens(for:language:)` returns non-`plain` `String.Index` ranges in source order
- Unknown / nil / empty language → `[]` (body stays `Theme.Palette.primary`)
- Languages: swift, python(py), javascript(js,jsx), typescript(ts,tsx), json, yaml(yml), bash(sh,zsh,shell), go, rust(rs), c(h), cpp(cc,cxx,hh,hpp), sql, html/xml
- Colors: keyword `violet`, string `diffAdd`, comments `tertiary`, number `warning`, typeable `info`
- Header LANG + Copy + horizontal scroll unchanged

## Tests

`swift build` — success (~3.6s)

`swift test --filter ParityCodeHighlighterTests` — **12 tests, 0 failures** (0.006s)

| Case | Result |
|---|---|
| unknown / nil / empty / mermaid / objective-c → `[]` | pass |
| swift `func`/`let` + number `1` + declared names | pass |
| python `def` + `"world"` (`py` alias) | pass |
| js backtick `` `hello ${name}` `` | pass |
| json keys `typeable` vs value `string` | pass |
| sql `-- only active` line comment | pass |
| escaped `\"` / `\\` do not break pairing | pass |
| 10k-char single line, no crash, &lt;200ms | pass (0.004s) |
| aliases RS/Go/h + html comment/tag | pass |

## App build

Serialized command attempted. `flock` is **not** on this macOS (`command not found: flock`); `xcodebuild` still ran.

**BUILD FAILED** — not `hl`:

```
App/Views/Chat/ShellApprovalSheet.swift:225
error: type 'ButtonStyle' has no member 'borderedProminent' / 'bordered'
```

That file is owned by U1 `permsheet` (concurrent). After that compile, `permsheet` already rewrote the ternary `.buttonStyle` into an if/else.

`hl` units in the same log:

- `CodeHighlighter.swift` — SwiftDriverJobDiscovery success (AgentCore)
- `CodeBlockView.swift` — `CodeBlockView.o` written (268 872 bytes, 04:16)

Parent can relink after the wave. No `hl` compile errors.

## Open items

- Objective-C skipped (per spec)
- No wrap toggle (ZCode has one; not in exclusive-file scope)
- Python `"""` / `'''` tokenized as `commentBlock` (docstrings); regular `"…"` / `'…'` stay `string`
- JSON keys are `typeable` (quoted), values `string`
- macOS has no `flock(1)`; use `python fcntl` if later waves need a real exclusive lock
