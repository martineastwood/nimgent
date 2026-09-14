version       = "0.1.0"
author        = "martin"
description   = "Lightweight LLM client library for Nim"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run the test suite":
  exec "nim c -r --hints:off --threads:on --mm:orc tests/all_tests.nim"
  exec "nim c -r --hints:off --threads:on --mm:orc tests/google_tests.nim"
  exec "nim c -r --hints:off --threads:on --mm:orc tests/stream_cancel_tests.nim"
  exec "nim c -r --hints:off --threads:on --mm:orc tests/tracing_tests.nim"

task testMemory, "Check repeated streaming memory retention":
  exec "nim c -r -d:release --threads:on --mm:orc tests/memory_stream_test.nim"
