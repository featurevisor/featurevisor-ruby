require "json"
require "find"
require "open3"
require "shellwords"
require_relative "../test_checks"
require_relative "../segment_tests"

module FeaturevisorCLI
  module Commands
    class Test
      class InfrastructureError < StandardError
        attr_reader :code

        def initialize(message, code: nil)
          super(message)
          @code = code
        end
      end

      def self.run(options)
        new(options).run
      end

      def initialize(options)
        @options = options
        @project_path = options.project_directory_path
        @coverage_selections = []
      end

      def run
        progress "Running tests..."
        root_config = get_config(nil)
        sets = selected_sets(root_config)
        report = empty_report
        report[:uncovered] = [] if @options.uncovered
        matched_case = @options.case_id.nil?

        sets.each do |set|
          @active_set = set
          config = get_config(set)
          report[:uncovered] << get_uncovered(set) if @options.uncovered
          begin
            tests = get_tests(set)
          rescue InfrastructureError => e
            if @options.case_id && !@options.set && e.code == "test_case_not_found"
              next
            end
            raise
          end
          matched_case = true
          environments = get_environments(config)
          available_targets = get_targets(set)
          unknown_target = @options.targets.find { |target| !available_targets.include?(target) }
          if unknown_target
            raise InfrastructureError,
                  "Unknown target #{unknown_target.inspect}. Available targets: #{available_targets.empty? ? 'none' : available_targets.join(', ')}."
          end
          targets = @options.targets.empty? ? available_targets : @options.targets
          segments_by_key = get_segments(set)
          datafiles_by_key = build_datafiles(environments, targets, @options.inflate, set)
          merge_report!(report, run_tests(tests, datafiles_by_key, segments_by_key, get_logger_level, config, set))
        end
        if @options.case_id && !matched_case
          raise InfrastructureError, "No test case matches --case and the selected filters"
        end

        report[:coverage] = coverage_report if @options.coverage
        finalize_report!(report)
        print_report(report)
        exit 1 unless report[:passed]
      rescue InfrastructureError => e
        report ||= empty_report
        report[:errors] << { message: e.message }
        finalize_report!(report)
        print_report(report)
        exit 1
      end

      private

      def get_config(set = @active_set)
        progress "Getting config#{set ? " for set #{set.inspect}" : ''}..."
        config_output = execute_command(node_command("config", "--json"))

        begin
          JSON.parse(config_output, symbolize_names: true)
        rescue JSON::ParserError => e
          raise InfrastructureError, "Failed to parse config JSON: #{e.message}"
        end
      end

      def get_segments(set = @active_set)
        progress "Getting segments..."
        segments_output = execute_command(node_command("list", "--segments", "--json", *set_arguments(set)))

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
          raise InfrastructureError, "Failed to parse segments JSON: #{e.message}"
        end
      end

      def get_targets(set = @active_set)
        progress "Getting targets..."
        targets_output = execute_command(node_command("list", "--targets", "--json", *set_arguments(set)))

        begin
          targets = JSON.parse(targets_output, symbolize_names: true)

          if targets.is_a?(Array)
            targets.filter_map do |target|
              if target.is_a?(Hash)
                target[:name] || target[:key]
              else
                target
              end
            end
          elsif targets.is_a?(Hash)
            targets.keys
          else
            []
          end
        rescue JSON::ParserError => e
          raise InfrastructureError, "Failed to parse targets JSON: #{e.message}"
        end
      end

      def selected_sets(config)
        return [@options.set] if @options.set
        return [nil] unless config[:sets]

        directory = config[:setsDirectoryPath] || "sets"
        path = File.expand_path(directory, @project_path)
        sets = Dir.children(path).select { |entry| File.directory?(File.join(path, entry)) }.sort
        raise InfrastructureError, "No sets found in #{directory}." if sets.empty?
        sets
      rescue SystemCallError => e
        raise InfrastructureError, "Failed to list project sets in #{directory}: #{e.message}"
      end

      def get_environments(config)
        environments = config[:environments]

        return [false] if environments == false
        return environments if environments.is_a?(Array) && !environments.empty?

        [false]
      end

      def base_datafile_key(environment)
        [environment == false ? nil : environment, nil].freeze
      end

      def target_datafile_key(environment, target)
        [environment == false ? nil : environment, target].freeze
      end

      def build_datafiles(environments, targets, inflate, set = @active_set)
        datafiles_by_key = {}

        environments.each do |environment|
          environment_label = environment == false ? "default (no environment)" : environment
          progress "Building datafile for environment: #{environment_label}..."

          datafiles_by_key[base_datafile_key(environment)] = build_single_datafile(
            environment: environment,
            inflate: inflate,
            set: set
          )

          targets.each do |target|
            progress "Building datafile for target: #{target}..."
            datafiles_by_key[target_datafile_key(environment, target)] = build_single_datafile(
              environment: environment,
              inflate: inflate,
              target: target,
              set: set
            )
          end
        end

        datafiles_by_key
      end

      def build_single_datafile(environment:, inflate:, target: nil, set: @active_set)
        arguments = ["build", "--json"]
        arguments << "--environment=#{environment}" if environment != false && !environment.nil?
        arguments << "--inflate=#{inflate}" if inflate && inflate > 0
        arguments << "--target=#{target}" if target
        datafile_output = execute_command(node_command(*arguments, *set_arguments(set)))

        begin
          JSON.parse(datafile_output, symbolize_names: true)
        rescue JSON::ParserError => e
          raise InfrastructureError, "Failed to parse datafile JSON: #{e.message}"
        end
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

      def get_tests(set = @active_set)
        arguments = ["list", "--tests", "--execution-protocol", "--json"]
        arguments << "--keyPattern=#{@options.key_pattern}" if @options.key_pattern && !@options.key_pattern.empty?
        if @options.assertion_pattern && !@options.assertion_pattern.empty?
          arguments << "--assertionPattern=#{@options.assertion_pattern}"
        end
        arguments << "--entityType=#{@options.entity_type}" if @options.entity_type && !@options.entity_type.empty?
        arguments << "--case=#{@options.case_id}" if @options.case_id
        tests_output = execute_command(node_command(*arguments, *set_arguments(set)))

        begin
          payload = JSON.parse(tests_output, symbolize_names: true)
          unless payload.is_a?(Hash)
            raise InfrastructureError, "Invalid test execution protocol: expected an envelope object"
          end
          unless payload[:kind] == "featurevisor.test-execution"
            raise InfrastructureError, 'Invalid test execution protocol: kind must be "featurevisor.test-execution"'
          end
          version = payload[:schemaVersion]
          unless version.is_a?(Numeric) && version == 1
            raise InfrastructureError, "Unsupported test execution protocol schemaVersion; expected numeric 1"
          end
          tests = payload[:tests]
          unless tests.is_a?(Array) && tests.all? { |test| test.is_a?(Hash) }
            raise InfrastructureError, "Invalid test execution protocol: tests must be an array of objects"
          end
          tests
        rescue JSON::ParserError => e
          raise InfrastructureError, "Failed to parse tests JSON: #{e.message}"
        end
      end

      def set_arguments(set = @active_set)
        set ? ["--set=#{set}"] : []
      end

      def node_command(*arguments)
        [*FeaturevisorCLI::NodeCli.command(@project_path), *arguments]
      end

      def resolve_datafile_for_assertion(assertion, datafiles_by_key)
        environment = assertion.key?(:environment) ? assertion[:environment] : false
        environment = false if environment.nil?

        return datafiles_by_key[target_datafile_key(environment, assertion[:target])] if assertion[:target]

        datafiles_by_key[base_datafile_key(environment)]
      end

      def create_tester_instance(datafile, level, assertion, set = @active_set)
        sticky = parse_sticky(assertion[:stickyFeatures])
        sticky_variables = assertion[:stickyVariables].is_a?(Hash) ? assertion[:stickyVariables] : {}

        diagnostics = []
        check_level = assertion.key?(:checks) || !Array(assertion[:children]).empty? ? "error" : level
        instance = Featurevisor.create_featurevisor(
          datafile: datafile,
          sticky_features: sticky,
          sticky_variables: sticky_variables,
          log_level: check_level,
          on_diagnostic: ->(diagnostic) { diagnostics << diagnostic },
          modules: [
            {
              name: "test-module",
              bucket_value: ->(options) do
                at = assertion[:at]
                if at.is_a?(Numeric)
                  (at * 1000).to_i
                else
                  options[:bucket_value]
                end
              end,
              after_evaluation: ->(evaluation, _evaluation_options) do
                record_coverage_selection(evaluation, assertion, set) if @options.coverage && !(datafile[:_segment_test_keys] || {}).value?(evaluation[:feature_key].to_s)
                evaluation
              end
            }
          ]
        )
        instance.instance_variable_set(:@__segment_test_keys, datafile[:_segment_test_keys] || {})
        instance.instance_variable_set(:@__segment_test_diagnostics, diagnostics)
        instance.on("error", ->(event) { diagnostics << event[:diagnostic] if event[:diagnostic] })
        [instance, diagnostics]
      end

      def run_tests(tests, datafiles_by_key, segments_by_key, level, _config, set)
        report = empty_report

        tests.each do |test|
          discriminators = %i[feature variable segment scenario].select { |key| test.key?(key) }
          type = discriminators.first
          invalid_discriminator = discriminators.length != 1
          assertions = test[:assertions] || []
          if invalid_discriminator
            assertions = [{ description: "malformed test spec", __invalid_discriminator: true }]
          elsif type == :scenario && assertions.empty?
            assertions = [{ description: "malformed scenario spec", __missing_assertions: true }]
          end
          if !invalid_discriminator && %i[feature variable scenario].include?(type) && !@options.targets.empty?
            assertions = assertions.select { |assertion| assertion[:target].nil? || @options.targets.include?(assertion[:target]) }
            next if assertions.empty?
          end

          result = {
            type: (type || :unknown).to_s,
            key: type ? test[type] : test[:key],
            source: test.dig(:_test, :source) || test[:key],
            set: test.dig(:_test, :set) || set,
            passed: true,
            cases: []
          }

          assertions.each do |assertion|
            next unless assertion.is_a?(Hash)
            test_result = execute_assertion(test, type, assertion, datafiles_by_key, segments_by_key, level, set)
            test_result ||= { has_error: true, errors: "      ✘ test assertion could not be evaluated\n", duration: 0 }
            errors = error_objects(test_result[:errors], type: type, assertion: assertion)
            case_result = {
              id: assertion.dig(:_case, :id),
              description: assertion[:description],
              environment: normalized_environment(assertion[:environment]),
              target: assertion[:target],
              context: assertion[:context].is_a?(Hash) ? assertion[:context] : {},
              matrixValues: assertion.dig(:_case, :matrixValues) || {},
              passed: !test_result[:has_error],
              errors: errors,
              rerun: rerun_instruction(assertion, result[:set])
            }
            result[:cases] << case_result
            result[:passed] = false unless case_result[:passed]
          end

          report[:results] << result
        end

        finalize_report!(report)
        report
      end

      def execute_assertion(test, type, assertion, datafiles_by_key, segments_by_key, level, set)
        if assertion[:__invalid_discriminator]
          return { has_error: true, errors: "      ✘ test spec requires exactly one of feature, variable, segment or scenario\n", duration: 0 }
        end

        datafile = resolve_datafile_for_assertion(assertion, datafiles_by_key)
        if type == :segment
          if !datafile && ((assertion[:environment].is_a?(String) && !assertion[:environment].empty?) || assertion[:target])
            return { has_error: true, errors: "      ✘ no datafile found for assertion target/environment combination\n", duration: 0 }
          end
          authored = test[:_segments].is_a?(Hash) ? test[:_segments] : segments_by_key
          return run_test_segment(assertion, authored[test[:segment].to_sym] || authored[test[:segment]], level, datafile, authored, test[:segment], set)
        end
        return { has_error: true, errors: "      ✘ no datafile found for assertion target/environment combination\n", duration: 0 } unless datafile

        authored_segments = test[:_segments].is_a?(Hash) ? test[:_segments] : {}
        preflight_details = {}
        begin
          preflight_assertion!(test, assertion, datafile, authored_segments, preflight_details)
        rescue FeaturevisorCLI::TestChecks::CheckError => e
          error = FeaturevisorCLI::TestChecks.comparison_error(
            e.message, "valid checks", e.message, **preflight_details
          )
          return { has_error: true, errors: [error], duration: 0 }
        end

        datafile = SegmentTests.prepare(datafile, authored_segments)
        progress JSON.pretty_generate(datafile) if @options.show_datafile
        instance, diagnostics = create_tester_instance(datafile, level, assertion, set)
        begin
          return run_test_feature(assertion, test[:feature], instance, level) if type == :feature
          return run_test_variable(assertion, test[:variable], instance, datafile, diagnostics, authored_segments) if type == :variable
          return run_test_scenario(assertion, instance, datafile, diagnostics, authored_segments) if type == :scenario
        ensure
          instance.close
        end
      end

      def preflight_assertion!(test, assertion, datafile, segments, details = {})
        if test[:feature]
          feature = FeaturevisorCLI::TestChecks.keyed(FeaturevisorCLI::TestChecks.keyed(datafile, :features), test[:feature])
          variables = FeaturevisorCLI::TestChecks.keyed(feature, :variablesSchema)
          [assertion, *Array(assertion[:children])].each do |current|
            next unless current.is_a?(Hash)
            (current[:expectedVariables] || {}).each_key do |variable|
              unless FeaturevisorCLI::TestChecks.keyed(variables, variable)
                raise FeaturevisorCLI::TestChecks::CheckError,
                      "variable #{variable.inspect} is absent from feature #{test[:feature].inspect} in the selected datafile"
              end
            end
          end
        end
        owner = test[:variable]
        FeaturevisorCLI::TestChecks.preflight!(datafile, assertion[:checks], owner_variable: owner, segments: segments) if assertion.key?(:checks)
        children = assertion[:children] || []
        raise FeaturevisorCLI::TestChecks::CheckError, "children must be an array" unless children.is_a?(Array)
        children.each_with_index do |child, index|
          raise FeaturevisorCLI::TestChecks::CheckError, "children[#{index}] must be an object" unless child.is_a?(Hash)
          if child.key?(:checks) || test[:scenario]
            details[:child_index] = index
            FeaturevisorCLI::TestChecks.preflight!(datafile, child[:checks], owner_variable: owner, segments: segments)
          end
        end
      end

      def run_test_variable(assertion, variable_key, instance, datafile, diagnostics, segments = {})
        root_context = parse_context(assertion[:context])
        matcher = segment_matcher(instance, segments)
        instance.set_context(root_context, true)
        options = {}
        options[:default_variable_value] = assertion[:defaultVariableValue] if assertion.key?(:defaultVariableValue)
        started = Time.now
        errors = []

        errors.concat(error_objects(test_variable_expectation(assertion, variable_key, instance, options)))
        if assertion.key?(:checks)
          check_result = FeaturevisorCLI::TestChecks.evaluate_result(
            instance, datafile, assertion[:checks], owner_variable: variable_key, diagnostics: diagnostics,
            segments: segments, context: root_context, segment_matcher: matcher
          )
          errors.concat(check_result[:errors])
        end

        Array(assertion[:children]).each_with_index do |child_assertion, child_index|
          child = instance.spawn(
            parse_context(child_assertion[:context]),
            sticky_features: parse_sticky(child_assertion[:stickyFeatures]),
            sticky_variables: child_assertion[:stickyVariables].is_a?(Hash) ? child_assertion[:stickyVariables] : {}
          )
          begin
            child_options = {}
            if child_assertion.key?(:defaultVariableValue)
              child_options[:default_variable_value] = child_assertion[:defaultVariableValue]
            end
            errors.concat(error_objects(test_variable_expectation(
              child_assertion, variable_key, child, child_options, child_index
            )))
            if child_assertion.key?(:checks)
              check_result = FeaturevisorCLI::TestChecks.evaluate_result(
                child,
                datafile,
                child_assertion[:checks],
                owner_variable: variable_key,
                diagnostics: diagnostics,
                child_index: child_index,
                segments: segments,
                context: root_context.merge(parse_context(child_assertion[:context])),
                segment_matcher: segment_matcher(child, segments, instance.instance_variable_get(:@__segment_test_keys), diagnostics)
              )
              errors.concat(check_result[:errors])
            end
          ensure
            child.close
          end
        end

        { has_error: !errors.empty?, errors: errors, duration: Time.now - started }
      end

      def run_test_scenario(assertion, instance, datafile, diagnostics, segments = {})
        started = Time.now
        errors = []
        root_context = parse_context(assertion[:context])
        matcher = segment_matcher(instance, segments)
        instance.set_context(root_context, true)
        if assertion[:__missing_assertions]
          errors << { message: "scenario spec requires assertions" }
        elsif assertion.key?(:checks)
          check_result = FeaturevisorCLI::TestChecks.evaluate_result(
            instance, datafile, assertion[:checks], owner_variable: nil, diagnostics: diagnostics,
            segments: segments, context: root_context, segment_matcher: matcher
          )
          errors.concat(check_result[:errors])
        elsif Array(assertion[:children]).empty?
          errors << { message: "scenario assertion requires checks or children" }
        end
        Array(assertion[:children]).each_with_index do |child_assertion, child_index|
          child = instance.spawn(
            parse_context(child_assertion[:context]),
            sticky_features: parse_sticky(child_assertion[:stickyFeatures]),
            sticky_variables: child_assertion[:stickyVariables].is_a?(Hash) ? child_assertion[:stickyVariables] : {}
          )
          begin
            check_result = FeaturevisorCLI::TestChecks.evaluate_result(
              child,
              datafile,
              child_assertion[:checks],
              owner_variable: nil,
              diagnostics: diagnostics,
              child_index: child_index,
              segments: segments,
              context: root_context.merge(parse_context(child_assertion[:context])),
              segment_matcher: segment_matcher(child, segments, instance.instance_variable_get(:@__segment_test_keys), diagnostics)
            )
            errors.concat(check_result[:errors])
          ensure
            child.close
          end
        end
        { has_error: !errors.empty?, errors: errors, duration: Time.now - started }
      end

      def test_variable_expectation(assertion, variable_key, evaluator, options, child_index = nil)
        evaluation = evaluator.evaluate_variable(variable_key, {}, options)
        details = { variableKey: variable_key }
        details[:childIndex] = child_index unless child_index.nil?
        errors = []
        if assertion.key?(:expectedValue)
          value = evaluator.get_variable(variable_key, {}, options)
          errors << expectation_error("variable", assertion[:expectedValue], value, details) unless compare_values(value, assertion[:expectedValue])
        end
        if assertion[:expectedEvaluation].is_a?(Hash)
          assertion[:expectedEvaluation].each do |key, expected|
            actual = get_evaluation_value(evaluation, key)
            unless compare_values(actual, expected)
              errors << expectation_error(
                "evaluation",
                expected,
                actual,
                details.merge(evaluationType: "variable", evaluationKey: key)
              )
            end
          end
        end
        errors
      end

      def expectation_error(type, expected, actual, details = {})
        { type: type, expected: expected, actual: actual, details: details }
      end

      def format_test_value(value)
        JSON.generate(value)
      rescue JSON::GeneratorError
        value.inspect
      end

      def run_test_feature(assertion, feature_key, instance, level)
        context = parse_context(assertion[:context])
        sticky = parse_sticky(assertion[:stickyFeatures])

        # Set context and sticky for this assertion
        instance.set_context(context, false)
        if sticky && !sticky.empty?
          instance.set_sticky_features(sticky, false)
        end

        # Create override options
        override_options = create_override_options(assertion)

        has_error = false
        errors = []
        start_time = Time.now

        # Test expectedToBeEnabled
        if assertion.key?(:expectedToBeEnabled)
          expected_to_be_enabled = assertion[:expectedToBeEnabled]
          is_enabled = instance.is_enabled(feature_key, context, override_options)

          if is_enabled != expected_to_be_enabled
            has_error = true
            errors << expectation_error("flag", expected_to_be_enabled, is_enabled)
          end
        end

        # Test expectedVariation
        if assertion.key?(:expectedVariation)
          expected_variation = assertion[:expectedVariation]
          variation = instance.get_variation(feature_key, context, override_options)

          variation_value = variation.nil? ? nil : variation
          if !compare_values(variation_value, expected_variation)
            has_error = true
            errors << expectation_error("variation", expected_variation, variation_value)
          end
        end

        # Test expectedVariables
        if assertion[:expectedVariables]
          expected_variables = assertion[:expectedVariables]
          expected_variables.each do |variable_key, expected_value|
            # Set default variable value for this specific variable
            if assertion[:defaultVariableValues].is_a?(Hash) && assertion[:defaultVariableValues].key?(variable_key)
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
                  errors << expectation_error("variable", expected_value, actual_value, variableKey: variable_key)
                end
                next
              rescue JSON::ParserError
                # Fall through to regular comparison
              end
            end

            # Regular comparison for non-JSON strings or when JSON parsing fails
            if !compare_values(actual_value, expected_value)
              has_error = true
              errors << expectation_error("variable", expected_value, actual_value, variableKey: variable_key)
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
                errors << expectation_error(
                  "evaluation", expected_value, actual_value,
                  evaluationType: "flag", evaluationKey: key
                )
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
                errors << expectation_error(
                  "evaluation", expected_value, actual_value,
                  evaluationType: "variation", evaluationKey: key
                )
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
                    errors << expectation_error(
                      "evaluation", expected_value, actual_value,
                      variableKey: variable_key, evaluationKey: key
                    )
                  end
                end
              end
            end
          end
        end

        # Test children
        if assertion[:children]
          assertion[:children].each_with_index do |child, child_index|
            if child.is_a?(Hash)
              child_context = parse_context(child[:context])

              # Create override options for child with sticky values
              child_instance = instance.spawn(
                child_context,
                sticky_features: parse_sticky(child[:stickyFeatures]) || {},
                sticky_variables: child[:stickyVariables].is_a?(Hash) ? child[:stickyVariables] : {}
              )
              begin
                child_result = run_test_feature_child(child, feature_key, child_instance, level, child_index)
              ensure
                child_instance.close
              end

              if child_result[:has_error]
                has_error = true
                errors.concat(child_result[:errors])
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

      def run_test_feature_child(assertion, feature_key, instance, level, child_index = nil)
        context = parse_context(assertion[:context])
        override_options = create_override_options(assertion)

        has_error = false
        errors = []
        child_details = child_index.nil? ? {} : { childIndex: child_index }
        start_time = Time.now

        # Test expectedToBeEnabled
        if assertion.key?(:expectedToBeEnabled)
          expected_to_be_enabled = assertion[:expectedToBeEnabled]
          is_enabled = instance.is_enabled(feature_key, context, override_options)

          if is_enabled != expected_to_be_enabled
            has_error = true
            errors << expectation_error("flag", expected_to_be_enabled, is_enabled, child_details)
          end
        end

        # Test expectedVariation
        if assertion.key?(:expectedVariation)
          expected_variation = assertion[:expectedVariation]
          variation = instance.get_variation(feature_key, context, override_options)

          variation_value = variation.nil? ? nil : variation
          if !compare_values(variation_value, expected_variation)
            has_error = true
            errors << expectation_error("variation", expected_variation, variation_value, child_details)
          end
        end

        # Test expectedVariables
        if assertion[:expectedVariables]
          expected_variables = assertion[:expectedVariables]
          expected_variables.each do |variable_key, expected_value|
            # Set default variable value for this specific variable
            if assertion[:defaultVariableValues].is_a?(Hash) && assertion[:defaultVariableValues].key?(variable_key)
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
                  errors << expectation_error(
                    "variable", expected_value, actual_value,
                    child_details.merge(variableKey: variable_key)
                  )
                end
                next
              rescue JSON::ParserError
                # Fall through to regular comparison
              end
            end

            # Regular comparison for non-JSON strings or when JSON parsing fails
            if !compare_values(actual_value, expected_value)
              has_error = true
              errors << expectation_error(
                "variable", expected_value, actual_value,
                child_details.merge(variableKey: variable_key)
              )
            end
          end
        end

        # Test expectedEvaluations
        if assertion[:expectedEvaluations]
          expected_evaluations = assertion[:expectedEvaluations]

          if expected_evaluations[:flag]
            evaluation = evaluate_from_instance(instance, :flag, feature_key, context, override_options)
            expected_evaluations[:flag].each do |key, expected_value|
              actual_value = get_evaluation_value(evaluation, key)
              if !compare_values(actual_value, expected_value)
                has_error = true
                errors << expectation_error(
                  "evaluation", expected_value, actual_value,
                  child_details.merge(evaluationType: "flag", evaluationKey: key)
                )
              end
            end
          end

          if expected_evaluations[:variation]
            evaluation = evaluate_from_instance(instance, :variation, feature_key, context, override_options)
            expected_evaluations[:variation].each do |key, expected_value|
              actual_value = get_evaluation_value(evaluation, key)
              if !compare_values(actual_value, expected_value)
                has_error = true
                errors << expectation_error(
                  "evaluation", expected_value, actual_value,
                  child_details.merge(evaluationType: "variation", evaluationKey: key)
                )
              end
            end
          end

          if expected_evaluations[:variables]
            expected_evaluations[:variables].each do |variable_key, expected_eval|
              if expected_eval.is_a?(Hash)
                evaluation = evaluate_from_instance(
                  instance,
                  :variable,
                  feature_key,
                  context,
                  override_options,
                  variable_key
                )
                expected_eval.each do |key, expected_value|
                  actual_value = get_evaluation_value(evaluation, key)
                  if !compare_values(actual_value, expected_value)
                    has_error = true
                    errors << expectation_error(
                      "evaluation", expected_value, actual_value,
                      child_details.merge(variableKey: variable_key, evaluationKey: key)
                    )
                  end
                end
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

      def run_test_segment(assertion, segment, level, selected = nil, segments = {}, segment_key = "subject", set = @active_set)
        return { has_error: true, errors: "segment was not found", duration: 0 } unless segment.is_a?(Hash)
        context = parse_context(assertion[:context])
        segments = segments.merge(segment_key.to_sym => segment)
        datafile = selected || { schemaVersion: "4", revision: "tester", features: {}, segments: {}, variables: {} }
        SegmentTests.references!(segment_key, datafile, segments)
        datafile = SegmentTests.prepare(datafile, segments)
        instance, = create_tester_instance(datafile, level, assertion, set)
        instance.instance_variable_set(:@__segment_test_keys, datafile[:_segment_test_keys])

        has_error = false
        errors = []
        start_time = Time.now

        if assertion.key?(:expectedToMatch)
          expected_to_match = assertion[:expectedToMatch]
          actual = segment_matcher(instance).call(segment_key, context)

          if actual != expected_to_match
            has_error = true
            errors << expectation_error("segment", expected_to_match, actual)
          end
        end

        duration = Time.now - start_time

        {
          has_error: has_error,
          errors: errors,
          duration: duration
        }
      rescue FeaturevisorCLI::TestChecks::CheckError => error
        { has_error: true, errors: [expectation_error("segment", "valid references", error.message)], duration: 0 }
      ensure
        instance&.close
      end

      def segment_matcher(instance, segments = {}, keys = nil, diagnostics = nil)
        keys ||= instance.instance_variable_get(:@__segment_test_keys)
        keys = {} if !keys && segments.empty?
        unless keys
          datafile = SegmentTests.prepare(instance.instance_variable_get(:@datafile).get_datafile, segments)
          instance.set_datafile(datafile, true)
          keys = datafile[:_segment_test_keys]
          instance.instance_variable_set(:@__segment_test_keys, keys)
        end
        diagnostics ||= instance.instance_variable_get(:@__segment_test_diagnostics) || []
        lambda do |key, context|
          diagnostics.clear
          evaluation = instance.evaluate_flag(keys.fetch(key.to_s), context)
          failed = diagnostics.any? { |item| %w[error fatal].include?(item[:level].to_s) }
          raise TestChecks::CheckError, "segment #{key.inspect} evaluation failed" if evaluation[:reason] == "error" || failed
          evaluation[:enabled] == true
        end
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

        if assertion.key?(:defaultVariationValue)
          options[:default_variation_value] = assertion[:defaultVariationValue]
        end

        options
      end

      def evaluate_from_instance(instance, type, feature_key, context, override_options, variable_key = nil)
        method_name = :"evaluate_#{type}"

        if instance.respond_to?(method_name)
          if variable_key.nil?
            return instance.send(method_name, feature_key, context, override_options)
          end

          return instance.send(method_name, feature_key, variable_key, context, override_options)
        end

        if instance.is_a?(Featurevisor::ChildInstance)
          parent = instance.instance_variable_get(:@parent)
          child_context = instance.instance_variable_get(:@context) || {}
          child_sticky = instance.instance_variable_get(:@sticky)
          combined_context = { **child_context, **context }

          combined_options = {
            __featurevisor_child_sticky: child_sticky,
            **override_options
          }

          if variable_key.nil?
            return parent.send(method_name, feature_key, combined_context, combined_options)
          end

          return parent.send(method_name, feature_key, variable_key, combined_context, combined_options)
        end

        {}
      end

      def get_evaluation_value(evaluation, key)
        case key
        when :type
          evaluation[:type]
        when :featureKey
          evaluation[:feature_key]
        when :reason
          evaluation[:reason]
        when :bucketKey
          evaluation[:bucket_key]
        when :bucketValue
          evaluation[:bucket_value]
        when :ruleKey
          evaluation[:rule_key]
        when :error
          evaluation[:error]
        when :enabled
          evaluation[:enabled]
        when :traffic
          evaluation[:traffic]
        when :forceIndex
          evaluation[:force_index]
        when :force
          evaluation[:force]
        when :conditions
          evaluation[:conditions]
        when :stickyFeature
          evaluation[:sticky_feature]
        when :variation
          evaluation[:variation]
        when :variationValue
          evaluation[:variation_value]
        when :variableKey
          evaluation[:variable_key]
        when :variableValue
          evaluation[:variable_value]
        when :variableSchema
          evaluation[:variable_schema]
        when :variableOverrideIndex
          evaluation[:variable_override_index]
        when :variableOverrideKey
          evaluation[:variable_override_key]
        when :variableOverridePath
          evaluation[:variable_override_path]
        when :variableOverridePaths
          evaluation[:variable_override_paths]
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

      def empty_report
        {
          schemaVersion: 1,
          runner: "ruby",
          passed: true,
          summary: {
            specs: { passed: 0, failed: 0 },
            assertions: { passed: 0, failed: 0 },
            entitySpecs: { passed: 0, failed: 0 },
            entityAssertions: { passed: 0, failed: 0 },
            scenarioSpecs: { passed: 0, failed: 0 },
            scenarioCases: { passed: 0, failed: 0 }
          },
          results: [],
          errors: []
        }
      end

      def merge_report!(destination, source)
        destination[:results].concat(source[:results])
        destination[:errors].concat(source[:errors])
      end

      def finalize_report!(report)
        summary = empty_report[:summary]
        report[:results].each do |result|
          spec_bucket = result[:type] == "scenario" ? :scenarioSpecs : :entitySpecs
          case_bucket = result[:type] == "scenario" ? :scenarioCases : :entityAssertions
          spec_state = result[:passed] ? :passed : :failed
          summary[:specs][spec_state] += 1
          summary[spec_bucket][spec_state] += 1
          result[:cases].each do |item|
            case_state = item[:passed] ? :passed : :failed
            summary[:assertions][case_state] += 1
            summary[case_bucket][case_state] += 1
          end
        end
        report[:summary] = summary
        report[:passed] = report[:errors].empty? && summary[:specs][:failed].zero? && summary[:assertions][:failed].zero?
        report[:uncovered] = report[:uncovered].sort_by { |item| item[:set].to_s } if report.key?(:uncovered)
        report
      end

      def error_objects(value, type: nil, assertion: nil)
        errors = if value.is_a?(Array)
                   value.map { |error| error.is_a?(Hash) ? deep_copy(error) : { message: error.to_s } }
                 else
                   value.to_s.lines.filter_map do |line|
          message = line.sub(/^\s*✘\s*/, "").strip
          next if message.empty?
                     { message: message }
                   end
                 end
        return errors unless type && assertion

        errors.map do |error|
          if error[:type] == "check"
            decorate_check_error(error, type, assertion)
          else
            decorate_expectation_error(error, type, assertion)
          end
        end
      end

      def decorate_check_error(error, type, assertion)
        return error unless error[:type] == "check"

        details = error[:details].is_a?(Hash) ? error[:details] : {}
        assertion_index = assertion.dig(:_case, :assertionIndex)
        base = type == :scenario ? [] : ["assertions", assertion_index || 0]
        base += ["children", details[:childIndex]] if details.key?(:childIndex)
        collection = "checks"
        error[:path] = base + [collection]
        error[:path] << details[:checkIndex] if details.key?(:checkIndex)
        if details[:evaluated].is_a?(Array)
          details[:evaluated] = details[:evaluated].map do |leaf|
            leaf.merge(path: base + [collection] + Array(leaf[:path]))
          end
        end
        if error[:expected] == true && error[:actual] == false
          error[:message] = "Check did not match"
        end
        error
      end

      def decorate_expectation_error(error, type, assertion)
        details = error[:details].is_a?(Hash) ? error[:details] : {}
        assertion_index = assertion.dig(:_case, :assertionIndex) || 0
        path = ["assertions", assertion_index]
        path += ["children", details[:childIndex]] if details.key?(:childIndex)
        suffix = case error[:type]
                 when "flag" then ["expectedToBeEnabled"]
                 when "segment" then ["expectedToMatch"]
                 when "variation" then ["expectedVariation"]
                 when "variable"
                   type == :variable ? ["expectedValue"] : ["expectedVariables", details[:variableKey]]
                 when "evaluation"
                   if type == :variable
                     ["expectedEvaluation", details[:evaluationKey]]
                   elsif details.key?(:variableKey)
                     ["expectedEvaluations", "variables", details[:variableKey], details[:evaluationKey]]
                   else
                     ["expectedEvaluations", details[:evaluationType], details[:evaluationKey]]
                   end
                 else
                   []
                 end
        error[:path] = path + suffix unless suffix.empty?
        error[:message] ||= "expected #{format_test_value(error[:expected])}, received #{format_test_value(error[:actual])}"
        error
      end

      def deep_copy(value)
        Marshal.load(Marshal.dump(value))
      end

      def normalized_environment(environment)
        environment == false ? nil : environment
      end

      def rerun_instruction(assertion, set)
        args = ["test"]
        args << "--case=#{assertion.dig(:_case, :id)}" if assertion.dig(:_case, :id)
        if @options.project_directory_path_explicit
          args << "--projectDirectoryPath=#{@options.project_directory_path}"
        end
        args << "--set=#{set}" if set
        @options.targets.each { |target| args << "--target=#{target}" }
        { command: "bundle exec featurevisor", args: args }
      end

      def progress(message)
        stream = @options.json ? $stderr : $stdout
        stream.puts(message)
      end

      def print_report(report)
        if @options.json
          puts(@options.pretty ? JSON.pretty_generate(report) : JSON.generate(report))
          return
        end

        if report[:results].empty? && report[:errors].empty?
          puts "No tests found"
        end
        report[:results].each do |result|
          next if @options.only_failures && result[:passed]
          puts "\nTesting: #{result[:source]}"
          result[:cases].each_with_index do |item, index|
            next if @options.only_failures && item[:passed]
            puts "  #{item[:passed] ? '✔' : '✘'} #{human_case_label(item, index)}"
            item[:errors].each do |error|
              human_error_lines(error).each { |line| puts "      ✘ #{line}" }
            end
            next if item[:passed] || item.dig(:rerun, :args).nil?
            command = "#{item.dig(:rerun, :command)} #{item.dig(:rerun, :args).map { |arg| Shellwords.escape(arg) }.join(' ')}"
            puts "      Rerun (POSIX shell): #{command}"
          end
        end
        report[:errors].each { |error| puts "Error: #{error[:message]}" }
        summary = report[:summary]
        puts ""
        puts "Entity specs: #{summary[:entitySpecs][:passed]} passed, #{summary[:entitySpecs][:failed]} failed"
        puts "Entity assertions: #{summary[:entityAssertions][:passed]} passed, #{summary[:entityAssertions][:failed]} failed"
        puts "Scenario specs: #{summary[:scenarioSpecs][:passed]} passed, #{summary[:scenarioSpecs][:failed]} failed"
        puts "Scenario cases: #{summary[:scenarioCases][:passed]} passed, #{summary[:scenarioCases][:failed]} failed"
        puts "Total cases: #{summary[:assertions][:passed]} passed, #{summary[:assertions][:failed]} failed"
        if report[:uncovered]
          puts "\nDefinitions without associated specs (not evaluation coverage):"
          report[:uncovered].each do |item|
            puts "  Set: #{item[:set]}" if item[:set]
            puts "  Features: #{item[:features].empty? ? 'none' : item[:features].join(', ')}"
            puts "  Global variables: #{item[:variables].empty? ? 'none' : item[:variables].join(', ')}"
          end
        end
        if report[:coverage]
          puts "\nObserved rule and override selections (not branch coverage):"
          selections = report.dig(:coverage, :selections)
          selections.each { |selection| puts "  #{human_coverage_selection(selection)}" }
          puts "  No selections observed" if selections.empty?
        end
        puts ""
      end

      def human_case_label(item, index)
        label = item[:description].to_s.empty? ? "assertion #{index + 1}" : item[:description]
        details = ["case #{index + 1}"]
        matrix = item[:matrixValues]
        if matrix.is_a?(Hash) && !matrix.empty?
          details << "matrix #{matrix.map { |key, value| "#{key}=#{JSON.generate(value)}" }.join(', ')}"
        end
        details << "target #{item[:target]}" if item[:target]
        "#{label} (#{details.join('; ')})"
      end

      def human_coverage_selection(selection)
        owner = if selection[:featureKey]
                  "feature #{selection[:featureKey]}#{selection[:variableKey] ? " variable #{selection[:variableKey]}" : ''}"
                else
                  "global variable #{selection[:variableKey]}"
                end
        scope = %i[set environment target].filter_map { |key| "#{key} #{selection[key]}" if selection[key] }
        picks = []
        picks << "rule #{selection[:ruleKey]}" if selection[:ruleKey]
        picks << "variation #{JSON.generate(selection[:variation])}" if selection.key?(:variation)
        picks << "override #{Array(selection[:overridePath]).join(' > ')}" if selection[:overridePath]
        picks << "override #{selection[:overrideIndex] + 1}" if selection.key?(:overrideIndex)
        "#{owner}#{scope.empty? ? '' : " (#{scope.join(', ')})"}: #{picks.join(', ')}"
      end

      def human_error_lines(error)
        details = error[:details]
        return [error[:message]] unless error[:type] == "check" && details.is_a?(Hash)

        named = details[:checkKey] ? " #{details[:checkKey].inspect}" : ""
        description = details[:checkDescription] ? " (#{details[:checkDescription]})" : ""
        lines = ["#{human_check_message(error[:message])}#{named}#{description} at #{human_path(error[:path])}"]
        Array(details[:evaluated]).each do |leaf|
          reference = human_reference(leaf[:reference])
          comparison = leaf[:compareTo] ? human_reference(leaf[:compareTo]) : "literal"
          reference = "#{reference}.#{leaf[:property]}" if leaf[:property]
          lines << "#{human_path(leaf[:path])}: #{reference} #{leaf[:operator]} #{comparison} " \
                   "(left=#{JSON.generate(leaf[:actual])}, right=#{JSON.generate(leaf[:expected])})"
        end
        lines
      end

      def human_check_message(message)
        message.to_s.gsub(/\b(checks|children)\[(\d+)\]/) do
          "#{Regexp.last_match(1) == 'children' ? 'Child' : 'check'} #{Regexp.last_match(2).to_i + 1}"
        end
      end

      def human_path(path)
        Array(path).each_with_index.map do |part, index|
          part.is_a?(Integer) ? "[#{part + 1}]" : index.zero? ? part.to_s : ".#{part}"
        end.join
      end

      def human_reference(reference)
        return "<unknown>" unless reference.is_a?(Hash)
        variable = reference[:variable]
        root = reference[:feature] ? [reference[:feature], variable].compact.join(".") : variable
        reference.key?(:path) ? "#{root}:#{JSON.generate(reference[:path])}" : root.to_s
      end

      def get_uncovered(set)
        {
          set: set,
          features: get_uncovered_entities("features", set),
          variables: get_uncovered_entities("variables", set)
        }
      end

      def get_uncovered_entities(selector, set)
        command = node_command("list", "--#{selector}", "--without-tests", "--json", *set_arguments(set))
        output = JSON.parse(execute_command(command), symbolize_names: true)
        Array(output).filter_map { |item| item.is_a?(Hash) ? item[:key] : item }.map(&:to_s).sort
      rescue JSON::ParserError => e
        raise InfrastructureError, "Failed to parse uncovered #{selector} JSON: #{e.message}"
      end

      def record_coverage_selection(evaluation, assertion, set)
        rule_key = evaluation[:rule_key]
        paths = Array(evaluation[:variable_override_paths])
        paths = [evaluation[:variable_override_path]] if paths.empty? && evaluation[:variable_override_path]
        paths = [evaluation[:variable_override_key]] if paths.empty? && evaluation[:variable_override_key]
        paths = [nil] if paths.empty? && evaluation.key?(:variable_override_index)
        paths = [nil] if paths.empty? && rule_key
        paths.each do |path|
          next unless rule_key || path || evaluation.key?(:variable_override_index)
          item = {
            set: set,
            environment: normalized_environment(assertion[:environment]),
            target: assertion[:target]
          }
          item[:featureKey] = evaluation[:feature_key] if evaluation[:feature_key]
          item[:variableKey] = evaluation[:variable_key] if evaluation[:variable_key]
          item[:ruleKey] = rule_key if rule_key
          item[:variation] = evaluation.dig(:variation, :value) if evaluation[:variation].is_a?(Hash) && evaluation[:variation].key?(:value)
          item[:overridePath] = path if path
          item[:overrideIndex] = evaluation[:variable_override_index] if !path && evaluation.key?(:variable_override_index)
          @coverage_selections << item
        end
      end

      def coverage_report
        unique = @coverage_selections.each_with_object({}) do |selection, items|
          items[JSON.generate(selection)] = selection
        end.values
        {
          mode: "observed-selections",
          selections: unique.sort_by { |item| JSON.generate(item) }
        }
      end



      # Node CLI calls pass an argument list run in the project directory.
      def execute_command(command)
        stdout, stderr, status =
          command.is_a?(Array) ? Open3.capture3(*command, chdir: @project_path) : Open3.capture3(command)
        stdout.force_encoding(Encoding::UTF_8)
        stderr.force_encoding(Encoding::UTF_8)

        unless status.success?
          begin
            payload = JSON.parse(stderr)
            error = payload["error"] || {}
            if error["message"] || error["code"]
              raise InfrastructureError.new(
                error["message"] || "Command failed with exit code #{status.exitstatus}",
                code: error["code"]
              )
            end
          rescue JSON::ParserError
            nil
          end
          details = stderr.empty? ? "" : ": #{stderr.strip}"
          raise InfrastructureError, "Command failed with exit code #{status.exitstatus}#{details}"
        end

        stdout
      end
    end
  end
end
