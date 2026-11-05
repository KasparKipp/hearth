defmodule Hearth.PromptTest do
  # Swaps the global Mix shell to answer prompts.
  use ExUnit.Case, async: false

  alias Hearth.Prompt

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  # An igniter as `Prompt` sees it: the user's flags, Igniter's options
  # (a pipe adds `yes: true`) and the assigns.
  defp igniter(flags, assigns) do
    %{args: %{argv_flags: flags, options: [yes: true]}, assigns: Map.new(assigns)}
  end

  describe "yes_given?/1" do
    test "only a --yes on the command line counts, the last switch winning" do
      assert Prompt.yes_given?(igniter(["--yes"], []))
      assert Prompt.yes_given?(igniter(["--no-yes", "--yes"], []))
      refute Prompt.yes_given?(igniter(["--yes", "--no-yes"], []))
      refute Prompt.yes_given?(igniter(["--no-yes"], []))
      refute Prompt.yes_given?(igniter(["--sync"], []))
    end

    test "an igniter without argv flags didn't say --yes" do
      refute Prompt.yes_given?(%{args: nil, assigns: %{}})
    end
  end

  describe "terminal?/1" do
    test "/dev/null is no terminal, though a character device" do
      refute Prompt.terminal?("/dev/null")
    end

    test "a file or a pipe is no terminal" do
      refute Prompt.terminal?("mix.exs")
    end

    test "when stdin can't be read, a terminal is assumed, as Igniter does" do
      assert Prompt.terminal?("/no/such/stdin")
    end
  end

  describe "confirm?/2" do
    test "--yes accepts without asking, terminal or not" do
      assert Prompt.confirm?(igniter(["--yes"], hearth_tty?: false), "Go?")
      assert Prompt.confirm?(igniter(["--yes"], hearth_tty?: true), "Go?")
      refute_received {:mix_shell, :yes?, _}
    end

    test "test mode accepts unless a test stands in for the terminal" do
      assert Prompt.confirm?(igniter([], test_mode?: true), "Go?")
      refute Prompt.confirm?(igniter([], test_mode?: true, hearth_tty?: false), "Go?")
    end

    test "without a terminal it declines, printing the question and how to accept" do
      refute Prompt.confirm?(igniter([], hearth_tty?: false), "Go?")

      assert_received {:mix_shell, :info, [line]}
      assert line =~ "Go? [y/N] n"
      assert line =~ "--yes"
      refute_received {:mix_shell, :yes?, _}
    end

    test "in a terminal it asks" do
      send(self(), {:mix_shell_input, :yes?, true})
      assert Prompt.confirm?(igniter([], hearth_tty?: true), "Go?")
      assert_received {:mix_shell, :yes?, ["Go?"]}

      send(self(), {:mix_shell_input, :yes?, false})
      refute Prompt.confirm?(igniter([], hearth_tty?: true), "Go?")
    end
  end
end
