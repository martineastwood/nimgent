version       = "0.1.0"
author        = "martin"
description   = "Lightweight LLM client library for Nim"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "nimwire >= 0.1.0"

task test, "Run the test suite":
  exec "nim c -r --hints:off --threads:on --mm:atomicArc tests/all_tests.nim"
  exec "nim c -r --hints:off --threads:on --mm:atomicArc tests/google_tests.nim"
  exec "nim c -r --hints:off --threads:on --mm:atomicArc tests/stream_cancel_tests.nim"
