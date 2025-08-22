require "featurevisor"

RSpec.describe "sdk: child" do
  it "should create a child instance" do
    f = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          test: {
            key: "test",
            bucketBy: "userId",
            variablesSchema: {
              color: {
                key: "color",
                type: "string",
                defaultValue: "red"
              },
              showSidebar: {
                key: "showSidebar",
                type: "boolean",
                defaultValue: false
              },
              sidebarTitle: {
                key: "sidebarTitle",
                type: "string",
                defaultValue: "sidebar title"
              },
              count: {
                key: "count",
                type: "integer",
                defaultValue: 0
              },
              price: {
                key: "price",
                type: "double",
                defaultValue: 9.99
              },
              paymentMethods: {
                key: "paymentMethods",
                type: "array",
                defaultValue: ["paypal", "creditcard"]
              },
              flatConfig: {
                key: "flatConfig",
                type: "object",
                defaultValue: {
                  key: "value"
                }
              },
              nestedConfig: {
                key: "nestedConfig",
                type: "json",
                defaultValue: JSON.generate({
                  key: {
                    nested: "value"
                  }
                })
              }
            },
            variations: [
              { value: "control" },
              {
                value: "treatment",
                variables: {
                  showSidebar: true,
                  sidebarTitle: "sidebar title from variation"
                },
                variableOverrides: {
                  showSidebar: [
                    {
                      segments: ["netherlands"],
                      value: false
                    },
                    {
                      conditions: [
                        {
                          attribute: "country",
                          operator: "equals",
                          value: "de"
                        }
                      ],
                      value: false
                    }
                  ],
                  sidebarTitle: [
                    {
                      segments: ["netherlands"],
                      value: "Dutch title"
                    },
                    {
                      conditions: [
                        {
                          attribute: "country",
                          operator: "equals",
                          value: "de"
                        }
                      ],
                      value: "German title"
                    }
                  ]
                }
              }
            ],
            force: [
              {
                conditions: [{ attribute: "userId", operator: "equals", value: "user-ch" }],
                enabled: true,
                variation: "control",
                variables: {
                  color: "red and white"
                }
              },
              {
                conditions: [{ attribute: "userId", operator: "equals", value: "user-gb" }],
                enabled: false
              },
              {
                conditions: [
                  { attribute: "userId", operator: "equals", value: "user-forced-variation" }
                ],
                enabled: true,
                variation: "treatment"
              }
            ],
            traffic: [
              # belgium
              {
                key: "2",
                segments: ["belgium"],
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 0] },
                  {
                    variation: "treatment",
                    range: [0, 100_000]
                  }
                ],
                variation: "control",
                variables: {
                  color: "black"
                }
              },
              # everyone
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 50_000] },
                  {
                    variation: "treatment",
                    range: [50_000, 100_000]
                  }
                ]
              }
            ]
          },
          anotherTest: {
            key: "test",
            bucketBy: "userId",
            traffic: [
              # everyone
              {
                key: "1",
                segments: "*",
                percentage: 100_000
              }
            ]
          }
        },
        segments: {
          netherlands: {
            key: "netherlands",
            conditions: JSON.generate([
              {
                attribute: "country",
                operator: "equals",
                value: "nl"
              }
            ])
          },
          belgium: {
            key: "belgium",
            conditions: JSON.generate([
              {
                attribute: "country",
                operator: "equals",
                value: "be"
              }
            ])
          }
        }
      },
      context: {
        appVersion: "1.0.0"
      }
    )

    expect(f).not_to be_nil
    expect(f.get_context).to eq({ appVersion: "1.0.0" })

    child_f = f.spawn({
      userId: "123",
      country: "nl"
    })

    expect(child_f).not_to be_nil
    expect(child_f.get_context).to eq({ appVersion: "1.0.0", userId: "123", country: "nl" })

    context_updated = false
    unsubscribe_context = child_f.on("context_set") do
      context_updated = true
    end

    child_f.set_context({ country: "be" })
    expect(child_f.get_context).to eq({ appVersion: "1.0.0", userId: "123", country: "be" })

    expect(child_f.is_enabled("test")).to be true
    expect(child_f.get_variation("test")).to eq("control")

    expect(child_f.get_variable("test", "color")).to eq("black")
    expect(child_f.get_variable_string("test", "color")).to eq("black")

    expect(child_f.get_variable("test", "showSidebar")).to be false
    expect(child_f.get_variable_boolean("test", "showSidebar")).to be false

    expect(child_f.get_variable("test", "sidebarTitle")).to eq("sidebar title")
    expect(child_f.get_variable_string("test", "sidebarTitle")).to eq("sidebar title")

    expect(child_f.get_variable("test", "count")).to eq(0)
    expect(child_f.get_variable_integer("test", "count")).to eq(0)

    expect(child_f.get_variable("test", "price")).to eq(9.99)
    expect(child_f.get_variable_double("test", "price")).to eq(9.99)

    expect(child_f.get_variable("test", "paymentMethods")).to eq(["paypal", "creditcard"])
    expect(child_f.get_variable_array("test", "paymentMethods")).to eq(["paypal", "creditcard"])

    expect(child_f.get_variable("test", "flatConfig")).to eq({ key: "value" })
    expect(child_f.get_variable_object("test", "flatConfig")).to eq({ key: "value" })

    expect(child_f.get_variable("test", "nestedConfig")).to eq({
      key: { nested: "value" }
    })
    expect(child_f.get_variable_json("test", "nestedConfig")).to eq({
      key: { nested: "value" }
    })

    expect(context_updated).to be true
    unsubscribe_context.call

    expect(child_f.is_enabled("newFeature")).to be false
    child_f.set_sticky({
      newFeature: {
        enabled: true
      }
    })
    expect(child_f.is_enabled("newFeature")).to be true

    all_evaluations = child_f.get_all_evaluations
    expect(all_evaluations.keys).to eq([:test, :anotherTest])

    child_f.close
  end
end
