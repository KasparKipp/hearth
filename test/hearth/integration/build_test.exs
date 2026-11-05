# Mix tasks a `build:` names. Mix runs a task in the caller's process,
# so `self()` is the test's.
defmodule Mix.Tasks.HearthBuildTest.Ok do
  @moduledoc false
  use Mix.Task
  def run(args), do: send(self(), {:built, args})
end

defmodule Mix.Tasks.HearthBuildTest.Fail do
  @moduledoc false
  use Mix.Task
  def run(_args), do: Mix.raise("spec.wsdl has no <types> section")
end

defmodule Mix.Tasks.HearthBuildTest.Crash do
  @moduledoc false
  use Mix.Task
  def run(_args), do: raise(ArgumentError, "bad input")
end

defmodule Mix.Tasks.HearthBuildTest.Exit do
  @moduledoc false
  use Mix.Task
  def run([status]), do: exit({:shutdown, String.to_integer(status)})
end

defmodule Hearth.Integration.BuildTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Hearth.Integration.Build

  test "an entry without build: runs nothing" do
    igniter = test_project()
    assert {:ok, ^igniter} = Build.run(igniter, source: "priv/specs/a.yaml")
    refute_received {:built, _}
  end

  test "runs the Mix task with its arguments" do
    entry = [build: "hearth_build_test.ok --out 'priv/specs/a b.yaml'"]

    assert {:ok, _igniter} = Build.run(test_project(), entry)
    assert_received {:built, ["--out", "priv/specs/a b.yaml"]}
  end

  test "runs a command once per run, however many entries name it" do
    entry = [build: "hearth_build_test.ok"]

    assert {:ok, igniter} = Build.run(test_project(), entry)
    assert {:ok, igniter} = Build.run(igniter, entry)
    assert {:ok, _igniter} = Build.run(igniter, build: "hearth_build_test.ok --other")

    assert_received {:built, []}
    assert_received {:built, ["--other"]}
    refute_received {:built, _}
  end

  test "a failing task is an error naming the command and its message" do
    assert {:error, {:build, "hearth_build_test.fail", "spec.wsdl has no <types> section"}} =
             Build.run(test_project(), build: "hearth_build_test.fail")

    assert {:error, {:build, "hearth_build_test.crash", "bad input"}} =
             Build.run(test_project(), build: "hearth_build_test.crash")
  end

  test "a task that exits non-zero is an error, zero isn't" do
    assert {:error, {:build, "hearth_build_test.exit 3", "it exited with status 3"}} =
             Build.run(test_project(), build: "hearth_build_test.exit 3")

    assert {:ok, _igniter} = Build.run(test_project(), build: "hearth_build_test.exit 0")
  end

  test "a task that doesn't exist is an error" do
    assert {:error, {:build, "hearth_build_test.missing", message}} =
             Build.run(test_project(), build: "hearth_build_test.missing")

    assert message =~ "hearth_build_test.missing"
  end

  test "the :hearth_build assign stands in for Mix, and may change the igniter" do
    igniter =
      Igniter.assign(test_project(), :hearth_build, fn igniter, "acme.spec", ["--strict"] ->
        {:ok, Igniter.create_new_file(igniter, "priv/specs/acme.yaml", "openapi: 3.0.0\n")}
      end)

    assert {:ok, igniter} = Build.run(igniter, build: "acme.spec --strict")
    assert Igniter.exists?(igniter, "priv/specs/acme.yaml")

    failing = Igniter.assign(test_project(), :hearth_build, fn _, _, _ -> {:error, "nope"} end)
    assert {:error, {:build, "acme.spec", "nope"}} = Build.run(failing, build: "acme.spec")
  end
end
