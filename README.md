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

### `Refinery::FaradayDownloader`

Adds a `download` method to `Faraday::Connection` and a robust `Content-Disposition` parser to `Faraday::Utils`. Supports:

- RFC 6266 / 5987 / 2231 content-disposition parsing (including continuations and encoded filenames)
- Streaming download to file or IO
- Automatic filename extraction from `Content-Disposition`

```ruby
using Refinery::FaradayDownloader

conn = Faraday.new("https://example.com")
conn.download("/report.pdf", "report.pdf")
conn.download("/export", dir: '.', content_disposition: true)
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
| `CLI::OptCommon` | `-h`, `-v`, `-V` (help, verbose, version) |
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
```

## Requiring

Load only what you need:

```ruby
require 'refinery/deg-rad'
require 'refinery/time'
require 'refinery/hash'
require 'refinery/downloader'
require 'refinery/daemonize'
require 'refinery/cli'
```

## License

Released under the [MIT License](LICENSE).

## Author

**Stéphane D'Alu** — [sdalu@sdalu.com](mailto:sdalu@sdalu.com)

~~~
