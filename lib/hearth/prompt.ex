defmodule Hearth.Prompt do
  @moduledoc false

  # regen's y/N questions. Igniter 0.8 adds `yes: true` to a task's
  # options whenever stdin isn't a terminal (`Igniter.Mix.Task.set_yes/2`),
  # so `options[:yes]` can't tell a `--yes` from a pipe or CI run. A
  # question is answered by, in order:
  #
  #   * `--yes` on the command line: accept;
  #   * test mode: accept, unless a test stands in for the terminal with
  #     the `:hearth_tty?` assign;
  #   * no terminal: decline, printing the question and how to accept;
  #   * the user, asked in the terminal (default no).
  #
  # Takes the igniter as a map: no Igniter call, so no Igniter guard.

  @spec confirm?(map(), String.t()) :: boolean()
  def confirm?(igniter, question) do
    cond do
      yes_given?(igniter) ->
        true

      igniter.assigns[:test_mode?] && not Map.has_key?(igniter.assigns, :hearth_tty?) ->
        true

      not tty?(igniter) ->
        Mix.shell().info("#{question} [y/N] n (no terminal to ask in; pass --yes to accept)")
        false

      true ->
        Mix.shell().yes?(question, default: :no)
    end
  end

  # Whether the command line itself says `--yes` (the last of `--yes` /
  # `--no-yes` wins, as for any switch). Igniter keeps the user's flags in
  # `argv_flags`; `options` is where it adds its own.
  @spec yes_given?(map()) :: boolean()
  def yes_given?(%{args: %{argv_flags: flags}}) do
    {options, _args, _invalid} = OptionParser.parse(flags, switches: [yes: :boolean])
    options[:yes] == true
  end

  # Not an igniter built from argv: nobody said `--yes`.
  def yes_given?(_igniter), do: false

  defp tty?(igniter) do
    case Map.fetch(igniter.assigns, :hearth_tty?) do
      {:ok, tty?} -> tty?
      :error -> terminal?("/dev/stdin")
    end
  end

  # Whether `stdin` (a path to it) is a terminal. Igniter's check
  # (`Igniter.Mix.Task.tty?/0`, private API) is "a character device", which
  # `/dev/null` is too: cron, systemd or `docker run` without `-i` would
  # then be asked, read end of file and decline without the `--yes` hint.
  # So `/dev/null` is no terminal. When it can't be told, assume a
  # terminal, as Igniter does.
  @doc false
  @spec terminal?(Path.t()) :: boolean()
  def terminal?(stdin) do
    case :file.read_file_info(stdin) do
      {:ok, info} -> elem(info, 2) == :device and file_id(info) != null_id()
      _error -> true
    end
  end

  # file_info's major_device, minor_device and inode.
  defp file_id(info), do: {elem(info, 9), elem(info, 10), elem(info, 11)}

  defp null_id do
    case :file.read_file_info("/dev/null") do
      {:ok, info} -> file_id(info)
      _error -> nil
    end
  end
end
