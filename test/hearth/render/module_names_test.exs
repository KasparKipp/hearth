defmodule Hearth.Render.ModuleNamesTest do
  use ExUnit.Case, async: true

  alias Hearth.Render.ModuleNames

  describe "layer2/1" do
    test "verbose name without a domain" do
      assert ModuleNames.layer2(app_module: "MyApp", integration: "Stripe") ==
               MyApp.Integrations.Stripe.StripeApi
    end

    test "a domain segment slots in after the app" do
      assert ModuleNames.layer2(app_module: "MyApp", integration: "Stripe", domain: "Billing") ==
               MyApp.Billing.Integrations.Stripe.StripeApi
    end

    test "an explicit nil domain is the same as omitting it" do
      assert ModuleNames.layer2(app_module: "MyApp", integration: "Stripe", domain: nil) ==
               ModuleNames.layer2(app_module: "MyApp", integration: "Stripe")
    end

    test "the behaviour module repeats the integration name with an Api suffix" do
      assert ModuleNames.layer2(app_module: "App", integration: "Petstore") ==
               App.Integrations.Petstore.PetstoreApi
    end
  end

  describe "layer1/1" do
    test "the raw client drops the Api suffix" do
      assert ModuleNames.layer1(app_module: "MyApp", integration: "Stripe") ==
               MyApp.Integrations.Stripe
    end

    test "a domain segment slots in after the app" do
      assert ModuleNames.layer1(app_module: "MyApp", integration: "Stripe", domain: "Billing") ==
               MyApp.Billing.Integrations.Stripe
    end

    test "layer1 is layer2's parent module" do
      opts = [app_module: "MyApp", integration: "Stripe"]
      assert Module.concat(ModuleNames.layer1(opts), "StripeApi") == ModuleNames.layer2(opts)
    end
  end

  describe "layer1_test/1" do
    test "the test module is a sibling of layer1 with a Test suffix" do
      assert ModuleNames.layer1_test(app_module: "MyApp", integration: "Stripe") ==
               MyApp.Integrations.StripeTest
    end

    test "a domain segment slots in after the app" do
      assert ModuleNames.layer1_test(
               app_module: "MyApp",
               integration: "Stripe",
               domain: "Billing"
             ) == MyApp.Billing.Integrations.StripeTest
    end

    test "it is a sibling of layer1, not a child of it" do
      opts = [app_module: "MyApp", integration: "Stripe"]
      refute ModuleNames.layer1_test(opts) == Module.concat(ModuleNames.layer1(opts), "Test")
    end
  end

  describe "layer3/1" do
    test "the Req implementation is layer2 plus a Req suffix" do
      assert ModuleNames.layer3(app_module: "MyApp", integration: "Stripe") ==
               MyApp.Integrations.Stripe.StripeApi.Req
    end

    test "layer3 nests under layer2" do
      opts = [app_module: "MyApp", integration: "Stripe", domain: "Billing"]
      assert Module.concat(ModuleNames.layer2(opts), "Req") == ModuleNames.layer3(opts)
    end
  end

  describe "mock/1" do
    test "the Mox double is layer2 plus a Mock suffix" do
      assert ModuleNames.mock(app_module: "MyApp", integration: "Stripe") ==
               MyApp.Integrations.Stripe.StripeApi.Mock
    end

    test "mock nests under layer2, as a sibling of layer3" do
      opts = [app_module: "MyApp", integration: "Stripe", domain: "Billing"]
      assert Module.concat(ModuleNames.layer2(opts), "Mock") == ModuleNames.mock(opts)
    end
  end
end
