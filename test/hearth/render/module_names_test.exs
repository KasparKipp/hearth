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
end
