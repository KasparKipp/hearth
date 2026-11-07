defmodule Hearth.Spec.Drift.ConstraintsTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Drift.Schema

  # Constraint keywords, through `Schema.changes/3`. A tighter schema
  # breaks a request (callers send what it no longer accepts), a looser
  # one a response (callers read what it didn't return before).

  defp tightens(old, new, detail) do
    assert Schema.changes(old, new, :request) == [{detail, true}]
    assert Schema.changes(old, new, :response) == [{detail, false}]
    assert Schema.changes(old, new, :both) == [{detail, true}]
  end

  defp loosens(old, new, detail) do
    assert Schema.changes(old, new, :request) == [{detail, false}]
    assert Schema.changes(old, new, :response) == [{detail, true}]
    assert Schema.changes(old, new, :both) == [{detail, true}]
  end

  defp breaks_both(old, new, detail) do
    for side <- [:request, :response, :both],
        do: assert(Schema.changes(old, new, side) == [{detail, true}])
  end

  defp unchanged(old, new) do
    for side <- [:request, :response, :both], do: assert(Schema.changes(old, new, side) == [])
  end

  defp kw(schema \\ %{}, key, value), do: Map.put(schema, key, value)

  test "upper bounds: added or lowered tighten, removed or raised loosen" do
    for key <- ~w(maxLength maxItems maxProperties maximum) do
      tightens(kw(key, 100), kw(key, 10), "#{key} 100 → 10")
      loosens(kw(key, 10), kw(key, 100), "#{key} 10 → 100")
      tightens(%{}, kw(key, 10), "#{key} (none) → 10")
      loosens(kw(key, 10), %{}, "#{key} 10 → (none)")
    end
  end

  test "lower bounds: added or raised tighten, removed or lowered loosen" do
    for key <- ~w(minLength minItems minProperties minimum) do
      tightens(kw(key, 1), kw(key, 5), "#{key} 1 → 5")
      loosens(kw(key, 5), kw(key, 1), "#{key} 5 → 1")
      tightens(%{}, kw(key, 1), "#{key} (none) → 1")
      loosens(kw(key, 1), %{}, "#{key} 1 → (none)")
    end
  end

  test "an equal bound written differently is no change" do
    unchanged(kw("maximum", 10), kw("maximum", 10.0))
  end

  test "3.0 boolean exclusive bounds tighten when set, loosen when cleared" do
    for {key, base} <- [{"exclusiveMaximum", "maximum"}, {"exclusiveMinimum", "minimum"}] do
      bound = kw(base, 10)

      tightens(kw(bound, key, false), kw(bound, key, true), "#{key} false → true")
      loosens(kw(bound, key, true), kw(bound, key, false), "#{key} true → false")
      tightens(bound, kw(bound, key, true), "#{key} false → true")
      unchanged(bound, kw(bound, key, false))
    end
  end

  test "3.1 numeric exclusive bounds compare like their inclusive ones" do
    tightens(kw("exclusiveMaximum", 10), kw("exclusiveMaximum", 5), "exclusiveMaximum 10 → 5")
    loosens(kw("exclusiveMaximum", 5), kw("exclusiveMaximum", 10), "exclusiveMaximum 5 → 10")
    tightens(kw("exclusiveMinimum", 1), kw("exclusiveMinimum", 2), "exclusiveMinimum 1 → 2")
    loosens(kw("exclusiveMinimum", 2), %{}, "exclusiveMinimum 2 → (none)")
  end

  test "a 3.0 exclusive bound rewritten in 3.1 form is no change" do
    unchanged(%{"maximum" => 10, "exclusiveMaximum" => true}, %{"exclusiveMaximum" => 10})
    unchanged(%{"exclusiveMinimum" => 0}, %{"minimum" => 0, "exclusiveMinimum" => true})
    unchanged(%{"maximum" => 10, "exclusiveMaximum" => false}, %{"maximum" => 10})
  end

  test "multipleOf: a multiple of the old one tightens, a divisor loosens, else both" do
    tightens(kw("multipleOf", 2), kw("multipleOf", 4), "multipleOf 2 → 4")
    loosens(kw("multipleOf", 4), kw("multipleOf", 2), "multipleOf 4 → 2")
    breaks_both(kw("multipleOf", 2), kw("multipleOf", 3), "multipleOf 2 → 3")
    tightens(%{}, kw("multipleOf", 0.5), "multipleOf (none) → 0.5")
    loosens(kw("multipleOf", 0.5), %{}, "multipleOf 0.5 → (none)")
  end

  test "pattern, format and const: added tightens, removed loosens, changed breaks both" do
    for {key, a, b} <- [
          {"pattern", "^a$", "^b$"},
          {"format", "uuid", "email"},
          {"const", "x", "y"}
        ] do
      tightens(%{}, kw(key, a), "#{key} (none) → #{a}")
      loosens(kw(key, a), %{}, "#{key} #{a} → (none)")
      breaks_both(kw(key, a), kw(key, b), "#{key} #{a} → #{b}")
    end
  end

  test "const shows a structured value as JSON" do
    tightens(%{}, kw("const", %{"a" => 1}), ~s|const (none) → {"a":1}|)
  end

  test "uniqueItems tightens when set, loosens when cleared" do
    tightens(%{}, kw("uniqueItems", true), "uniqueItems false → true")
    loosens(kw("uniqueItems", true), kw("uniqueItems", false), "uniqueItems true → false")
    unchanged(%{}, kw("uniqueItems", false))
  end

  test "readOnly added breaks requests, writeOnly added breaks responses; removing either breaks nothing" do
    tightens(%{}, kw("readOnly", true), "readOnly false → true")
    loosens(%{}, kw("writeOnly", true), "writeOnly false → true")

    for key <- ~w(readOnly writeOnly), side <- [:request, :response, :both] do
      assert Schema.changes(kw(key, true), %{}, side) == [{"#{key} true → false", false}]
    end
  end

  test "not: added tightens, removed loosens, changed breaks both" do
    string = %{"type" => "string"}

    tightens(%{}, kw("not", string), "not (none) → schema")
    loosens(kw("not", string), %{}, "not schema → (none)")
    breaks_both(kw("not", string), kw("not", %{"type" => "integer"}), "not schema changed")
  end

  test "a changed default breaks requests only" do
    tightens(kw("default", 1), kw("default", 2), "default 1 → 2")
    tightens(%{}, kw("default", "a"), "default (none) → a")
    tightens(kw("default", "a"), %{}, "default a → (none)")
    tightens(kw("default", "a"), kw("default", nil), "default a → null")
  end

  describe "additionalProperties" do
    @string %{"type" => "string"}

    test "absent, true and {} are alike" do
      unchanged(%{}, kw("additionalProperties", true))
      unchanged(kw("additionalProperties", %{}), kw("additionalProperties", true))
    end

    test "true → schema → false tightens, the reverse loosens" do
      any = kw("additionalProperties", true)
      some = kw("additionalProperties", @string)
      none = kw("additionalProperties", false)

      tightens(any, some, "additionalProperties true → schema")
      tightens(some, none, "additionalProperties schema → false")
      tightens(%{}, none, "additionalProperties true → false")
      loosens(none, some, "additionalProperties false → schema")
      loosens(some, %{}, "additionalProperties schema → true")
    end

    test "a schema compared with a schema recurses under {}" do
      meta = fn schema -> %{"properties" => %{"meta" => kw("additionalProperties", schema)}} end

      tightens(
        meta.(kw(@string, "maxLength", 100)),
        meta.(kw(@string, "maxLength", 10)),
        "meta{}: maxLength 100 → 10"
      )

      breaks_both(
        kw("additionalProperties", @string),
        kw("additionalProperties", %{"type" => "integer"}),
        "{}: type string → integer"
      )
    end
  end

  describe "paths and $refs" do
    test "nested keywords carry their path" do
      old = %{"properties" => %{"owner" => %{"properties" => %{"name" => kw("maxLength", 100)}}}}
      new = %{"properties" => %{"owner" => %{"properties" => %{"name" => kw("maxLength", 10)}}}}

      tightens(old, new, "owner.name: maxLength 100 → 10")

      tags = fn unique ->
        %{"properties" => %{"tags" => %{"items" => kw("uniqueItems", unique)}}}
      end

      tightens(tags.(false), tags.(true), "tags[]: uniqueItems false → true")
    end

    test "keywords beside an unchanged $ref are compared" do
      ref = %{"$ref" => "#/components/schemas/Owner"}

      tightens(kw(ref, "nullable", true), ref, "no longer nullable")
      loosens(ref, kw(ref, "nullable", true), "now nullable")
      tightens(ref, kw(ref, "maxLength", 5), "maxLength (none) → 5")
    end

    test "a changed $ref is reported alone" do
      old = %{"$ref" => "#/components/schemas/A", "nullable" => true}
      new = %{"$ref" => "#/components/schemas/B"}

      breaks_both(old, new, "$ref A → B")
    end
  end

  describe "readOnly and writeOnly properties" do
    defp prop(flags, max) do
      %{"properties" => %{"id" => Map.merge(flags, %{"type" => "string", "maxLength" => max})}}
    end

    test "a readOnly property's constraints don't count in requests" do
      read_only = %{"readOnly" => true}

      assert Schema.changes(prop(read_only, 10), prop(read_only, 5), :request) == []

      assert Schema.changes(prop(read_only, 10), prop(read_only, 5), :response) ==
               [{"id: maxLength 10 → 5", false}]

      assert Schema.changes(prop(read_only, 10), prop(read_only, 5), :both) ==
               [{"id: maxLength 10 → 5", false}]

      assert Schema.changes(prop(read_only, 5), prop(read_only, 10), :both) ==
               [{"id: maxLength 5 → 10", true}]
    end

    test "a writeOnly property's constraints don't count in responses" do
      write_only = %{"writeOnly" => true}

      assert Schema.changes(prop(write_only, 10), prop(write_only, 5), :response) == []

      assert Schema.changes(prop(write_only, 10), prop(write_only, 5), :request) ==
               [{"id: maxLength 10 → 5", true}]

      assert Schema.changes(prop(write_only, 5), prop(write_only, 10), :both) ==
               [{"id: maxLength 5 → 10", false}]

      assert Schema.changes(prop(write_only, 10), prop(write_only, 5), :both) ==
               [{"id: maxLength 10 → 5", true}]
    end

    test "a property that only now becomes readOnly is compared as usual" do
      assert Schema.changes(prop(%{}, 10), prop(%{"readOnly" => true}, 5), :request) == [
               {"id: maxLength 10 → 5", true},
               {"id: readOnly false → true", true}
             ]
    end
  end

  test "annotations and rarely used 3.1 keywords are ignored" do
    old = %{"type" => "array", "items" => %{"type" => "string"}}

    new =
      Map.merge(old, %{
        "deprecated" => true,
        "x-foo" => "bar",
        "externalDocs" => %{"url" => "https://example.com"},
        "xml" => %{"name" => "pets"},
        "$comment" => "note",
        "examples" => [["a"]],
        "prefixItems" => [%{"type" => "string"}],
        "contains" => %{"type" => "string"},
        "discriminator" => %{"propertyName" => "kind"}
      })

    unchanged(old, new)
  end
end
