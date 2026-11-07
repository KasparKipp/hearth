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

    test "ignores descriptions, examples, titles and other annotations" do
      old = %{"type" => "string", "description" => "old", "example" => "x"}

      new = %{
        "type" => "string",
        "description" => "new",
        "title" => "T",
        "deprecated" => true,
        "x-foo" => "bar"
      }

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
               {"tags[]: enum (none) → x", true}
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

  describe "changes/3 by side" do
    test "a response schema breaks where it gets looser, a request schema where it gets tighter" do
      props = %{"a" => @string}
      enum = fn values -> %{"type" => "string", "enum" => values} end

      cases = [
        {object(props), object(%{"a" => @string, "b" => @string}, ["b"]), true, false},
        {object(props), object(props, ["a"]), true, false},
        {object(props, ["a"]), object(props), false, true},
        {object(%{"a" => @string, "b" => @string}), object(props), true, true},
        {enum.(["A"]), enum.(["A", "B"]), false, true},
        {enum.(["A", "B"]), enum.(["A"]), true, false},
        {@string, enum.(["A"]), true, false},
        {enum.(["A"]), @string, false, true},
        {%{"$ref" => "#/components/schemas/A"}, %{"$ref" => "#/components/schemas/B"}, true,
         true},
        {%{"allOf" => [@string]}, %{"allOf" => [@string, @string]}, true, true}
      ]

      for {old, new, request?, response?} <- cases do
        assert [{_, ^request?}] = Schema.changes(old, new, :request)
        assert [{_, ^response?}] = Schema.changes(old, new, :response)
        assert [{_, true}] = Schema.changes(old, new, :both), inspect({old, new})
      end
    end

    test "an optional property added breaks neither side" do
      assert Schema.changes(object(%{}), object(%{"b" => @string}), :both) ==
               [{"property b added", false}]
    end

    test "a schema with no enum gaining one is a tightening" do
      assert Schema.changes(@string, %{"type" => "string", "enum" => ["A", "B"]}) ==
               [{"enum (none) → A, B", true}]

      assert Schema.changes(%{"type" => "string", "enum" => ["A"]}, @string, :response) ==
               [{"enum A → (none)", true}]
    end

    test "enum values compare as sets" do
      old = %{"type" => "string", "enum" => ["A", "B"]}

      assert Schema.changes(old, %{"type" => "string", "enum" => ["B", "A", "A"]}) == []

      assert Schema.changes(%{"enum" => ["A", "A", "B"]}, %{"enum" => ["A", "B", "C", "C"]}) ==
               [{"enum gains C", false}]
    end

    test "a type list compares as a set, and null is nullability" do
      assert Schema.changes(%{"type" => ["string", "null"]}, %{"type" => ["null", "string"]}) ==
               []

      assert Schema.changes(%{"type" => "string", "nullable" => true}, %{
               "type" => ["string", "null"]
             }) == []

      assert Schema.changes(%{"type" => ["null", "string"]}, %{
               "type" => "string",
               "nullable" => true
             }) == []
    end

    test "nullability changes by side" do
      nullable = %{"type" => ["string", "null"]}

      assert Schema.changes(nullable, @string, :request) == [{"no longer nullable", true}]
      assert Schema.changes(nullable, @string, :response) == [{"no longer nullable", false}]
      assert Schema.changes(@string, nullable, :request) == [{"now nullable", false}]
      assert Schema.changes(@string, nullable, :response) == [{"now nullable", true}]

      assert Schema.changes(object(%{"owner" => @string}), object(%{"owner" => nullable})) ==
               [{"owner: now nullable", false}]
    end

    test "a type set narrowing tightens, widening loosens, anything else breaks both" do
      wide = %{"type" => ["string", "integer"]}

      assert Schema.changes(wide, @string, :request) == [{"type string | integer → string", true}]

      assert Schema.changes(wide, @string, :response) == [
               {"type string | integer → string", false}
             ]

      assert Schema.changes(@string, wide, :request) == [
               {"type string → string | integer", false}
             ]

      assert Schema.changes(@string, wide, :response) == [
               {"type string → string | integer", true}
             ]

      assert Schema.changes(%{}, @string, :response) == [{"type (none) → string", false}]
      assert Schema.changes(@string, %{}, :request) == [{"type string → (none)", false}]

      assert Schema.changes(@string, %{"type" => "integer"}, :response) ==
               [{"type string → integer", true}]
    end

    test "the side reaches nested properties, items and compositions" do
      old = object(%{"tags" => %{"type" => "array", "items" => %{"enum" => ["a"]}}})
      new = object(%{"tags" => %{"type" => "array", "items" => %{"enum" => ["a", "b"]}}})

      assert Schema.changes(old, new, :response) == [{"tags[]: enum gains b", true}]
      assert Schema.changes(old, new, :request) == [{"tags[]: enum gains b", false}]

      assert Schema.changes(%{"oneOf" => [old]}, %{"oneOf" => [new]}, :response) ==
               [{"oneOf[0].tags[]: enum gains b", true}]
    end
  end
end
