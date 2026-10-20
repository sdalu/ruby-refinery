# Design

Why the refinery is shaped as it is.  What each refinement does is in
the README.

## Refinements, one file per area, nothing loaded by default

Every addition is a refinement, active only in a file that says
`using`, so pulling the gem into a project changes no behaviour
anywhere it is not asked for.  Monkey patches would be simpler to call
and impossible to scope; that is the trade.

There is no `require 'refinery'` loading everything: each area is its
own file, required on its own.  The point is the optional
dependencies: `faraday`, `tty-progressbar` and `mqtt` are not declared
in the gemspec, so a project that wants `deg-rad` does not install an
HTTP client and an MQTT stack to get it, and a project that does want
the downloader already depends on Faraday.  The price is that a missing
gem is a `LoadError` at require time rather than at install, and that
the suite skips (loudly) what the host cannot load.

`refinery/time` is the old name of `refinery/datetime` and only
requires it, so that programs written against that name keep loading.

## EnumeratorThrottling: a fresh enumerator, walked afresh

Each method returns a new `Enumerator` whose body calls the receiver's
own `#each` every time it is iterated.  So the result can be iterated
twice, and its pacing state -- the rate limiter, the deadline -- is
built inside that body, per iteration: a second run never waits on the
passes of the first.  Arguments are still checked at the call, not
at the first iteration, so a bad rate fails where it was written.

Items are passed on with `*v`, as `#each` yields them, so a Hash's
pairs arrive as pairs.

The `:hard` budget interrupts the source, never the caller.  It once
ran the whole walk under one `Timeout.timeout`, which interrupts
whatever the thread is running when it fires.  With a block that was
always the enumerator's own frames, so the walk ended quietly; through
`#next`, the caller's code runs on another fiber between two calls, so
the `HardLimit` landed there, where nothing rescued it, and even fired
into unrelated code after the caller had left the enumerator, its
timeout still armed.  No exception can stop the caller's code under
`#next` without surfacing in it, so the same behaviour both ways meant
interrupting only the source: it runs in a fiber of its own, the
timeout is armed only around each `resume` (each item it produces),
and a source stopped partway is unwound with `Fiber#raise` so that its
`ensure` runs, as a `break` out of `#each` would.  The cost is a fiber
switch per item, some microseconds.

`HardLimit` is an exception class of its own: rescuing `Timeout::Error`
would also swallow a timeout raised by the caller's own code.  Both it
and the unwinding exception are raised inside the source, so neither
is a `StandardError`: a source's plain `rescue => e`, a fetcher
retrying, let a `StandardError` `HardLimit` through no more than a hung
fetch, and the limit was lost.

The fiber has a cost beyond the switch: fiber-locals and lock
ownership are per fiber.  The iterating fiber's fiber-locals are copied
into the source's, so a source reading a locale or a request id finds
it; locks cannot be, so a `Monitor` the caller holds is another fiber's
there, and taking it deadlocks.  That stays, documented: it is the
price of interrupting only the source.

The rate limiter is a sliding window over the last `limit` passes, on
the monotonic clock, so a wall-clock step cannot burst or stall it.

## Stats: nil where undefined

A mean of nothing, a sample variance of one value: these return `nil`
rather than raising or giving `NaN`, so a caller can write
`a.mean || 0` and a `NaN` cannot travel silently into later arithmetic.
A percentile outside 0..100 is a caller's error, not an undefined
statistic, and raises even on an empty array.

Percentiles interpolate linearly between closest ranks, numpy's and
Excel's `PERCENTILE.INC` default, so results compare directly with
those tools.

## StringShaper: acronyms are words

`snakize` makes a run of two or more capitals a word of its own
(`HTTPServer` → `http_server`), which is what a reader of the
snake_case name expects.  `split_acronyms: false` keeps the
older rule (a capital starts a word only after a lowercase letter or
digit) for callers whose stored names were made with it.  `camelize` is
not `snakize`'s inverse and does not try to be: the case of an acronym
is gone once snaked.

## Faraday downloader: open late, write from the stream

The destination is opened at the first chunk, not before the request,
because the name can come from the response's `Content-Disposition`.
Chunks are written from Faraday's `on_data` as they arrive, so a large
body is never held in memory.  The cost is that the adapter must
stream; one that does not leaves the file empty.

Faraday calls `on_data` once with an empty chunk when the body is
empty.  That call opens nothing; `create_empty` alone decides whether
an empty file is made.

A `Content-Disposition` filename comes from the server and is not
trusted: it is cut down to its last path component (either separator),
rid of NUL and leading dots, whitespace runs collapsed, and ignored if
nothing is left.  That sanitising, not `clean_path`, is what keeps a
download inside `dir:`.  `clean_path` normalises `.` and `..` but does
not confine (README, known shortfalls).

The progress bar is built at the first chunk, once the downloader has
published the final filename in `env[:download_filename]`, with the
name written into the format string: TTY::ProgressBar sizes the bar
from the format, so a `:filename` token filled in later would make the
line wider than the terminal and every redraw would wrap.

## MQTTResilient: one lock, and a socket dropped on failure

The gem's `connect` leaves its socket open when the handshake fails
partway, so `connected?` stays true, the next `connect` does nothing
and every write fails with `EPIPE`.  The refined `connect` drops the
socket on any failure, `::Exception` included, because the gem's own
exceptions do not derive from `StandardError`.

Publishes and reconnects share one process-wide `LOCK`.  A reconnect
replaces the socket, and neither the gem's `disconnect` nor `connect`
takes its write semaphore, so an unsynchronised reconnect can pull the
socket from under another thread's publish.  The lock is a constant
rather than a per-client `@lock ||= Mutex.new`, which would have an
initialisation race of its own.  The cost: two clients in one process
serialise against each other.

## CLI: counts in the option store

`-v` is repeatable, and its handler returns the running count, so
`OptionParser#parse!(into:)` stores the count itself.  `OptCommon.level`
turns that count into a logger level, with `-q` taking precedence over
any `-v`.

## Daemonize: an exclusive, atomic create

`pid_write` writes the pid to a file of its own (a random name, created
with `O_EXCL | O_NOFOLLOW`: a guessable one, in a world-writable `/tmp`,
had the target of a symlink planted there overwritten) and `link(2)`s it to
the pidfile, which fails if the pidfile exists: so two starts cannot
both believe they own it, and the pidfile never exists empty.  (Created
with `O_EXCL` and written after, it did, and a second start reading it
then found no pid, ruled it dead and took it over.)  On `EEXIST` it
checks the recorded pid, removes a dead one and retries, and refuses
(exit 1) beside a live one.  A pid the caller cannot signal (`EPERM`)
counts as running; so does an empty pidfile less than 5 s old, one
being written in two steps; and its own pid, in a pidfile it has not
written, is a stale one whose pid came round again.  The `at_exit`
cleanup deletes the pidfile only from the process that wrote it, and
only while it still holds that pid.

Check, delete and link run under an exclusive `flock` on `<pidfile>.lock`.
Without it two starters over a stale pidfile both found it dead, and
the slower deleted, by path, the fresh pidfile the faster had just
linked, then linked its own: both ran (8 rounds in 300 of 8 racing
starters).  The lock file is never removed: unlinking it would let a
waiter lock the old file while a newcomer locks a new one.
