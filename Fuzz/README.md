# Fuzzing

libFuzzer targets for the code that reads input Mimic did not write. Each one feeds mutated bytes to
a parser, with AddressSanitizer on, and stops on a crash, a Swift runtime trap, a memory error, an
input that takes over ten seconds, or one that grows memory past 2 GB.

| Target | Reads | Seeds |
| --- | --- | --- |
| `FuzzHAR` | `HARParser.parse`, the HAR capture importer | `Corpus/har` |
| `FuzzOpenAPI` | `OpenAPIParser.parse`, OpenAPI 3.0–3.2 and Swagger 2 | `Corpus/openapi` |
| `FuzzProjectDocument` | `ControlCoding` decoding of project exports, journeys and control API commands | `Corpus/project` |

`json.dict` lists JSON tokens and the keys these formats use, which gets mutations past the first
checks far sooner than random bytes.

## Running

Linux only: Apple's toolchains ship no libFuzzer runtime. With Docker on a Mac:

```sh
docker run --rm -v "$PWD":/src/mimic -w /src/mimic -e FUZZ_SECONDS=300 swift:6.2.4 Fuzz/run.sh
```

`Fuzz/run.sh FuzzOpenAPI` runs one target. The working corpus grows under `.artifacts/fuzz/corpus`
and failing inputs land in `.artifacts/fuzz/findings/<Target>/`. Replay one with
`Fuzz/.build/release/<Target> <file>`.

The build passes `--sanitize=fuzzer` so SwiftPM links libFuzzer's entry point, and
`-Xswiftc -sanitize=fuzzer,address` because two separate `-sanitize=` flags leave the code without
coverage instrumentation: the later flag replaces the earlier one.

[`fuzz.yml`](../.github/workflows/fuzz.yml) runs every target for two minutes on pull requests that
touch the parsers, and for twenty minutes nightly.

## When a target finds something

1. Download the `fuzz-findings` artifact from the failed run, or take the file from
   `.artifacts/fuzz/findings`.
2. Reproduce it with the target binary, then shrink it with `-minimize_crash=1 -max_total_time=60`.
3. Fix the parser, and add the shrunk input as a literal in the parser's unit tests and as a file in
   the target's `Corpus/` directory, so every later run replays it.

`Corpus/openapi/regression-control-character-in-operation.json` is the first such input: OpenAPIKit
trapped on it instead of throwing, which crashed the app during import.
