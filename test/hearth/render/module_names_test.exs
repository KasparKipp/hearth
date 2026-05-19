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
               MyApp.Billing.Stripe.StripeApi
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
               MyApp.Billing.Stripe
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
             ) == MyApp.Billing.StripeTest
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

  describe "external_test/1" do
    test "the external test is a sibling of layer1 with an ExternalTest suffix" do
      assert ModuleNames.external_test(app_module: "MyApp", integration: "Stripe") ==
               MyApp.Integrations.StripeExternalTest
    end

    test "a domain segment slots in after the app" do
      assert ModuleNames.external_test(
               app_module: "MyApp",
               integration: "Stripe",
               domain: "Billing"
             ) == MyApp.Billing.StripeExternalTest
    end

    test "it is a sibling of layer1, not a child of it" do
      opts = [app_module: "MyApp", integration: "Stripe"]

      refute ModuleNames.external_test(opts) ==
               Module.concat(ModuleNames.layer1(opts), "ExternalTest")
    end
  end

  describe "from_layer1/1" do
    test "derives every layer module from the Layer 1 module" do
      names = ModuleNames.from_layer1(MyApp.Integrations.Stripe)

      assert names.integration == "Stripe"
      assert names.layer1 == MyApp.Integrations.Stripe
      assert names.layer2 == MyApp.Integrations.Stripe.StripeApi
      assert names.layer3 == MyApp.Integrations.Stripe.StripeApi.Req
      assert names.layer1_test == MyApp.Integrations.StripeTest
      assert names.external_test == MyApp.Integrations.StripeExternalTest
      assert names.mock == MyApp.Integrations.Stripe.StripeApi.Mock
    end

    test "it is the inverse of building from app/domain/integration" do
      opts = [app_module: "MyApp", integration: "Stripe", domain: "Billing"]
      names = ModuleNames.from_layer1(ModuleNames.layer1(opts))

      assert names.layer2 == ModuleNames.layer2(opts)
      assert names.layer3 == ModuleNames.layer3(opts)
      assert names.layer1_test == ModuleNames.layer1_test(opts)
      assert names.external_test == ModuleNames.external_test(opts)
      assert names.mock == ModuleNames.mock(opts)
    end

    test "works for a --no-domain layout" do
      names = ModuleNames.from_layer1(MyApp.Stripe)

      assert names.integration == "Stripe"
      assert names.layer2 == MyApp.Stripe.StripeApi
      assert names.layer1_test == MyApp.StripeTest
    end
  end

  describe "empty domain (--no-domain)" do
    test "an empty-string domain drops the namespace segment entirely" do
      opts = [app_module: "MyApp", integration: "Stripe", domain: ""]

      assert ModuleNames.layer1(opts) == MyApp.Stripe
      assert ModuleNames.layer2(opts) == MyApp.Stripe.StripeApi
      assert ModuleNames.layer3(opts) == MyApp.Stripe.StripeApi.Req
      assert ModuleNames.layer1_test(opts) == MyApp.StripeTest
      assert ModuleNames.external_test(opts) == MyApp.StripeExternalTest
    end
  end
end
