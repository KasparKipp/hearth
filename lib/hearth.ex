defmodule Hearth do
  @moduledoc """
  Strike sparks from OpenAPI specs into Req HTTP clients.

  Hearth is a set of [Igniter](https://hexdocs.pm/igniter) Mix tasks that turn
  an OpenAPI 3.0 / 3.1 spec into a three-layer Req integration:

    * **Layer 1** — a raw Req client (base URL, auth, `request/2`);
    * **Layer 2** — a behaviour plus a dispatcher. Business logic calls this
      module, so tests can stub it with the generated Mox mock;
    * **Layer 3** — the Req implementation, one function per operation.

  It also generates a `Req.Test` auth test and an `:external`-tagged live-API
  test, writes a pruned copy of the spec, and patches config idempotently.

  ## Tasks

    * `mix hearth.install` — one-time project setup.
    * `mix hearth.gen` — generate an integration from a spec file
      (create-only).
    * `mix hearth.regen` — regenerate integrations from their pruned specs,
      honouring `hearth:owned` / `hearth:collaborating` ownership tokens.
    * `mix hearth.diff` — report drift between integrations and their source
      specs, marking breaking changes. Read-only; fails in CI on drift.

  Run `mix help hearth.gen` for the full option list.
  """
end
