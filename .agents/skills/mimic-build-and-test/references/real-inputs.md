# Testing against real inputs

Three shipped bugs came from fixtures that were tidier than reality: a replayed
`Content-Encoding: gzip` broke every real HAR import, an appended `Content-Type` was emitted twice,
and every Swagger fixture in the suite declared `produces` inside the operation while real specs
overwhelmingly declare it once at the document level — which the parser did not read, so those specs
imported as plain text and, because `.plainText` short-circuits the JSON body fallback, with no body
either. Two bugs behind one convention every fixture happened to share.

When adding a feature that consumes external input, add a case built from something a real server,
browser or spec generator produces. `Tests/SpecImportTests/RealCaptureTests.swift` and
`Tests/MockServerEngineTests/RealTrafficTests.swift` are the homes for HAR and traffic; the
OpenAPI/Swagger shape cases sit beside their parser in `Tests/SpecImportTests/OpenAPIParserTests.swift`.

The tell is a fixture whose every instance agrees on something the format does not require. If all of
them put a field in the same place, the parser has only ever been asked to read it there.
