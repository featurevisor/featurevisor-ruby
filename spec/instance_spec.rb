require "featurevisor"

RSpec.describe "sdk: instance" do
  it "should be a function" do
    expect(Featurevisor.respond_to?(:create_instance)).to be true
  end

  it "should create instance with datafile content" do
    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {},
        segments: {}
      }
    )

    expect(sdk.respond_to?(:get_variation)).to be true
  end

  it "should configure plain bucketBy" do
    captured_bucket_key = ""

    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          test: {
            key: "test",
            bucketBy: "userId",
            variations: [{ value: "control" }, { value: "treatment" }],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 100_000] },
                  { variation: "treatment", range: [0, 0] }
                ]
              }
            ]
          }
        },
        segments: {}
      },
      hooks: [
        {
          name: "unit-test",
          bucket_key: ->(options) {
            captured_bucket_key = options[:bucket_key]
            options[:bucket_key]
          }
        }
      ]
    )

    feature_key = "test"
    context = {
      userId: "123"
    }

    expect(sdk.is_enabled(feature_key, context)).to be true
    expect(sdk.get_variation(feature_key, context)).to eq("control")
    expect(captured_bucket_key).to eq("123.test")
  end

  it "should configure and bucketBy" do
    captured_bucket_key = ""

    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          test: {
            key: "test",
            bucketBy: ["userId", "organizationId"],
            variations: [{ value: "control" }, { value: "treatment" }],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 100_000] },
                  { variation: "treatment", range: [0, 0] }
                ]
              }
            ]
          }
        },
        segments: {}
      },
      hooks: [
        {
          name: "unit-test",
          bucket_key: ->(options) {
            captured_bucket_key = options[:bucket_key]
            options[:bucket_key]
          }
        }
      ]
    )

    feature_key = "test"
    context = {
      userId: "123",
      organizationId: "456"
    }

    expect(sdk.get_variation(feature_key, context)).to eq("control")
    expect(captured_bucket_key).to eq("123.456.test")
  end

  it "should configure or bucketBy" do
    captured_bucket_key = ""

    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          test: {
            key: "test",
            bucketBy: { or: ["userId", "deviceId"] },
            variations: [{ value: "control" }, { value: "treatment" }],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 100_000] },
                  { variation: "treatment", range: [0, 0] }
                ]
              }
            ]
          }
        },
        segments: {}
      },
      hooks: [
        {
          name: "unit-test",
          bucket_key: ->(options) {
            captured_bucket_key = options[:bucket_key]
            options[:bucket_key]
          }
        }
      ]
    )

    expect(
      sdk.is_enabled("test", {
        userId: "123",
        deviceId: "456"
      })
    ).to be true

    expect(
      sdk.get_variation("test", {
        userId: "123",
        deviceId: "456"
      })
    ).to eq("control")
    expect(captured_bucket_key).to eq("123.test")

    expect(
      sdk.get_variation("test", {
        deviceId: "456"
      })
    ).to eq("control")
    expect(captured_bucket_key).to eq("456.test")
  end

  it "should intercept context: before hook" do
    intercepted = false
    intercepted_feature_key = ""
    intercepted_variable_key = ""

    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          test: {
            key: "test",
            bucketBy: "userId",
            variations: [{ value: "control" }, { value: "treatment" }],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 100_000] },
                  { variation: "treatment", range: [0, 0] }
                ]
              }
            ]
          }
        },
        segments: {}
      },
      hooks: [
        {
          name: "unit-test",
          before: ->(options) {
            feature_key = options[:feature_key]
            variable_key = options[:variable_key]

            intercepted = true
            intercepted_feature_key = feature_key
            intercepted_variable_key = variable_key

            options
          }
        }
      ]
    )

    variation = sdk.get_variation("test", {
      userId: "123"
    })

    expect(variation).to eq("control")
    expect(intercepted).to be true
    expect(intercepted_feature_key).to eq("test")
    expect(intercepted_variable_key).to be_nil
  end

  it "should intercept value: after hook" do
    intercepted = false
    intercepted_feature_key = ""
    intercepted_variable_key = ""

    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          test: {
            key: "test",
            bucketBy: "userId",
            variations: [{ value: "control" }, { value: "treatment" }],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 100_000] },
                  { variation: "treatment", range: [0, 0] }
                ]
              }
            ]
          }
        },
        segments: {}
      },
      hooks: [
        {
          name: "unit-test",
          after: ->(evaluation, options) {
            feature_key = options[:feature_key]
            variable_key = options[:variable_key]

            intercepted = true
            intercepted_feature_key = feature_key
            intercepted_variable_key = variable_key

            evaluation[:variation_value] = "control_intercepted" # manipulating value here
            evaluation
          }
        }
      ]
    )

    variation = sdk.get_variation("test", {
      userId: "123"
    })

    expect(variation).to eq("control_intercepted") # should not be "control" any more
    expect(intercepted).to be true
    expect(intercepted_feature_key).to eq("test")
    expect(intercepted_variable_key).to be_nil
  end

  it "should initialize with sticky features" do
    datafile_content = {
      schemaVersion: "2",
      revision: "1.0",
      features: {
        test: {
          key: "test",
          bucketBy: "userId",
          variations: [{ value: "control" }, { value: "treatment" }],
          traffic: [
            {
              key: "1",
              segments: "*",
              percentage: 100_000,
              allocation: [
                { variation: "control", range: [0, 0] },
                { variation: "treatment", range: [0, 100_000] }
              ]
            }
          ]
        }
      },
      segments: {}
    }

    sdk = Featurevisor.create_instance(
      sticky: {
        test: {
          enabled: true,
          variation: "control",
          variables: {
            color: "red"
          }
        }
      }
    )

    # initially control
    expect(
      sdk.get_variation("test", {
        userId: "123"
      })
    ).to eq("control")

    expect(
      sdk.get_variable("test", "color", {
        userId: "123"
      })
    ).to eq("red")

    sdk.set_datafile(datafile_content)

    # still control after setting datafile
    expect(
      sdk.get_variation("test", {
        userId: "123"
      })
    ).to eq("control")

    # unsetting sticky features will make it treatment
    sdk.set_sticky({}, true)
    expect(
      sdk.get_variation("test", {
        userId: "123"
      })
    ).to eq("treatment")
  end

  it "should honour simple required features" do
    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          requiredKey: {
            key: "requiredKey",
            bucketBy: "userId",
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 0, # disabled
                allocation: []
              }
            ]
          },
          myKey: {
            key: "myKey",
            bucketBy: "userId",
            required: ["requiredKey"],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: []
              }
            ]
          }
        },
        segments: {}
      }
    )

    # should be disabled because required is disabled
    expect(sdk.is_enabled("myKey")).to be false

    # enabling required should enable the feature too
    sdk2 = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          requiredKey: {
            key: "requiredKey",
            bucketBy: "userId",
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000, # enabled
                allocation: []
              }
            ]
          },
          myKey: {
            key: "myKey",
            bucketBy: "userId",
            required: ["requiredKey"],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: []
              }
            ]
          }
        },
        segments: {}
      }
    )
    expect(sdk2.is_enabled("myKey")).to be true
  end

  it "should honour required features with variation" do
    # should be disabled because required has different variation
    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          requiredKey: {
            key: "requiredKey",
            bucketBy: "userId",
            variations: [{ value: "control" }, { value: "treatment" }],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 0] },
                  { variation: "treatment", range: [0, 100_000] }
                ]
              }
            ]
          },
          myKey: {
            key: "myKey",
            bucketBy: "userId",
            required: [
              {
                key: "requiredKey",
                variation: "control" # different variation
              }
            ],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: []
              }
            ]
          }
        },
        segments: {}
      }
    )

    expect(sdk.is_enabled("myKey")).to be false

    # child should be enabled because required has desired variation
    sdk2 = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          requiredKey: {
            key: "requiredKey",
            bucketBy: "userId",
            variations: [{ value: "control" }, { value: "treatment" }],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 0] },
                  { variation: "treatment", range: [0, 100_000] }
                ]
              }
            ]
          },
          myKey: {
            key: "myKey",
            bucketBy: "userId",
            required: [
              {
                key: "requiredKey",
                variation: "treatment" # desired variation
              }
            ],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: []
              }
            ]
          }
        },
        segments: {}
      }
    )
    expect(sdk2.is_enabled("myKey")).to be true
  end

  it "should emit warnings for deprecated feature" do
    deprecated_count = 0

    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          test: {
            key: "test",
            bucketBy: "userId",
            variations: [{ value: "control" }, { value: "treatment" }],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 100_000] },
                  { variation: "treatment", range: [0, 0] }
                ]
              }
            ]
          },
          deprecatedTest: {
            key: "deprecatedTest",
            deprecated: true,
            bucketBy: "userId",
            variations: [{ value: "control" }, { value: "treatment" }],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 100_000] },
                  { variation: "treatment", range: [0, 0] }
                ]
              }
            ]
          }
        },
        segments: {}
      },
      logger: Featurevisor.create_logger(
        handler: ->(level, message, details) {
          if level == "warn" && message.include?("is deprecated")
            deprecated_count += 1
          end
        }
      )
    )

    test_variation = sdk.get_variation("test", {
      userId: "123"
    })
    deprecated_test_variation = sdk.get_variation("deprecatedTest", {
      userId: "123"
    })

    expect(test_variation).to eq("control")
    expect(deprecated_test_variation).to eq("control")
    expect(deprecated_count).to eq(1)
  end

  it "should check if enabled for overridden flags from rules" do
    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          test: {
            key: "test",
            bucketBy: "userId",
            traffic: [
              {
                key: "2",
                segments: ["netherlands"],
                percentage: 100_000,
                enabled: false,
                allocation: []
              },
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: []
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
          }
        }
      }
    )

    expect(sdk.is_enabled("test", { userId: "user-123", country: "de" })).to be true
    expect(sdk.is_enabled("test", { userId: "user-123", country: "nl" })).to be false
  end

  it "should check if enabled for mutually exclusive features" do
    bucket_value = 10_000

    sdk = Featurevisor.create_instance(
      hooks: [
        {
          name: "unit-test",
          bucket_value: ->(options) {
            bucket_value
          }
        }
      ],
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          mutex: {
            key: "mutex",
            bucketBy: "userId",
            ranges: [[0, 50_000]],
            traffic: [{ key: "1", segments: "*", percentage: 50_000, allocation: [] }]
          }
        },
        segments: {}
      }
    )

    expect(sdk.is_enabled("test")).to be false
    expect(sdk.is_enabled("test", { userId: "123" })).to be false

    bucket_value = 40_000
    expect(sdk.is_enabled("mutex", { userId: "123" })).to be true

    bucket_value = 60_000
    expect(sdk.is_enabled("mutex", { userId: "123" })).to be false
  end

  it "should get variation" do
    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          test: {
            key: "test",
            bucketBy: "userId",
            variations: [{ value: "control" }, { value: "treatment" }],
            force: [
              {
                conditions: [{ attribute: "userId", operator: "equals", value: "user-gb" }],
                enabled: false
              },
              {
                segments: ["netherlands"],
                enabled: false
              }
            ],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: [
                  { variation: "control", range: [0, 0] },
                  { variation: "treatment", range: [0, 100_000] }
                ]
              }
            ]
          },
          testWithNoVariation: {
            key: "testWithNoVariation",
            bucketBy: "userId",
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100_000,
                allocation: []
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
          }
        }
      }
    )

    context = {
      userId: "123"
    }

    expect(sdk.get_variation("test", context)).to eq("treatment")
    expect(sdk.get_variation("test", { userId: "user-ch" })).to eq("treatment")

    # non existing
    expect(sdk.get_variation("nonExistingFeature", context)).to be_nil

    # disabled
    expect(sdk.get_variation("test", { userId: "user-gb" })).to be_nil
    expect(sdk.get_variation("test", { userId: "user-gb" })).to be_nil
    expect(sdk.get_variation("test", { userId: "123", country: "nl" })).to be_nil

    # no variation
    expect(sdk.get_variation("testWithNoVariation", context)).to be_nil
  end

  it "should get variable" do
    sdk = Featurevisor.create_instance(
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
                  { variation: "control", range: [0, 0] },
                  {
                    variation: "treatment",
                    range: [0, 100_000]
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
      }
    )

    context = {
      userId: "123"
    }

    evaluated_features = sdk.get_all_evaluations(context)
    expect(evaluated_features).to eq({
      test: {
        enabled: true,
        variation: "treatment",
        variables: {
          color: "red",
          showSidebar: true,
          sidebarTitle: "sidebar title from variation",
          count: 0,
          price: 9.99,
          paymentMethods: ["paypal", "creditcard"],
          flatConfig: {
            key: "value"
          },
          nestedConfig: {
            key: {
              nested: "value"
            }
          }
        }
      },
      anotherTest: {
        enabled: true
      }
    })

    expect(sdk.get_variation("test", context)).to eq("treatment")
    expect(
      sdk.get_variation("test", {
        **context,
        country: "be"
      })
    ).to eq("control")
    expect(sdk.get_variation("test", { userId: "user-ch" })).to eq("control")

    expect(sdk.get_variable("test", "color", context)).to eq("red")
    expect(sdk.get_variable_string("test", "color", context)).to eq("red")
    expect(sdk.get_variable("test", "color", { **context, country: "be" })).to eq("black")
    expect(sdk.get_variable("test", "color", { userId: "user-ch" })).to eq("red and white")

    expect(sdk.get_variable("test", "showSidebar", context)).to be true
    expect(sdk.get_variable_boolean("test", "showSidebar", context)).to be true
    expect(
      sdk.get_variable_boolean("test", "showSidebar", {
        **context,
        country: "nl"
      })
    ).to be false
    expect(
      sdk.get_variable_boolean("test", "showSidebar", {
        **context,
        country: "de"
      })
    ).to be false

    expect(
      sdk.get_variable_string("test", "sidebarTitle", {
        userId: "user-forced-variation",
        country: "de"
      })
    ).to eq("German title")
    expect(
      sdk.get_variable_string("test", "sidebarTitle", {
        userId: "user-forced-variation",
        country: "nl"
      })
    ).to eq("Dutch title")
    expect(
      sdk.get_variable_string("test", "sidebarTitle", {
        userId: "user-forced-variation",
        country: "be"
      })
    ).to eq("sidebar title from variation")

    expect(sdk.get_variable("test", "count", context)).to eq(0)
    expect(sdk.get_variable_integer("test", "count", context)).to eq(0)

    expect(sdk.get_variable("test", "price", context)).to eq(9.99)
    expect(sdk.get_variable_double("test", "price", context)).to eq(9.99)

    expect(sdk.get_variable("test", "paymentMethods", context)).to eq(["paypal", "creditcard"])
    expect(sdk.get_variable_array("test", "paymentMethods", context)).to eq([
      "paypal",
      "creditcard"
    ])

    expect(sdk.get_variable("test", "flatConfig", context)).to eq({
      key: "value"
    })
    expect(sdk.get_variable_object("test", "flatConfig", context)).to eq({
      key: "value"
    })

    expect(sdk.get_variable("test", "nestedConfig", context)).to eq({
      key: {
        nested: "value"
      }
    })
    expect(sdk.get_variable_json("test", "nestedConfig", context)).to eq({
      key: {
        nested: "value"
      }
    })

    # non existing
    expect(sdk.get_variable("test", "nonExisting", context)).to be_nil
    expect(sdk.get_variable("nonExistingFeature", "nonExisting", context)).to be_nil

    # disabled
    expect(sdk.get_variable("test", "color", { userId: "user-gb" })).to be_nil
  end

  it "should get variables without any variations" do
    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
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
          }
        },
        features: {
          test: {
            key: "test",
            bucketBy: "userId",
            variablesSchema: {
              color: {
                key: "color",
                type: "string",
                defaultValue: "red"
              }
            },
            traffic: [
              {
                key: "1",
                segments: "netherlands",
                percentage: 100_000,
                variables: {
                  color: "orange"
                },
                allocation: []
              },
              {
                key: "2",
                segments: "*",
                percentage: 100_000,
                allocation: []
              }
            ]
          }
        }
      }
    )

    default_context = {
      userId: "123"
    }

    # test default value
    expect(
      sdk.get_variable("test", "color", {
        **default_context
      })
    ).to eq("red")

    # test override
    expect(
      sdk.get_variable("test", "color", {
        **default_context,
        country: "nl"
      })
    ).to eq("orange")
  end

  it "should check if enabled for individually named segments" do
    sdk = Featurevisor.create_instance(
      datafile: {
        schemaVersion: "2",
        revision: "1.0",
        features: {
          test: {
            key: "test",
            bucketBy: "userId",
            traffic: [
              { key: "1", segments: "netherlands", percentage: 100_000, allocation: [] },
              {
                key: "2",
                segments: JSON.generate(["iphone", "unitedStates"]),
                percentage: 100_000,
                allocation: []
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
          iphone: {
            key: "iphone",
            conditions: JSON.generate([
              {
                attribute: "device",
                operator: "equals",
                value: "iphone"
              }
            ])
          },
          unitedStates: {
            key: "unitedStates",
            conditions: JSON.generate([
              {
                attribute: "country",
                operator: "equals",
                value: "us"
              }
            ])
          }
        }
      }
    )

    expect(sdk.is_enabled("test")).to be false
    expect(sdk.is_enabled("test", { userId: "123" })).to be false
    expect(sdk.is_enabled("test", { userId: "123", country: "de" })).to be false
    expect(sdk.is_enabled("test", { userId: "123", country: "us" })).to be false

    expect(sdk.is_enabled("test", { userId: "123", country: "nl" })).to be true
    expect(sdk.is_enabled("test", { userId: "123", country: "us", device: "iphone" })).to be true
  end

  it "should handle JSON string datafile with automatic parsing" do
    json_datafile = '{
      "schemaVersion": "2",
      "revision": "1.0",
      "features": {
        "test": {
          "key": "test",
          "bucketBy": "userId",
          "variations": [
            { "value": "control" },
            { "value": "treatment" }
          ],
          "traffic": [
            {
              "key": "1",
              "segments": "*",
              "percentage": 100000,
              "allocation": [
                { "variation": "control", "range": [0, 100000] },
                { "variation": "treatment", "range": [0, 0] }
              ]
            }
          ]
        }
      },
      "segments": {}
    }'

    sdk = Featurevisor.create_instance(datafile: json_datafile)

    expect(sdk.get_revision).to eq("1.0")
    expect(sdk.get_feature("test")).to be_a(Hash)
    expect(sdk.get_feature("test")[:key]).to eq("test")
    expect(sdk.get_feature("test")[:bucketBy]).to eq("userId")
    expect(sdk.is_enabled("test", { userId: "123" })).to be true
    expect(sdk.get_variation("test", { userId: "123" })).to eq("control")
  end

  it "should handle JSON string when setting datafile" do
    sdk = Featurevisor.create_instance

    json_datafile = '{
      "schemaVersion": "2",
      "revision": "2.0",
      "features": {
        "newFeature": {
          "key": "newFeature",
          "bucketBy": "userId",
          "traffic": [
            {
              "key": "1",
              "segments": "*",
              "percentage": 100000,
              "allocation": []
            }
          ]
        }
      },
      "segments": {}
    }'

    sdk.set_datafile(json_datafile)

    expect(sdk.get_revision).to eq("2.0")
    expect(sdk.get_feature("newFeature")).to be_a(Hash)
    expect(sdk.get_feature("newFeature")[:key]).to eq("newFeature")
    expect(sdk.get_feature("newFeature")[:bucketBy]).to eq("userId")
    expect(sdk.is_enabled("newFeature", { userId: "123" })).to be true
  end

  it "should work with manually parsed JSON using symbolize_names: true" do
    json_string = '{
      "schemaVersion": "2",
      "revision": "3.0",
      "features": {
        "manualTest": {
          "key": "manualTest",
          "bucketBy": "userId",
          "traffic": [
            {
              "key": "1",
              "segments": "*",
              "percentage": 100000,
              "allocation": []
            }
          ]
        }
      },
      "segments": {}
    }'

    # Parse with symbolize_names: true as documented
    datafile = JSON.parse(json_string, symbolize_names: true)
    sdk = Featurevisor.create_instance(datafile: datafile)

    expect(sdk.get_revision).to eq("3.0")
    expect(sdk.get_feature("manualTest")).to be_a(Hash)
    expect(sdk.get_feature("manualTest")[:key]).to eq("manualTest")
    expect(sdk.is_enabled("manualTest", { userId: "123" })).to be true
  end
end
