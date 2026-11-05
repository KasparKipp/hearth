if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Gen.TestHelper do
    @moduledoc false

    alias Sourceror.Zipper

    # `:external`-tagged tests hit the real network, so `mix hearth.gen`
    # makes them opt-in by excluding the tag in `test/test_helper.exs`.
    #
    # `ExUnit.configure/1` *replaces* `:exclude`, so a second call would
    # drop the project's own excludes. Instead `:external` joins every
    # literal `exclude:` list the helper already passes to
    # `ExUnit.start/1` or `ExUnit.configure/1` (all of them, so it holds
    # whichever runs last); a helper that sets none gets
    # `ExUnit.configure(exclude: [:external])`. An `exclude:` Hearth
    # can't edit — a variable, a function call — leaves the file alone
    # with a warning. Idempotent: a list that already holds `:external`
    # (or `external: …`) is left as it is.
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    @path "test/test_helper.exs"
    @configure "ExUnit.configure(exclude: [:external])"

    @spec exclude_external(Igniter.t()) :: Igniter.t()
    def exclude_external(igniter) do
      Igniter.create_or_update_elixir_file(
        igniter,
        @path,
        "ExUnit.start()\n#{@configure}\n",
        &patch/1
      )
    end

    defp patch(zipper) do
      excludes = zipper |> Zipper.node() |> exclude_values()

      cond do
        excludes == [] ->
          {:ok, Igniter.Code.Common.add_code(zipper, @configure)}

        not Enum.all?(excludes, &literal_list?/1) ->
          {:warning, unreadable_warning()}

        Enum.all?(excludes, &external?/1) ->
          {:ok, zipper}

        true ->
          {:ok, Zipper.traverse(zipper, &add_external/1)}
      end
    end

    defp unreadable_warning do
      """
      #{@path} sets `exclude:` from code Hearth can't edit, so it was left alone.
      Add :external to it to keep the generated live-API tests opt-in, e.g.:

          ExUnit.start(exclude: [:external | excludes])
      """
    end

    # Every `exclude:` value passed to `ExUnit.start/1` or
    # `ExUnit.configure/1`, anywhere in the file.
    defp exclude_values(ast) do
      {_ast, values} =
        Macro.prewalk(ast, [], fn node, acc ->
          case exclude_value(node) do
            {:ok, value} -> {node, [value | acc]}
            :error -> {node, acc}
          end
        end)

      values
    end

    defp exclude_value(node) do
      with {:ok, opts} <- exunit_opts(node),
           {_key, value} <- Enum.find(opts, &exclude_pair?/1) do
        {:ok, value}
      else
        _ -> :error
      end
    end

    defp exunit_opts({{:., _, [{:__aliases__, _, [:ExUnit]}, fun]}, _, [opts]})
         when fun in [:start, :configure] do
      case unwrap(opts) do
        list when is_list(list) -> {:ok, list}
        _ -> :error
      end
    end

    defp exunit_opts(_node), do: :error

    defp exclude_pair?({key, _value}), do: unwrap(key) == :exclude
    defp exclude_pair?(_), do: false

    defp literal_list?(value), do: is_list(unwrap(value))

    defp external?(value), do: Enum.any?(unwrap(value), &external_item?/1)

    defp external_item?({key, _value}), do: unwrap(key) == :external
    defp external_item?(item), do: unwrap(item) == :external

    # Sourceror wraps literals in a `:__block__` carrying their metadata.
    defp unwrap({:__block__, _meta, [value]}), do: value
    defp unwrap(value), do: value

    defp add_external(zipper) do
      case exunit_opts(Zipper.node(zipper)) do
        {:ok, _opts} -> Zipper.update(zipper, &add_to_call/1)
        :error -> zipper
      end
    end

    defp add_to_call({call, meta, [opts]}) do
      opts =
        case opts do
          {:__block__, block_meta, [list]} -> {:__block__, block_meta, [add_to_opts(list)]}
          list -> add_to_opts(list)
        end

      {call, meta, [opts]}
    end

    defp add_to_opts(opts) do
      Enum.map(opts, fn pair ->
        if exclude_pair?(pair), do: add_to_exclude(pair), else: pair
      end)
    end

    defp add_to_exclude({key, value} = pair) do
      if external?(value), do: pair, else: {key, add_to_list(value)}
    end

    # `:external` goes after the bare tags, before any `tag: value`
    # filters — a keyword tail has to stay last.
    defp add_to_list({:__block__, meta, [items]}), do: {:__block__, meta, [add_to_list(items)]}

    defp add_to_list(items) do
      {tags, filters} = Enum.split_while(items, &(not match?({_key, _value}, &1)))
      tags ++ [:external] ++ filters
    end
  end
end
