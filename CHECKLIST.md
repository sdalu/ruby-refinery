# Closing a round on ruby-refinery

What has to be true before a unit of work here is done.

## Gates

- [ ] `rake test` -- the whole suite, including the README check
      (`test/test_readme.rb`)
- [ ] Did the suite skip anything? Its output opens with one
      `skipping` line for each. A refinement whose gem is absent here
      (`faraday`, `tty-progressbar`, `mqtt`) was not tested, and a round
      that touched one is not gated by this run.
- [ ] Did this round add or change a refinement? Then a test in
      `test/` feeds it what it must refuse as well as what it must do.

## Documents

- [ ] `README.md` -- does the section of every refinement this round
      touched still show what the code does, examples included?
      `test/test_readme.rb` checks the names and require paths, not
      the examples.
- [ ] `README.md` "Known shortfalls" -- did this round fix or add one?
- [ ] `DESIGN.md` -- did this round change a reason it gives?
- [ ] `CLAUDE.md` -- does every file it names still exist?

## Release

- [ ] Does the number move? It lives in one file,
      `lib/refinery/_version.rb`, which the gemspec reads. Nothing is
      tagged, so no tag has to agree with it.
- [ ] Publishing to RubyGems? The name `refinery` is taken there (Philip
      Arndt's RefineryCMS, `refinery` 1.0): a push under it is refused,
      and a Gemfile's bare `gem 'refinery'` installs RefineryCMS.
      Projects take this one by `git:` or `path:` until it is published
      under a name of its own.

Then capture: whatever this round learned goes to the artifact that owns
that kind of fact, and anything this list failed to ask becomes a line
here.
