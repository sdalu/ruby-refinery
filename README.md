# Refinery

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A curated collection of Ruby
[refinements](https://docs.ruby-lang.org/en/master/syntax/refinements_rdoc.html)
providing small, focused enhancements.

## Installation

Add to your `Gemfile`:

```ruby
gem 'refinery', github: 'sdalu/ruby-refinery'
```

## Available Refinements

Each refinement is opt-in via `using` — no global side-effects.

### `Refinery::DegRad`

Degree ↔ radian conversion on `Numeric`.

```ruby
using Refinery::DegRad

180.to_rad          # => 3.141592653589793
Math::PI.to_deg     # => 180.0
(-Math::PI).to_deg  # => 180.0  (positive: true by default)
```

### `Refinery::DateOfMonth`

The first or last day of a `Date`'s month.

```ruby
using Refinery::DateOfMonth

Date.new(2000,10,17).start_of_month # => 2000-10-01
Date.new(2000,10,17).end_of_month   # => 2000-10-31
```

### `Refinery::TimeTruncate`

Truncate `Date`, `DateTime`, and `Time` objects to a given precision.

```ruby
using Refinery::TimeTruncate

Time.now.truncate(:hour)      # => 2026-02-18 12:00:00 +0100
DateTime.now.truncate(:month) # => 2026-02-01T00:00:00+01:00
Date.today.truncate(:year)    # => 2026-01-01
```

### `Refinery::TimeStepping`

Step through `Time` ranges with a custom increment.

```ruby
using Refinery::TimeStepping

t0 = Time.new(2026, 1, 1)
t1 = Time.new(2026, 1, 3)

t0.step(t1, 86400).to_a
# => [2026-01-01 00:00:00, 2026-01-02 00:00:00, 2026-01-03 00:00:00]
```

### `Refinery::HashModify`

Conditionally transform a single key in a `Hash` (immutable and in-place variants).

```ruby
using Refinery::HashModify


h = { name: "alice", age: 30 }

h.modify(:age) { |v| v + 1 }   # => { name: "alice", age: 31 }  (new hash)
h.modify!(:age) { |v| v + 1 }  # modifies h in place
h.modify(:missing) { |v| v }   # => h  (no-op when key absent)
```

### `Refinery::HashToString`

A `Hash` as a `key=value` list.

```ruby
using Refinery::HashToString

{ a: 1, b: 2 }.to_str_kvlist            # => "a=1, b=2"
{ a: 1, b: 2 }.to_str_kvlist(': ', ' ') # => "a: 1 b: 2"
```

### `Refinery::HashDeflateKeys`

A nested structure out of a `Hash` with flat path keys: segments split
on `sep:` (default `.`), `[n]` read as `.n`, and an integer segment
making an array index.  A block, when given, maps every hash key (not
array indices, nor integer keys).  An index above `max_index:` (default
10 000) raises `ArgumentError`, an array being as long as its largest
index; so does a path that is both a leaf and a branch (`'a'` and
`'a.b'`).

```ruby
using Refinery::HashDeflateKeys

h = { 'person.0.name' => "alice", 'person[0].age' => 30 }
h.deflate_keys
# => { 'person' => [ { 'name' => "alice", 'age' => 30 } ] }

{ 'a/b' => 1 }.deflate_keys(sep: '/', &:to_sym)  # => { a: { b: 1 } }
```

### `Refinery::EnumeratorThrottling`

Pacing an iteration whose steps cost something outside, such as one API
call per item.  Each method returns an `Enumerator` (or iterates at once
with a block) that can be iterated again, its pacing starting afresh;
items come through exactly as `#each` yields them.

```ruby
using Refinery::EnumeratorThrottling

dates.wait_inserted(0.0..1.0) { fetch(it) }  # random 0-1 s pause between items
ids.rate_limited(5, per: 1) { fetch(it) }    # at most 5 items per second
jobs.time_limited(60, runtime: 5) { run(it) }    # stop before overrunning 60 s
pages.time_limited(Time.now + 60, :hard) { save(it) } # also cut a hung fetch
```

`:soft` (the default) checks before each item and never interrupts one.
`:hard` also interrupts the source while it produces an item (`pages`
above, fetching the next page), and unwinds it so that its `ensure`
runs.  It never interrupts the caller's own code: neither the block,
nor the code between two `#next` calls; the iteration stops at the next
item instead, so a block and `#next` behave alike.  To cut slow work of
your own, wrap it yourself (`Timeout.timeout(5) { save(it) }`), where
you know an interruption is safe.

### `Refinery::Stats`

Descriptive statistics on an `Array` of numbers; `nil` where a statistic
is undefined (empty array, sample of one).

```ruby
using Refinery::Stats

a = [2, 4, 4, 4, 5, 5, 7, 9]
a.mean                    # => 5.0
a.median                  # => 4.5
a.percentile(90)          # => 7.6  (linear interpolation, as numpy)
a.variance                # => 4.0  (population)
a.stddev(sample: true)    # => 2.138...  (n - 1)
[].mean                   # => nil
```

### `Refinery::StringShaper`

Between camelCase and snake_case.

```ruby
using Refinery::StringShaper

"fooBar".snakize                  # => "foo_bar"
"FooBar".snakize                  # => "foo_bar"
"HTTPServer".snakize              # => "http_server"
"IPv6Address".snakize             # => "ipv6_address"
"HTTPServer".snakize(split_acronyms: false)  # => "httpserver"
"foo_bar".camelize                # => "fooBar"
"foo_bar".camelize(upper: true)   # => "FooBar"
```

A run of two or more capitals is a word of its own; with
`split_acronyms: false` it merges with the word after it.  `camelize`
cannot restore an acronym (`"http_server".camelize` is `"httpServer"`).

### `Refinery::StringTo`

A `String` made safe for one use.

```ruby
using Refinery::StringTo

" a/b ".to_filename        # => "a_b"   (`/` and NUL replaced, stripped)
"..".to_filename           # => "__"    ('', '.' and '..' name no file)
"<b>".to_html              # => "&lt;b&gt;"
"a b/c".to_uri_component   # => "a%20b%2Fc"
```

### `Refinery::Faraday::Downloader`

Needs the `faraday` gem, which this gem does not declare.

Adds a `download` method to `Faraday::Connection` and, through
`Refinery::Faraday::Utils`, a `Content-Disposition` parser to
`Faraday::Utils`. Supports:

- RFC 6266 / 5987 / 2231 content-disposition parsing (including continuations and encoded filenames)
- Streaming download to file or IO
- Filename taken from `Content-Disposition` (with `content_disposition: true`),
  cut down to a basename with no leading dots before it is used

```ruby
using Refinery::Faraday::Downloader

conn = Faraday.new("https://example.com")
conn.download("/report.pdf", "report.pdf")
conn.download("/export", dir: '.', content_disposition: true)

# An empty (0-byte) response still creates the file by default;
# pass create_empty: false to skip creating anything in that case.
conn.download("/maybe-empty", "out.bin", create_empty: false)
```

A file is written as `<path>.part` and renamed into place only on a
2xx response: an error response, or a transfer failing partway, leaves
any existing file untouched and no `.part` behind (the error body is
not saved).  An IO destination gets the body as it comes, whatever the
status: check `response.status`.  A body ending before its
`Content-Length` raises `Faraday::ConnectionFailed` (Net::HTTP itself
lets it pass); see the shortfalls for a compressed one.  A URL naming
no file (`/`), with no `dest` and no `Content-Disposition` name, raises
`ArgumentError`.

The file is written from Faraday's streaming callback, so the adapter
must stream: the default `net_http` does, Faraday's `:test` adapter
does not (the file then comes out empty).

A progress-bar middleware is also provided (`refinery/faraday/progress-bar`,
needs the `tty-progressbar` gem). It shows the filename (the one the
downloader saves to, else from the request URL); pass `shorten:` to
elide the middle of long names (`biglongfile` → `big...file`):

```ruby
require 'refinery/faraday/progress-bar'

conn = Faraday.new("https://example.com") do |f|
  f.response :progress_bar, shorten: 10
end
conn.download("/big-export.tar.gz")
```

### `Refinery::Daemonize`

PID-file management and daemonization helpers on `Process`.

```ruby
using Refinery::Daemonize

Process.pid_write("/tmp/myapp.pid")
Process.pid_check!("/tmp/myapp.pid")
Process.pid_status("/tmp/myapp.pid")  # => :running | :dead | :exited | :not_owned
```

### `Refinery::CLI`

OptionParser refinements for building command-line tools with common option groups:

| Module | Adds |
| --- | --- |
| `CLI::OptRuby` | `-I`, `--debug`, `--warn` |
| `CLI::OptCommon` | `-h`, `-v`, `-q`, `-V` (help; verbose, repeatable: `-v` info, `-vv` debug; quiet: errors only; version, printing the program's own top-level `Version` constant) |
| `CLI::OptProcess` | `-d`, `-p`, `-l` (daemonize, pidfile, logfile) |

```ruby
using Refinery::CLI::OptRuby
using Refinery::CLI::OptCommon
using Refinery::CLI::OptProcess

opts = {}
OptionParser.new do |o|
  o.options_ruby
  o.options_common
  o.options_process
end.parse!(into: opts)

Refinery::CLI::OptCommon.level(opts)     # => "warn", "info", "debug" or "error"
Refinery::CLI::OptCommon.process(opts, logger: logger)    # sets logger.level
Refinery::CLI::OptProcess.process(opts, logger: logger, progname: 'myapp')
```

`OptProcess.process` checks and writes the pidfile (`-p` without a name
gives `/tmp/<progname>`), daemonizes on `-d`, and reopens the logger
on `-l`.

### `Refinery::MQTTResilient`

Needs the `mqtt` gem, which this gem does not declare.

`MQTT::Client` (mqtt gem) that survives a broker going away:

- `connect` drops the socket when the handshake fails partway, so a
  retry connects again (the gem leaves it open: `connected?` stays true
  and every later write fails with `EPIPE`);
- `publish` retries over a broken connection, reconnecting in between
  (`retry_count: 3`, `retry_delay: 5.0` seconds spread evenly over the
  retries, `retry_delay / retry_count` before each; `retry_count: 0`
  raises at once); a reconnect the broker
  refuses spends a retry, and once they are spent the last reconnect's
  error is raised, `Errno::ECONNREFUSED` say, rather than the
  publish's;
- publishes and reconnects are serialized by one process-wide lock.

```ruby
using Refinery::MQTTResilient

client = MQTT::Client.new(host: "broker")
client.connect
client.publish("topic", "message")
```

Note that the gem's exceptions derive from `::Exception`, not
`StandardError`: rescue `MQTT::Exception` explicitly.

## Requiring

Load only what you need:

```ruby
require 'refinery/deg-rad'                # DegRad
require 'refinery/datetime'               # DateOfMonth, TimeTruncate, TimeStepping
require 'refinery/hash'                   # HashModify, HashToString, HashDeflateKeys
require 'refinery/enumerator'             # EnumeratorThrottling
require 'refinery/stats'                  # Stats
require 'refinery/string-shaper'          # StringShaper
require 'refinery/string-to'              # StringTo
require 'refinery/faraday/downloader'     # Faraday::Downloader (faraday)
require 'refinery/faraday/progress-bar'   # the middleware (faraday, tty-progressbar)
require 'refinery/daemonize'              # Daemonize
require 'refinery/cli'                    # CLI::Opt*
require 'refinery/mqtt'                   # MQTTResilient (mqtt)
```

`refinery/time` loads `refinery/datetime`.

## Known shortfalls

- `Faraday::Utils.clean_path(path, root)` does not confine `path` to
  `root`: a `..` pops `root` itself, so `clean_path("../x", "/dl")` is
  `"x"`.  `download` stays inside `dir:` for a `Content-Disposition`
  name only because that name is sanitized first; a `dest` the caller
  passes with `..` in it is not.
- `-V` raises `NameError` unless the program defines a top-level
  `Version`.
- `download` cannot tell a gzip or deflate body cut short: Net::HTTP
  inflates it without complaint, and the bytes it hands over are not
  the ones `Content-Length` counts.  Have Net::HTTP refuse an early end
  on the connection, which covers every body:
  `Faraday.new(url) { it.adapter(:net_http) { |http| http.ignore_eof = false } }`.

## Development

```sh
rake test
```

Tests needing an optional gem run only where it is installed (`faraday`,
`tty-progressbar`, `mqtt`), saying so when skipped.  The MQTT ones need
no broker: one fakes the gem's socket calls, the other serves a fake
broker on a local port.

## License

Released under the [MIT License](LICENSE).

## Author

**Stéphane D'Alu** — [sdalu@sdalu.com](mailto:sdalu@sdalu.com)

~~~
