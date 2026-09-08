import std/[asyncdispatch, posix, unittest]
import nimgent/[provider, stream]

suite "silent stream cancellation":
  test "cancellation is checked without network or keyboard activity":
    var fds: array[2, cint]
    require pipe(fds) == 0
    defer:
      discard close(fds[0])
      discard close(fds[1])
    for fd in [-1.cint, fds[0]]:
      let pending = newFuture[string]("stalled network")
      var watch = WakeWatch()
      var checks = 0
      let waiting = awaitWithWakeAsync(pending, addr watch, fd,
        proc (event: StreamEvent): bool =
          check event.kind == seWake
          inc checks
          checks < 2)
      require waitFor withTimeout(waiting, 1000)
      check not waiting.read
      check checks == 2
      check not pending.finished
      pending.complete("")

  test "completed network result is preserved":
    let pending = newFuture[string]("network")
    var watch = WakeWatch()
    let waiting = awaitWithWakeAsync(pending, addr watch, -1,
      proc (event: StreamEvent): bool = true)
    pending.complete("done")
    check waitFor waiting
    check pending.read == "done"
