defmodule Hearth.Spec.Drift.SchemaTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Drift.Schema

  defp object(props, required \\ []) do
    %{"type" => "object", "properties" => props, "required" => required}
  end

  @string %{"type" => "string"}

  describe "changes/2" do
    test "identical schemas have no changes" do
      assert Schema.changes(object(%{"a" => @string}), object(%{"a" => @string})) == []
    end

    test "ignores descriptions, examples and titles" do
      old = %{"type" => "string", "description" => "old", "example" => "x"}
      new = %{"type" => "string", "description" => "new", "title" => "T"}

      assert Schema.changes(old, new) == []
    end

    test "an added optional property is additive, an added required one breaking" do
      old = object(%{"a" => @string})

      assert Schema.changes(old, object(%{"a" => @string, "b" => @string})) ==
               [{"property b added", false}]

      assert Schema.changes(old, object(%{"a" => @string, "b" => @string}, ["b"])) ==
               [{"property b added, required", true}]
    end

    test "a removed property is breaking" do
      assert Schema.changes(object(%{"a" => @string, "b" => @string}), object(%{"a" => @string})) ==
               [{"property b removed", true}]
    end

    test "a property becoming required is breaking; becoming optional is additive" do
      props = %{"a" => @string}

      assert Schema.changes(object(props), object(props, ["a"])) == [{"a is now required", true}]

      assert Schema.changes(object(props, ["a"]), object(props)) == [
               {"a is no longer required", false}
             ]
    end

    test "enum values added are additive, removed are breaking" do
      old = %{"type" => "string", "enum" => ["A", "B"]}

      assert Schema.changes(old, %{"type" => "string", "enum" => ["A", "B", "C"]}) ==
               [{"enum gains C", false}]

      assert Schema.changes(old, %{"type" => "string", "enum" => ["A"]}) ==
               [{"enum loses B", true}]
    end

    test "a type change is breaking" do
      assert Schema.changes(@string, %{"type" => "integer"}) == [{"type string → integer", true}]
    end

    test "a $ref change is breaking, an unchanged $ref is no change" do
      assert Schema.changes(%{"$ref" => "#/components/schemas/A"}, %{
               "$ref" => "#/components/schemas/A"
             }) ==
               []

      assert Schema.changes(%{"$ref" => "#/components/schemas/A"}, %{
               "$ref" => "#/components/schemas/B"
             }) ==
               [{"$ref A → B", true}]
    end

    test "nested properties and array items are reported with their path" do
      old =
        object(%{
          "owner" => object(%{"name" => @string}),
          "tags" => %{"type" => "array", "items" => @string}
        })

      new =
        object(%{
          "owner" => object(%{"name" => %{"type" => "integer"}}),
          "tags" => %{"type" => "array", "items" => %{"type" => "string", "enum" => ["x"]}}
        })

      assert Schema.changes(old, new) == [
               {"owner.name: type string → integer", true},
               {"tags[]: enum gains x", false}
             ]
    end

    test "composition members are compared by position" do
      old = %{"allOf" => [%{"$ref" => "#/components/schemas/A"}, object(%{"a" => @string})]}

      new = %{
        "allOf" => [
          %{"$ref" => "#/components/schemas/A"},
          object(%{"a" => @string, "b" => @string})
        ]
      }

      assert Schema.changes(old, new) == [{"allOf[1]: property b added", false}]

      assert Schema.changes(old, %{"allOf" => [%{"$ref" => "#/components/schemas/A"}]}) ==
               [{"allOf: 2 → 1 schemas", true}]
    end
  end
end
