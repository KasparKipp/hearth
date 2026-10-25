defmodule Hearth.Integration.Names do
  @moduledoc false

  # Picks the integrations a task acts on from its arguments: `--all` →
  # every `.hearth.exs` entry; otherwise the comma-separated names, each
  # a single alias segment with an entry. Shared by `mix hearth.regen`
  # and `mix hearth.diff`. Pure: returns `{key, entry}` pairs or the
  # message to halt with.

  alias Hearth.Config
  alias Hearth.Integration.Manifest
  alias Hearth.Integration.Messages
  alias Hearth.Render.ModuleNames

  @spec select(Config.integrations(), String.t() | nil, boolean() | nil, atom()) ::
          {:ok, Config.integrations()} | {:error, String.t()}
  def select(integrations, names, all?, task) do
    case {names, all?} do
      {nil, true} -> all(integrations, task)
      {nil, _} -> {:error, Messages.missing_integration_message(task)}
      {_names, true} -> {:error, Messages.names_and_all_message(task)}
      {names, _} -> named(integrations, names, task)
    end
  end

  # The integration's pruned spec: `:send_grid` → `priv/hearth/send_grid.yaml`.
  @spec spec_path(atom()) :: String.t()
  def spec_path(key),
    do: key |> Atom.to_string() |> Macro.camelize() |> Manifest.pruned_spec_path()

  defp all([], task), do: {:error, Messages.no_integrations_message(task)}
  defp all(integrations, _task), do: {:ok, integrations}

  defp named(integrations, arg, task) do
    names =
      arg
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      names == [] ->
        {:error, Messages.missing_integration_message(task)}

      (bad = Enum.reject(names, &ModuleNames.valid_segment?/1)) != [] ->
        {:error, Messages.bad_names_message(task, bad)}

      true ->
        keys = names |> Enum.map(&Config.key/1) |> Enum.uniq()

        case Enum.reject(keys, &Keyword.has_key?(integrations, &1)) do
          [] -> {:ok, Enum.map(keys, &{&1, Keyword.fetch!(integrations, &1)})}
          missing -> {:error, Messages.missing_entry_message(task, missing)}
        end
    end
  end
end
