require "featurevisor"

RSpec.describe Featurevisor::DatafileReader do
  let(:logger) { Featurevisor.create_logger }

  describe "basic functionality" do
    it "should be a class" do
      expect(Featurevisor::DatafileReader).to be_a(Class)
    end

    it "should create an instance with options" do
      datafile = { schemaVersion: "2", revision: "1", segments: {}, features: {} }
      reader = Featurevisor::DatafileReader.new(datafile: datafile, logger: logger)

      expect(reader).to be_instance_of(Featurevisor::DatafileReader)
    end
  end

  describe "v2 datafile schema" do
    let(:datafile_json) do
      {
        schemaVersion: "2",
        revision: "1",
        segments: {
          netherlands: {
            key: "netherlands",
            conditions: [
              {
                attribute: "country",
                operator: "equals",
                value: "nl"
              }
            ]
          },
          germany: {
            key: "germany",
            conditions: [
              {
                attribute: "country",
                operator: "equals",
                value: "de"
              }
            ].to_json
          }
        },
        features: {
          test: {
            key: "test",
            bucketBy: "userId",
            variations: [
              { value: "control" },
              {
                value: "treatment",
                variables: {
                  showSidebar: true
                }
              }
            ],
            traffic: [
              {
                key: "1",
                segments: "*",
                percentage: 100000,
                allocation: [
                  { variation: "control", range: [0, 0] },
                  { variation: "treatment", range: [0, 100000] }
                ]
              }
            ]
          }
        }
      }
    end

    let(:reader) { Featurevisor::DatafileReader.new(datafile: datafile_json, logger: logger) }

    it "should return requested entities" do
      expect(reader.get_revision).to eq("1")
      expect(reader.get_schema_version).to eq("2")
      expect(reader.get_segment("netherlands")).to eq(datafile_json[:segments][:netherlands])
      expect(reader.get_segment("belgium")).to be_nil
      expect(reader.get_feature("test")).to eq(datafile_json[:features][:test])
      expect(reader.get_feature("test2")).to be_nil
    end

    it "should parse stringified conditions" do
      segment = reader.get_segment("germany")
      expect(segment[:conditions]).to be_an(Array)
      expect(segment[:conditions][0]["value"]).to eq("de")
      expect(segment[:conditions][0]["attribute"]).to eq("country")
      expect(segment[:conditions][0]["operator"]).to eq("equals")
    end
  end

  describe "segments" do
    let(:groups) do
      [
        # everyone
        {
          key: "*",
          segments: "*"
        },

        # dutch
        {
          key: "dutchMobileUsers",
          segments: ["mobileUsers", "netherlands"]
        },
        {
          key: "dutchMobileUsers2",
          segments: {
            and: ["mobileUsers", "netherlands"]
          }
        },
        {
          key: "dutchMobileOrDesktopUsers",
          segments: ["netherlands", { or: ["mobileUsers", "desktopUsers"] }]
        },
        {
          key: "dutchMobileOrDesktopUsers2",
          segments: {
            and: ["netherlands", { or: ["mobileUsers", "desktopUsers"] }]
          }
        },

        # german
        {
          key: "germanMobileUsers",
          segments: [
            {
              and: ["mobileUsers", "germany"]
            }
          ]
        },
        {
          key: "germanNonMobileUsers",
          segments: [
            {
              and: [
                "germany",
                {
                  not: ["mobileUsers"]
                }
              ]
            }
          ]
        },

        # version
        {
          key: "notVersion5.5",
          segments: [
            {
              not: ["version_5.5"]
            }
          ]
        }
      ]
    end

    let(:datafile_content) do
      {
        schemaVersion: "2",
        revision: "1",
        features: {},

        segments: {
          # deviceType
          mobileUsers: {
            key: "mobileUsers",
            conditions: [
              {
                attribute: "deviceType",
                operator: "equals",
                value: "mobile"
              }
            ]
          },
          desktopUsers: {
            key: "desktopUsers",
            conditions: [
              {
                attribute: "deviceType",
                operator: "equals",
                value: "desktop"
              }
            ]
          },

          # browser
          chromeBrowser: {
            key: "chromeBrowser",
            conditions: [
              {
                attribute: "browser",
                operator: "equals",
                value: "chrome"
              }
            ]
          },
          firefoxBrowser: {
            key: "firefoxBrowser",
            conditions: [
              {
                attribute: "browser",
                operator: "equals",
                value: "firefox"
              }
            ]
          },

          # country
          netherlands: {
            key: "netherlands",
            conditions: [
              {
                attribute: "country",
                operator: "equals",
                value: "nl"
              }
            ]
          },
          germany: {
            key: "germany",
            conditions: [
              {
                attribute: "country",
                operator: "equals",
                value: "de"
              }
            ]
          },

          # version
          "version_5.5": {
            key: "version_5.5",
            conditions: [
              {
                or: [
                  {
                    attribute: "version",
                    operator: "equals",
                    value: "5.5"
                  },
                  {
                    attribute: "version",
                    operator: "equals",
                    value: 5.5
                  }
                ]
              }
            ]
          }
        }
      }
    end

    let(:datafile_reader) { Featurevisor::DatafileReader.new(datafile: datafile_content, logger: logger) }

    it "should match everyone" do
      group = groups.find { |g| g[:key] == "*" }

      # match
      expect(datafile_reader.all_segments_are_matched(group[:segments], {})).to be true
      expect(datafile_reader.all_segments_are_matched(group[:segments], { foo: "foo" })).to be true
      expect(datafile_reader.all_segments_are_matched(group[:segments], { bar: "bar" })).to be true
    end

    it "should match dutchMobileUsers" do
      group = groups.find { |g| g[:key] == "dutchMobileUsers" }

      # match
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "nl",
          deviceType: "mobile"
        })
      ).to be true

      # not match
      expect(datafile_reader.all_segments_are_matched(group[:segments], {})).to be false
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "de",
          deviceType: "mobile"
        })
      ).to be false
    end

    it "should match dutchMobileUsers2" do
      group = groups.find { |g| g[:key] == "dutchMobileUsers2" }

      # match
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "nl",
          deviceType: "mobile"
        })
      ).to be true

      # not match
      expect(datafile_reader.all_segments_are_matched(group[:segments], {})).to be false
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "de",
          deviceType: "mobile"
        })
      ).to be false
    end

    it "should match dutchMobileOrDesktopUsers" do
      group = groups.find { |g| g[:key] == "dutchMobileOrDesktopUsers" }

      # match
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "nl",
          deviceType: "mobile"
        })
      ).to be true
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "nl",
          deviceType: "desktop"
        })
      ).to be true

      # not match
      expect(datafile_reader.all_segments_are_matched(group[:segments], {})).to be false
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "de",
          deviceType: "mobile"
        })
      ).to be false
    end

    it "should match germanMobileUsers" do
      group = groups.find { |g| g[:key] == "germanMobileUsers" }

      # match
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "de",
          deviceType: "mobile"
        })
      ).to be true

      # not match
      expect(datafile_reader.all_segments_are_matched(group[:segments], {})).to be false
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "nl",
          deviceType: "mobile"
        })
      ).to be false
    end

    it "should match germanNonMobileUsers" do
      group = groups.find { |g| g[:key] == "germanNonMobileUsers" }

      # match
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "de",
          deviceType: "desktop"
        })
      ).to be true

      # not match
      expect(datafile_reader.all_segments_are_matched(group[:segments], {})).to be false
      expect(
        datafile_reader.all_segments_are_matched(group[:segments], {
          country: "nl",
          deviceType: "desktop"
        })
      ).to be false
    end

    it "should match notVersion5.5" do
      group = groups.find { |g| g[:key] == "notVersion5.5" }

      # match
      expect(datafile_reader.all_segments_are_matched(group[:segments], {})).to be true
      expect(datafile_reader.all_segments_are_matched(group[:segments], { version: "5.6" })).to be true
      expect(datafile_reader.all_segments_are_matched(group[:segments], { version: 5.6 })).to be true

      # not match
      expect(datafile_reader.all_segments_are_matched(group[:segments], { version: "5.5" })).to be false
      expect(datafile_reader.all_segments_are_matched(group[:segments], { version: 5.5 })).to be false
    end
  end

  describe "conditions" do
    let(:datafile_reader) do
      Featurevisor::DatafileReader.new(
        datafile: {
          schemaVersion: "2.0",
          revision: "1",
          segments: {},
          features: {}
        },
        logger: logger
      )
    end

    it "should match all via *" do
      conditions = "*"
      expect(datafile_reader.all_conditions_are_matched(conditions, { browser_type: "chrome" })).to be true

      conditions2 = "blah"
      expect(datafile_reader.all_conditions_are_matched(conditions2, { browser_type: "chrome" })).to be false
    end

    describe "simple conditions" do
      it "should match with exact single condition" do
        conditions = [
          {
            attribute: "browser_type",
            operator: "equals",
            value: "chrome"
          }
        ]

        expect(
          datafile_reader.all_conditions_are_matched(conditions[0], {
            browser_type: "chrome"
          })
        ).to be true
      end

      it "should match with exact condition" do
        conditions = [
          {
            attribute: "browser_type",
            operator: "equals",
            value: "chrome"
          }
        ]

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "chrome"
          })
        ).to be true
      end

      it "should match with empty conditions" do
        conditions = []

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "chrome"
          })
        ).to be true
      end

      it "should match with multiple conditions" do
        conditions = [
          {
            attribute: "browser_type",
            operator: "equals",
            value: "chrome"
          },
          {
            attribute: "browser_version",
            operator: "equals",
            value: "1.0"
          }
        ]

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "chrome",
            browser_version: "1.0"
          })
        ).to be true
      end
    end

    describe "AND conditions" do
      it "should match with one AND condition" do
        conditions = [
          {
            and: [
              {
                attribute: "browser_type",
                operator: "equals",
                value: "chrome"
              }
            ]
          }
        ]

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "chrome"
          })
        ).to be true

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "firefox"
          })
        ).to be false
      end

      it "should match with multiple conditions inside AND" do
        conditions = [
          {
            and: [
              {
                attribute: "browser_type",
                operator: "equals",
                value: "chrome"
              },
              {
                attribute: "browser_version",
                operator: "equals",
                value: "1.0"
              }
            ]
          }
        ]

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "chrome",
            browser_version: "1.0"
          })
        ).to be true

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "chrome"
          })
        ).to be false
      end
    end

    describe "OR conditions" do
      it "should match with one OR condition" do
        conditions = [
          {
            or: [
              {
                attribute: "browser_type",
                operator: "equals",
                value: "chrome"
              }
            ]
          }
        ]

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "chrome"
          })
        ).to be true
      end

      it "should match with multiple conditions inside OR" do
        conditions = [
          {
            or: [
              {
                attribute: "browser_type",
                operator: "equals",
                value: "chrome"
              },
              {
                attribute: "browser_version",
                operator: "equals",
                value: "1.0"
              }
            ]
          }
        ]

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_version: "1.0"
          })
        ).to be true

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "firefox"
          })
        ).to be false
      end
    end

    describe "NOT conditions" do
      it "should match with one NOT condition" do
        conditions = [
          {
            not: [
              {
                attribute: "browser_type",
                operator: "equals",
                value: "chrome"
              }
            ]
          }
        ]

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "firefox"
          })
        ).to be true

        expect(
          datafile_reader.all_conditions_are_matched(conditions, {
            browser_type: "chrome"
          })
        ).to be false
      end
    end
  end

  describe "utility methods" do
    let(:datafile_reader) do
      Featurevisor::DatafileReader.new(
        datafile: {
          schemaVersion: "2.0",
          revision: "1",
          segments: {},
          features: {}
        },
        logger: logger
      )
    end

    it "should get feature keys" do
      expect(datafile_reader.get_feature_keys).to eq([])
    end

    it "should get variable keys" do
      expect(datafile_reader.get_variable_keys("nonexistent")).to eq([])
    end

    it "should check variations" do
      expect(datafile_reader.has_variations?("nonexistent")).to be false
    end

    it "should get regex with caching" do
      regex1 = datafile_reader.get_regex("test", "")
      regex2 = datafile_reader.get_regex("test", "")

      expect(regex1).to eq(regex2)
      expect(datafile_reader.regex_cache.keys.length).to eq(1)
    end
  end
end
