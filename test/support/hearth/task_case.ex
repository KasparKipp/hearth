defmodule Hearth.TaskCase do
  @moduledoc false

  # Shared setup for the Mix task tests: `Igniter.Test` plus helpers to
  # read back what a task wrote. Fixtures are read at compile time and
  # threaded through Igniter's virtual fs via `test_project(files: …)` —
  # in test mode `Igniter.exists?/2` only consults the virtual fs, never
  # real disk.

  use ExUnit.CaseTemplate

  using do
    quote do
      import Igniter.Test
      import Hearth.TaskCase
    end
  end

  def notice_text(igniter), do: Enum.join(igniter.notices, "\n\n")

  # Every issue the task raised, joined into one string.
  def issue_text(igniter), do: Enum.join(igniter.issues, "\n\n")

  # The content of a file the task created/updated, read back out of the
  # igniter's in-memory Rewrite (compose_task preserves rewrite changes).
  def created_file(igniter, path) do
    {:ok, source} = Rewrite.source(igniter.rewrite, path)
    Rewrite.Source.get(source, :content)
  end
end
