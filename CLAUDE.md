# ruby-refinery

## Where things are

- `README.md` -- every refinement, how to require it, known shortfalls.
- `DESIGN.md` -- why it is shaped so.
- `CHECKLIST.md` -- what closes a round here.
- `test/` -- minitest, one file per area; `test/helper.rb` holds
  `require_optional` and `ruby_run`.

Gate: `rake test`

## Traps

- **Faraday's `:test` adapter never calls `on_data`**, and the
  downloader writes only from it, so a download through it comes out
  empty and the test passes on names alone. `test/test_faraday.rb`
  serves real HTTP from a local `TCPServer` instead.
- **`test/test_mqtt.rb` reopens `MQTT::Client`** for the whole `rake
  test` process, replacing `connect`, `publish` and `disconnect` with
  hooks. A test wanting the real gem runs in a child (`ruby_run`), as
  `test/test_mqtt_broker.rb` does.
- **Under `bundle exec`, child processes load the bundle's refinery.**
  Run from a project whose bundle holds this gem (MadHouse), RUBYOPT's
  `bundler/setup` puts that copy ahead of `-I`, so a child tests old
  code and passes or fails on it.  `ruby_run` (`test/helper.rb`)
  unshifts `lib/` in the child for this; a child started any other way
  must do the same, and keep the environment (it finds `mqtt` there).
- **Probing the filename sanitiser writes outside the temp dir.**
  `clean_path` does not confine, so with the sanitiser broken a test
  download lands in the working directory (`git status` after).
