version       = "0.1.0"
author        = "martin"
description   = "Lightweight LLM client library for Nim"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run the test suite":
  exec "nim c -r --hints:off tests/all_tests.nim"
