# OHIP demo

A plain `mix new` app with an Oracle Hospitality (OHIP) client generated
by Hearth from Oracle's public specs. It covers what a proposal flow
reads: blocks and events from OPERA Cloud. Then it follows the client
from release 26.2 to 26.3. Hearth reports what changed in the parts the
app uses and whether any of it breaks, then applies it. The generated
functions stay the same and the tests stay green.

Hearth comes in as a path dependency (`../..`), so the demo follows the
library in this repo. Steps 4 to 6 fetch Oracle's specs from GitHub, so
you need network for them.

```bash
mix deps.get
```

## 1. How the client was made

Oracle publishes each OHIP API as its own Swagger 2.0 spec in
[`oracle/hospitality-api-docs`](https://github.com/oracle/hospitality-api-docs).
The proposal flow needs two of them: Block (`blk.json`) and Event
Management (`evm.json`). `.hearth.exs`, written before the first gen:

```elixir
[
  registry: %{
    "ohip_blk" => %{"26.2" => "https://raw.githubusercontent.com/oracle/hospitality-api-docs/52ca181…/rest-api-specs/property/v1/blk.json", "26.3" => "…/dd631fb…/…/blk.json"},
    "ohip_evm" => %{"26.2" => "…/52ca181…/…/evm.json", "26.3" => "…/dd631fb…/…/evm.json"}
  },
  integrations: [
    ohip: [
      sources: [blk: "ohip_blk@26.2", evm: "ohip_evm@26.2"],
      overrides: [
        patches: %{
          "/components/securitySchemes/bearerAuth" => %{"type" => "http", "scheme" => "bearer"},
          "/security" => [%{"bearerAuth" => []}]
        }
      ],
      headers: ["x-app-key": :app_key, "x-hotelid": [option: :hotel_id]],
      base_url: [resolve: {OhipDemo.Tenancy, :gateway}, options: [:hotel]],
      auth: [credential: [resolve: {OhipDemo.Tenancy, :token}, options: [:hotel]]]
    ]
  ]
]
```

- **`registry:`** gives each spec a shortcut. Each release points at the
  commit of its release tag, so `ohip_blk@26.2` always means the same
  file.
- **`sources:`** merges both specs into one integration: one client, one
  auth setup, one `OhipApi`. Each spec's base path (`/blk/v1`,
  `/evm/v1`) moves into its paths.
- **`patches:`** adds a bearer scheme. The specs declare none; they only
  list `authorization` as a header parameter.
- **`headers:`** sends the two headers every operation requires.
  `x-app-key` comes from config (`OHIP_APP_KEY`). `x-hotelid` is passed
  on every call and never read from config.
- **`base_url:` and `credential:`** come from `OhipDemo.Tenancy`
  (`lib/ohip_demo/tenancy.ex`), given the `hotel:` each call passes. The
  specs have no host, since each customer has its own gateway, and the
  token belongs to a hotel. Neither one sits in config or an env var.

Then:

```bash
mix hearth.gen --integration Ohip \
  --tag "Block:get_block,get_blocks,get_block_range_info,get_block_room_rate_grid" \
  --tag "EventManagement:get_event,get_events_one_hotel,get_event_calendar" --yes
```

With no source argument, gen read `sources:` from the entry. It fetched
both specs and converted them to OpenAPI 3, then merged them and picked
7 of their 138 operations. It wrote everything in this directory that
`mix new` didn't:

| File | What it is |
| --- | --- |
| `lib/ohip_demo/integrations/ohip.ex` | the raw Req client: base URL and token from `OhipDemo.Tenancy`, the two headers |
| `lib/ohip_demo/integrations/ohip/ohip_api.ex` | the behaviour your code calls: `get_blocks/1`, `get_block/3`, `get_block_range_info/3`, `get_block_room_rate_grid/3`, `get_event_calendar/2`, `get_events_one_hotel/2`, `get_event/3` |
| `lib/ohip_demo/integrations/ohip/ohip_api/req.ex` | the Req implementation |
| `test/ohip_demo/integrations/ohip_test.exs` | the client's `Req.Test` test |
| `test/ohip_demo/integrations/ohip_external_test.exs` | live-API tests, yours to edit |
| `test/support/mocks.ex` | the Mox mock for `OhipApi` |
| `config/test.exs` | points `OhipApi` at the mock in tests |
| `config/runtime.exs` | reads `OHIP_APP_KEY` in dev and prod, and nothing else |
| `priv/hearth/ohip.yaml` | both specs merged and pruned to these 7 operations |
| `.hearth.exs` | the rest of the entry: module, checksums per source, which tags were selected, and the auth scheme |

A call passes the hotel it acts for:

```elixir
hotel = %{id: "HOTEL1", gateway: "https://…", token: "…"}

OhipDemo.Integrations.Ohip.OhipApi.get_block(block_id, hotel.id, hotel: hotel, hotel_id: hotel.id)
```

## 2. Test it

```bash
mix test
```

```
9 passed, 7 excluded
```

The 9 tests drive the raw client through `Req.Test`, with no network. They pass
the token, the hotel id and the base URL per call, so `OhipDemo.Tenancy`
never runs in them. The 7 excluded are the live-API tests
(`mix test --include external`). They need a real gateway, a token and a
hotel id.

## 3. Check it's in sync

```bash
mix hearth.diff ohip
```

```
hearth.diff: ohip: no drift against blk: ohip_blk@26.2, evm: ohip_evm@26.2.

The source is unchanged since the last gen or sync.
```

`diff` re-prunes both sources and compares them with
`priv/hearth/ohip.yaml`. It writes nothing and exits non-zero on drift,
so it belongs in CI.

## 4. Oracle ships 26.3

Point both sources at the new release in `.hearth.exs`:

```elixir
sources: [blk: "ohip_blk@26.3", evm: "ohip_evm@26.3"],
```

and ask what changed:

```bash
mix hearth.diff ohip
```

```
hearth.diff: ohip has drifted from blk: ohip_blk@26.3, evm: ohip_evm@26.3.

blk, evm changed since the last gen or sync.

Operations:
  ~ get /blk/v1/blocks (getBlocks): query parameter blocksWithRoomInventory added
  ~ get /blk/v1/hotels/{hotelId}/blocks/{blockId} (getBlock): query parameter roomAllocationCriteria: []: enum gains ChildRates
  ~ get /blk/v1/hotels/{hotelId}/blocks/{blockId}/roomRateGrid (getBlockRoomRateGrid): query parameter roomAllocationCriteria: []: enum gains ChildRates

Schemas:
  ~ allocationType: enum gains ChildRates
  ~ blk_depositPolicyType: deadline: $ref policyDeadlineType → blk_policyDeadlineType  [breaking]
  + blk_policyDeadlineType
  ~ blk_resCancelPenaltyType: deadline: $ref policyDeadlineType → blk_policyDeadlineType  [breaking]
  + blockGridChildRatesType
  ~ cancelPenaltyType: deadline: $ref policyDeadlineType → blk_policyDeadlineType  [breaking]
  - policyDeadlineType  [breaking]
  ~ roomGridDetailsType: property childRate added

11 changes (4 breaking). Apply them with:

  mix hearth.regen ohip --sync

ohip: policyDeadlineType is no longer the same in every source, so each source's
copy now carries its key — and shows as a rename in the drift. To keep
the plain name for the source whose copy is unchanged, add to the entry
in .hearth.exs:

    overrides: [shared: %{"schemas/policyDeadlineType" => :blk}]
```

Only the 7 operations the app uses, and the schemas they reach, are
compared. The rest of Oracle's specs can change freely.

The 4 breaking changes aren't an API break. Block and Event Management
both define `policyDeadlineType`, and on 26.2 the two copies were
identical, so the merge kept one. On 26.3 they differ, so the merge has
to keep both, each named after its source (`blk_policyDeadlineType`).
That shows up as a rename. The advice at the end says which source to
keep the plain name for.

## 5. Keep the shared name

Add the suggested line under `overrides:` in `.hearth.exs`:

```elixir
overrides: [
  shared: %{"schemas/policyDeadlineType" => :blk},
  patches: %{…}
],
```

and diff again:

```bash
mix hearth.diff ohip
```

```
Operations:
  ~ get /blk/v1/blocks (getBlocks): query parameter blocksWithRoomInventory added
  ~ get /blk/v1/hotels/{hotelId}/blocks/{blockId} (getBlock): query parameter roomAllocationCriteria: []: enum gains ChildRates
  ~ get /blk/v1/hotels/{hotelId}/blocks/{blockId}/roomRateGrid (getBlockRoomRateGrid): query parameter roomAllocationCriteria: []: enum gains ChildRates

Schemas:
  ~ allocationType: enum gains ChildRates
  + blockGridChildRatesType
  ~ roomGridDetailsType: property childRate added

6 changes, none breaking.
```

That's the real 26.2 → 26.3 change for a proposal flow. Child rates
reach the block's room grid, and `getBlocks` gains a filter. No
operation was added or removed.

In CI, decide what fails the build:

```bash
mix hearth.diff ohip; echo $?                      # 1: any drift fails
mix hearth.diff ohip --fail-on breaking; echo $?   # 0: additive drift is only a notice
```

## 6. Move to 26.3

```bash
mix hearth.regen ohip --sync --yes
```

`--sync` re-prunes both sources, lists the 6 changes it applied, and
regenerates the client. See what changed:

```bash
git diff --stat .
```

- `priv/hearth/ohip.yaml`: the pruned spec now has the 6 changes, as a
  diff you can review.
- `.hearth.exs`: the new sources and their checksums.
- `lib/ohip_demo/integrations/ohip/ohip_api.ex`: only its `## Source`
  footer (26.2.0.0 → 26.3.0.0).

No function changed. New fields, enum values and query parameters all
go through the functions the app already has, for example
`get_blocks(params: [blocksWithRoomInventory: true], hotel: hotel, hotel_id: hotel.id)`.

```bash
mix test   # still 9 passed
```

Nothing is left to apply:

```bash
mix hearth.diff ohip              # no drift
mix hearth.regen ohip --dry-run   # No proposed content changes!
```

## Hand-edited files

To change a generated file and keep the change, put `hearth:owned` in
its `@moduledoc`:

```elixir
@moduledoc """
Raw Req client for the Ohip integration.

hearth:owned
"""
```

`regen` and `--sync` then skip it:
`* skipping lib/ohip_demo/integrations/ohip.ex (hearth:owned)`.
`hearth:collaborating` makes them ask first, file by file.
