require "json"
require "find"
require "open3"

module FeaturevisorCLI
  module Commands
    class Test
      def self.run(options)
        new(options).run
      end

      def initialize(options)
        @options = options
        @project_path = options.project_directory_path
      end

      def run
        puts "Running tests..."

        # Get project configuration
        config = get_config
        environments = config[:environments] || []
        segments_by_key = get_segments

        # Use CLI schemaVersion option or fallback to config
        schema_version = @options.schema_version
        if schema_version.nil? || schema_version.empty?
          schema_version = config[:schemaVersion]
        end

        # Build datafiles for all environments
        datafiles_by_environment = build_datafiles(environments, schema_version, @options.inflate)

        puts ""

        # Get log level
        level = get_logger_level
        tests = get_tests

        if tests.empty?
          puts "No tests found"
          return
        end

        # Create SDK instances for each environment
        sdk_instances_by_environment = create_sdk_instances(environments, datafiles_by_environment, level)

        # Run tests
        run_tests(tests, sdk_instances_by_environment, datafiles_by_environment, segments_by_key, level)
      end

      private

      def get_config
        puts "Getting config..."
        command = "(cd #{@project_path} && npx featurevisor config --json)"
        config_output = execute_command(command)

        begin
          JSON.parse(config_output, symbolize_names: true)
        rescue JSON::ParserError => e
          puts "Error: Failed to parse config JSON: #{e.message}"
          puts "Command output: #{config_output}"
          exit 1
        end
      end

      def get_segments
        puts "Getting segments..."
        command = "(cd #{@project_path} && npx featurevisor list --segments --json)"
        segments_output = execute_command(command)

        begin
          segments = JSON.parse(segments_output, symbolize_names: true)
          segments_by_key = {}
          segments.each do |segment|
            if segment[:key]
              segments_by_key[segment[:key]] = segment
            end
          end
          segments_by_key
        rescue JSON::ParserError => e
          puts "Error: Failed to parse segments JSON: #{e.message}"
          puts "Command output: #{segments_output}"
          exit 1
        end
      end

      def build_datafiles(environments, schema_version, inflate)
        datafiles_by_environment = {}

        environments.each do |environment|
          puts "Building datafile for environment: #{environment}..."

          command_parts = ["cd", @project_path, "&&", "npx", "featurevisor", "build", "--environment=#{environment}", "--json"]

          if schema_version && !schema_version.empty?
            command_parts = ["cd", @project_path, "&&", "npx", "featurevisor", "build", "--environment=#{environment}", "--schemaVersion=#{schema_version}", "--json"]
          end

          if inflate && inflate > 0
            if schema_version && !schema_version.empty?
              command_parts = ["cd", @project_path, "&&", "npx", "featurevisor", "build", "--environment=#{environment}", "--schemaVersion=#{schema_version}", "--inflate=#{inflate}", "--json"]
            else
              command_parts = ["cd", @project_path, "&&", "npx", "featurevisor", "build", "--environment=#{environment}", "--inflate=#{inflate}", "--json"]
            end
          end

          command = command_parts.join(" ")
          datafile_output = execute_command(command)

          begin
            datafile = JSON.parse(datafile_output, symbolize_names: true)
            datafiles_by_environment[environment] = datafile
          rescue JSON::ParserError => e
            puts "Error: Failed to parse datafile JSON for #{environment}: #{e.message}"
            puts "Command output: #{datafile_output}"
            exit 1
          end
        end

        datafiles_by_environment
      end

      def get_logger_level
        if @options.verbose
          "debug"
        elsif @options.quiet
          "error"
        else
          "warn"
        end
      end

      def get_tests
        command_parts = ["cd", @project_path, "&&", "npx", "featurevisor", "list", "--tests", "--applyMatrix", "--json"]

        if @options.key_pattern && !@options.key_pattern.empty?
          command_parts << "--keyPattern=#{@options.key_pattern}"
        end

        if @options.assertion_pattern && !@options.assertion_pattern.empty?
          command_parts << "--assertionPattern=#{@options.assertion_pattern}"
        end

        command = command_parts.join(" ")
        tests_output = execute_command(command)

        begin
          JSON.parse(tests_output, symbolize_names: true)
        rescue JSON::ParserError => e
          puts "Error: Failed to parse tests JSON: #{e.message}"
          puts "Command output: #{tests_output}"
          exit 1
        end
      end

      def create_sdk_instances(environments, datafiles_by_environment, level)
        sdk_instances_by_environment = {}

        environments.each do |environment|
          datafile = datafiles_by_environment[environment]

          # Create SDK instance
          instance = Featurevisor.create_instance(
            datafile: datafile,
            log_level: level,
            hooks: [
              {
                name: "tester-hook",
                bucket_value: ->(options) { options.bucket_value }
              }
            ]
          )

          sdk_instances_by_environment[environment] = instance
        end

        sdk_instances_by_environment
      end

      def run_tests(tests, sdk_instances_by_environment, datafiles_by_environment, segments_by_key, level)
        passed_tests_count = 0
        failed_tests_count = 0
        passed_assertions_count = 0
        failed_assertions_count = 0

        tests.each do |test|
          test_key = test[:key]
          assertions = test[:assertions] || []
          results = ""
          test_has_error = false
          test_duration = 0.0

          assertions.each do |assertion|
            if assertion.is_a?(Hash)
              test_result = nil

              if test[:feature]
                environment = assertion[:environment]
                instance = sdk_instances_by_environment[environment]

                # Show datafile if requested
                if @options.show_datafile
                  datafile = datafiles_by_environment[environment]
                  puts ""
                  puts JSON.pretty_generate(datafile)
                  puts ""
                end

                # If "at" parameter is provided, create a new instance with the specific hook
                if assertion[:at]
                  datafile = datafiles_by_environment[environment]

                  instance = Featurevisor.create_instance(
                    datafile: datafile,
                    log_level: level,
                    hooks: [
                      {
                        name: "tester-hook",
                        bucket_value: ->(options) do
                          # Match JavaScript implementation: assertion.at * (MAX_BUCKETED_NUMBER / 100)
                          # MAX_BUCKETED_NUMBER is 100000, so this becomes assertion.at * 1000
                          at = assertion[:at]
                          if at.is_a?(Numeric)
                            (at * 1000).to_i
                          else
                            options.bucket_value
                          end
                        end
                      }
                    ]
                  )
                end

                test_result = run_test_feature(assertion, test[:feature], instance, level)
              elsif test[:segment]
                segment_key = test[:segment]
                segment = segments_by_key[segment_key]
                if segment.is_a?(Hash)
                  test_result = run_test_segment(assertion, segment, level)
                end
              end

              if test_result
                test_duration += test_result[:duration]

                if test_result[:has_error]
                  results += "  ✘ #{assertion['description']} (#{(test_result[:duration] * 1000).round(2)}ms)\n"
                  results += test_result[:errors]
                  test_has_error = true
                  failed_assertions_count += 1
                else
                  results += "  ✔ #{assertion['description']} (#{(test_result[:duration] * 1000).round(2)}ms)\n"
                  passed_assertions_count += 1
                end
              end
            end
          end

          if !@options.only_failures || (@options.only_failures && test_has_error)
            puts "\nTesting: #{test_key} (#{(test_duration * 1000).round(2)}ms)"
            print results
          end

          if test_has_error
            failed_tests_count += 1
          else
            passed_tests_count += 1
          end
        end

        puts ""
        puts "Test specs: #{passed_tests_count} passed, #{failed_tests_count} failed"
        puts "Assertions: #{passed_assertions_count} passed, #{failed_assertions_count} failed"
        puts ""

        if failed_tests_count > 0
          exit 1
        end
      end

      def run_test_feature(assertion, feature_key, instance, level)
        context = parse_context(assertion[:context])
        sticky = parse_sticky(assertion[:sticky])

        # Set context and sticky for this assertion
        instance.set_context(context, false)
        if sticky && !sticky.empty?
          instance.set_sticky(sticky, false)
        end

        # Create override options
        override_options = create_override_options(assertion)

        has_error = false
        errors = ""
        start_time = Time.now

        # Test expectedToBeEnabled
        if assertion.key?(:expectedToBeEnabled)
          expected_to_be_enabled = assertion[:expectedToBeEnabled]
          is_enabled = instance.is_enabled(feature_key, context, override_options)

          if is_enabled != expected_to_be_enabled
            has_error = true
            errors += "      ✘ expectedToBeEnabled: expected #{expected_to_be_enabled} but received #{is_enabled}\n"
          end
        end

        # Test expectedVariation
        if assertion.key?(:expectedVariation)
          expected_variation = assertion[:expectedVariation]
          variation = instance.get_variation(feature_key, context, override_options)

          variation_value = variation.nil? ? nil : variation
          if !compare_values(variation_value, expected_variation)
            has_error = true
            errors += "      ✘ expectedVariation: expected #{expected_variation} but received #{variation_value}\n"
          end
        end

        # Test expectedVariables
        if assertion[:expectedVariables]
          expected_variables = assertion[:expectedVariables]
          expected_variables.each do |variable_key, expected_value|
            # Set default variable value for this specific variable
            if assertion[:defaultVariableValues] && assertion[:defaultVariableValues][variable_key]
              override_options[:default_variable_value] = assertion[:defaultVariableValues][variable_key]
            end

            actual_value = instance.get_variable(feature_key, variable_key, context, override_options)

            # Check if this is a JSON-type variable
            passed = false
            if expected_value.is_a?(String) && !expected_value.empty? && (expected_value[0] == '{' || expected_value[0] == '[')
              begin
                parsed_expected_value = JSON.parse(expected_value)

                if actual_value.is_a?(Hash)
                  passed = compare_maps(parsed_expected_value, actual_value)
                elsif actual_value.is_a?(Array)
                  passed = compare_arrays(parsed_expected_value, actual_value)
                else
                  passed = compare_values(actual_value, parsed_expected_value)
                end

                if !passed
                  has_error = true
                  actual_json = actual_value.to_json
                  errors += "      ✘ expectedVariables.#{variable_key}: expected #{expected_value} but received #{actual_json}\n"
                end
                next
              rescue JSON::ParserError
                # Fall through to regular comparison
              end
            end

            # Regular comparison for non-JSON strings or when JSON parsing fails
            if !compare_values(actual_value, expected_value)
              has_error = true
              errors += "      ✘ expectedVariables.#{variable_key}: expected #{expected_value} but received #{actual_value}\n"
            end
          end
        end

        # Test expectedEvaluations
        if assertion[:expectedEvaluations]
          expected_evaluations = assertion[:expectedEvaluations]

          # Test flag evaluations
          if expected_evaluations[:flag]
            evaluation = instance.evaluate_flag(feature_key, context, override_options)
            expected_evaluations[:flag].each do |key, expected_value|
              actual_value = get_evaluation_value(evaluation, key)
              if !compare_values(actual_value, expected_value)
                has_error = true
                errors += "      ✘ expectedEvaluations.flag.#{key}: expected #{expected_value} but received #{actual_value}\n"
              end
            end
          end

          # Test variation evaluations
          if expected_evaluations[:variation]
            evaluation = instance.evaluate_variation(feature_key, context, override_options)
            expected_evaluations[:variation].each do |key, expected_value|
              actual_value = get_evaluation_value(evaluation, key)
              if !compare_values(actual_value, expected_value)
                has_error = true
                errors += "      ✘ expectedEvaluations.variation.#{key}: expected #{expected_value} but received #{actual_value}\n"
              end
            end
          end

          # Test variable evaluations
          if expected_evaluations[:variables]
            expected_evaluations[:variables].each do |variable_key, expected_eval|
              if expected_eval.is_a?(Hash)
                evaluation = instance.evaluate_variable(feature_key, variable_key, context, override_options)
                expected_eval.each do |key, expected_value|
                  actual_value = get_evaluation_value(evaluation, key)
                  if !compare_values(actual_value, expected_value)
                    has_error = true
                    errors += "      ✘ expectedEvaluations.variables.#{variable_key}.#{key}: expected #{expected_value} but received #{actual_value}\n"
                  end
                end
              end
            end
          end
        end

        # Test children
        if assertion[:children]
          assertion[:children].each do |child|
            if child.is_a?(Hash)
              child_context = parse_context(child[:context])

              # Create override options for child with sticky values
              child_override_options = create_override_options(child)

              # Pass sticky values to child instance
              child_instance = instance.spawn(child_context, child_override_options)

              # Set sticky values for child if they exist
              # Create a local copy to ensure it's never nil
              child_sticky = sticky || {}
              if !child_sticky.empty?
                child_instance.set_sticky(child_sticky, false)
              end

              child_result = run_test_feature_child(child, feature_key, child_instance, level)

              if child_result[:has_error]
                has_error = true
                errors += child_result[:errors]
              end
            end
          end
        end

        duration = Time.now - start_time

        {
          has_error: has_error,
          errors: errors,
          duration: duration
        }
      end

      def run_test_feature_child(assertion, feature_key, instance, level)
        context = parse_context(assertion["context"])
        override_options = create_override_options(assertion)

        has_error = false
        errors = ""
        start_time = Time.now

        # Test expectedToBeEnabled
        if assertion.key?(:expectedToBeEnabled)
          expected_to_be_enabled = assertion[:expectedToBeEnabled]
          is_enabled = instance.is_enabled(feature_key, context, override_options)

          if is_enabled != expected_to_be_enabled
            has_error = true
            errors += "      ✘ expectedToBeEnabled: expected #{expected_to_be_enabled} but received #{is_enabled}\n"
          end
        end

        # Test expectedVariation
        if assertion.key?(:expectedVariation)
          expected_variation = assertion[:expectedVariation]
          variation = instance.get_variation(feature_key, context, override_options)

          variation_value = variation.nil? ? nil : variation
          if !compare_values(variation_value, expected_variation)
            has_error = true
            errors += "      ✘ expectedVariation: expected #{expected_variation} but received #{variation_value}\n"
          end
        end

        # Test expectedVariables
        if assertion[:expectedVariables]
          expected_variables = assertion[:expectedVariables]
          expected_variables.each do |variable_key, expected_value|
            # Set default variable value for this specific variable
            if assertion[:defaultVariableValues] && assertion[:defaultVariableValues][variable_key]
              override_options[:default_variable_value] = assertion[:defaultVariableValues][variable_key]
            end

            actual_value = instance.get_variable(feature_key, variable_key, context, override_options)

            # Check if this is a JSON-type variable
            passed = false
            if expected_value.is_a?(String) && !expected_value.empty? && (expected_value[0] == '{' || expected_value[0] == '[')
              begin
                parsed_expected_value = JSON.parse(expected_value)

                if actual_value.is_a?(Hash)
                  passed = compare_maps(parsed_expected_value, actual_value)
                elsif actual_value.is_a?(Array)
                  passed = compare_arrays(parsed_expected_value, actual_value)
                else
                  passed = compare_values(actual_value, parsed_expected_value)
                end

                if !passed
                  has_error = true
                  actual_json = actual_value.to_json
                  errors += "      ✘ expectedVariables.#{variable_key}: expected #{expected_value} but received #{actual_json}\n"
                end
                next
              rescue JSON::ParserError
                # Fall through to regular comparison
              end
            end

            # Regular comparison for non-JSON strings or when JSON parsing fails
            if !compare_values(actual_value, expected_value)
              has_error = true
              errors += "      ✘ expectedVariables.#{variable_key}: expected #{expected_value} but received #{actual_value}\n"
            end
          end
        end

        duration = Time.now - start_time

        {
          has_error: has_error,
          errors: errors,
          duration: duration
        }
      end

      def run_test_segment(assertion, segment, level)
        context = parse_context(assertion[:context])
        conditions = segment[:conditions]

        # Create a minimal datafile for segment testing
        datafile = {
          schemaVersion: "2",
          revision: "tester",
          features: {},
          segments: {}
        }

        # Create SDK instance for segment testing
        instance = Featurevisor.create_instance(
          datafile: datafile,
          log_level: level
        )

        has_error = false
        errors = ""
        start_time = Time.now

        if assertion.key?(:expectedToMatch)
          expected_to_match = assertion[:expectedToMatch]
          actual = instance.instance_variable_get(:@datafile_reader).all_conditions_are_matched(conditions, context)

          if actual != expected_to_match
            has_error = true
            errors += "      ✘ expectedToMatch: expected #{expected_to_match} but received #{actual}\n"
          end
        end

        duration = Time.now - start_time

        {
          has_error: has_error,
          errors: errors,
          duration: duration
        }
      end

      def parse_context(context_data)
        if context_data && context_data.is_a?(Hash)
          # Convert string keys to symbols for the SDK
          context_data.transform_keys(&:to_sym)
        else
          {}
        end
      end

      def parse_sticky(sticky_data)
        if sticky_data && sticky_data.is_a?(Hash)
          sticky_features = {}

          sticky_data.each do |key, value|
            if value.is_a?(Hash)
              evaluated_feature = {}

              if value.key?(:enabled)
                evaluated_feature[:enabled] = value[:enabled]
              end

              if value.key?(:variation)
                evaluated_feature[:variation] = value[:variation]
              end

              if value[:variables] && value[:variables].is_a?(Hash)
                evaluated_feature[:variables] = value[:variables].transform_keys(&:to_sym)
              end

              sticky_features[key.to_sym] = evaluated_feature
            end
          end

          sticky_features
        else
          {}
        end
      end

      def create_override_options(assertion)
        options = {}

        if assertion[:defaultVariationValue]
          options[:default_variation_value] = assertion[:defaultVariationValue]
        end

        options
      end

      def get_evaluation_value(evaluation, key)
        case key
        when "type"
          evaluation[:type]
        when "featureKey"
          evaluation[:feature_key]
        when "reason"
          evaluation[:reason]
        when "bucketKey"
          evaluation[:bucket_key]
        when "bucketValue"
          evaluation[:bucket_value]
        when "ruleKey"
          evaluation[:rule_key]
        when "error"
          evaluation[:error]
        when "enabled"
          evaluation[:enabled]
        when "traffic"
          evaluation[:traffic]
        when "forceIndex"
          evaluation[:force_index]
        when "force"
          evaluation[:force]
        when "required"
          evaluation[:required]
        when "sticky"
          evaluation[:sticky]
        when "variation"
          evaluation[:variation]
        when "variationValue"
          evaluation[:variation_value]
        when "variableKey"
          evaluation[:variable_key]
        when "variableValue"
          evaluation[:variable_value]
        when "variableSchema"
          evaluation[:variable_schema]
        else
          nil
        end
      end

      def compare_values(actual, expected)
        # Handle nil cases
        if actual.nil? && expected.nil?
          return true
        end
        if actual.nil? || expected.nil?
          return false
        end

        # Handle empty string vs nil for variation values
        if actual.is_a?(String) && actual.empty? && expected.nil?
          return true
        end
        if expected.is_a?(String) && expected.empty? && actual.nil?
          return true
        end

        # Handle numeric type conversions
        if actual.is_a?(Integer) && expected.is_a?(Float)
          return actual.to_f == expected
        end
        if actual.is_a?(Float) && expected.is_a?(Integer)
          return actual == expected.to_f
        end

        # Handle JSON string comparison
        if expected.is_a?(String) && actual.is_a?(Hash)
          if !expected.empty? && (expected[0] == '{' || expected[0] == '[')
            begin
              actual_json = actual.to_json
              expected_normalized = expected.gsub(/\s/, '')
              actual_normalized = actual_json.gsub(/\s/, '')
              return expected_normalized == actual_normalized
            rescue
              # Fall through to regular comparison
            end
          end
        end

        # Handle hash comparison with key normalization
        if actual.is_a?(Hash) && expected.is_a?(Hash)
          return compare_maps(actual, expected)
        end

        # Handle array comparison
        if actual.is_a?(Array) && expected.is_a?(Array)
          return compare_arrays(actual, expected)
        end

        # For other types, use direct comparison
        if [String, TrueClass, FalseClass, Integer, Float].any? { |type| actual.is_a?(type) }
          return actual == expected
        end

        # For uncomparable types, return false
        false
      end

      def compare_arrays(a, b)
        return false if a.length != b.length

        a.each_with_index do |v, i|
          return false unless compare_values(v, b[i])
        end

        true
      end

      def compare_maps(a, b)
        return false if a.length != b.length

        # Normalize keys for comparison (convert symbols to strings)
        a_normalized = normalize_hash_keys(a)
        b_normalized = normalize_hash_keys(b)

        a_normalized.each do |k, v|
          return false unless b_normalized.key?(k) && compare_values(v, b_normalized[k])
        end

        true
      end

      def normalize_hash_keys(obj)
        case obj
        when Hash
          normalized = {}
          obj.each do |k, v|
            normalized[k.to_s] = normalize_hash_keys(v)
          end
          normalized
        when Array
          obj.map { |v| normalize_hash_keys(v) }
        else
          obj
        end
      end



      def execute_command(command)
        stdout, stderr, status = Open3.capture3(command)

        unless status.success?
          puts "Error: Command failed with exit code #{status.exitstatus}"
          puts "Command: #{command}"
          puts "Stderr: #{stderr}" unless stderr.empty?
          exit 1
        end

        stdout
      end
    end
  end
end
