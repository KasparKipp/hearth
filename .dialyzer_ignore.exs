[
  # NimbleOptions.ValidationError types `key` as atom(), but an unknown-keys
  # error carries the list of keys, which `message/1` matches on. Dialyzer
  # then calls that clause and the helpers only it uses unreachable.
  {"lib/hearth/config/schema.ex", :guard_fail},
  {"lib/hearth/config/schema.ex", :pattern_match},
  {"lib/hearth/config/schema.ex", :unused_fun},
  # MapSet's opaque type trips Dialyzer on recent OTP, a known false
  # positive: https://github.com/elixir-lang/elixir/issues/14837
  {"lib/mix/tasks/hearth.regen.ex", :call_without_opaque}
]
