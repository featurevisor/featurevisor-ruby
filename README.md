# Featurevisor Ruby SDK <!-- omit in toc -->

Use the Featurevisor Ruby SDK to evaluate flags, variations and variables in Ruby applications.

## Table of contents <!-- omit in toc -->

- [Installation](#installation)
- [Initialization](#initialization)
  - [Public API](#public-api)
  - [Evaluation types](#evaluation-types)
- [Context](#context)
  - [Setting initial context](#setting-initial-context)
  - [Setting after initialization](#setting-after-initialization)
  - [Replacing existing context](#replacing-existing-context)
  - [Manually passing context](#manually-passing-context)
- [Check if enabled](#check-if-enabled)
- [Getting variation](#getting-variation)
- [Getting variables](#getting-variables)
  - [Getting feature variables](#getting-feature-variables)
  - [Type specific methods](#type-specific-methods)
  - [Getting global variables](#getting-global-variables)
- [Conditions](#conditions)
- [Composition](#composition)
- [Getting evaluations](#getting-evaluations)
- [Sticky](#sticky)
  - [Initialize with sticky](#initialize-with-sticky)
  - [Set sticky afterwards](#set-sticky-afterwards)
- [Setting datafile](#setting-datafile)
  - [Merging by default](#merging-by-default)
  - [Replacing](#replacing)
  - [Loading datafiles on demand](#loading-datafiles-on-demand)
  - [Updating datafile](#updating-datafile)
  - [Interval-based update](#interval-based-update)
- [Diagnostics](#diagnostics)
  - [Levels](#levels)
  - [Handler](#handler)
- [Events](#events)
  - [`datafile_set`](#datafile_set)
  - [`context_set`](#context_set)
  - [`sticky_features_set` and `sticky_variables_set`](#sticky_features_set-and-sticky_variables_set)
  - [`error`](#error)
- [Evaluation details](#evaluation-details)
- [Modules](#modules)
  - [Defining a module](#defining-a-module)
  - [Registering modules](#registering-modules)
- [Child instance](#child-instance)
- [Close](#close)
- [OpenFeature](#openfeature)
- [CLI usage](#cli-usage)
  - [Test](#test)
  - [Test against local monorepo's example-1](#test-against-local-monorepos-example-1)
  - [Benchmark](#benchmark)
  - [Assess distribution](#assess-distribution)
- [GitHub repositories](#github-repositories)
- [Development](#development)
  - [Setting up](#setting-up)
  - [Running tests](#running-tests)
  - [Releasing](#releasing)
- [License](#license)

<!-- FEATUREVISOR_DOCS_BEGIN -->

## Installation

Upgrading an existing application? Follow the [Ruby migration guide](https://featurevisor.com/docs/migrations/v4/ruby/).

Add this line to your application's Gemfile:

```ruby
gem 'featurevisor', '~> 4.0'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install featurevisor -v "~> 4.0"
```

## Initialization

The SDK can be initialized by passing [datafile](https://featurevisor.com/docs/building-datafiles/) content directly:

```ruby
require 'featurevisor'
require 'net/http'
require 'json'

# Fetch datafile from URL
datafile_url = 'https://cdn.yoursite.com/featurevisor-all.json'
response = Net::HTTP.get_response(URI(datafile_url))
unless response.is_a?(Net::HTTPSuccess)
  raise "Datafile request failed: HTTP #{response.code}"
end

# Parse JSON with symbolized keys (required)
datafile_content = JSON.parse(response.body, symbolize_names: true)

# Create SDK instance
f = Featurevisor.create_featurevisor(
  datafile: datafile_content
)
begin
  puts f.is_enabled('checkout', { userId: '123' })
ensure
  f.close
end
```

Network errors, unsuccessful HTTP responses and invalid JSON stop initialization. Handle these exceptions at your application's startup boundary.

**Important**: When parsing JSON datafiles, you must use `symbolize_names: true` to ensure proper key handling by the SDK.

Pass a JSON string for the SDK to parse:

```ruby
# Option 1: Parse JSON yourself (recommended)
datafile_content = JSON.parse(json_string, symbolize_names: true)
f = Featurevisor.create_featurevisor(datafile: datafile_content)

# Option 2: Pass JSON string directly (automatic parsing)
f = Featurevisor.create_featurevisor(datafile: json_string)
```

### Public API

The main runtime API is `Featurevisor.create_featurevisor`:

```ruby
f = Featurevisor.create_featurevisor(
  datafile: datafile_content
)
```

Most applications only need this factory and the returned `Featurevisor::Instance`. Public extension and observability APIs include modules, diagnostics, events, and the datafile structures accepted by the factory.

Concurrent evaluations and a single background datafile refresh writer are supported on MRI. Warm entity reads rely on MRI's execution model. Thread safety is not guaranteed on other Ruby implementations. CI covers MRI 3.0 and 3.4. Serialize writer operations. Do not change context, sticky state or modules, or close the instance, concurrently with evaluations on other threads. Module, event, and diagnostic callbacks must synchronize mutable state that they capture.

### Evaluation types

Featurevisor evaluates four kinds of values:

- [**Flag**](#check-if-enabled) (`true` or `false`): whether the feature is enabled or not
- [**Variation**](#getting-variation) (`String`): the variation of the feature (if any)
- [**Feature variable**](#getting-feature-variables): a configuration value owned by a feature
- [**Global variable**](#getting-global-variables): a configuration value evaluated independently of a feature

These evaluations are run against the provided context.

## Context

Contexts are [attribute](https://featurevisor.com/docs/attributes/) values you pass to the SDK for evaluating [features](https://featurevisor.com/docs/features/) against.

Conditions compare these attributes using the [operators](https://featurevisor.com/docs/operators/), including `empty` and `notEmpty`.

Date comparisons with `before` and `after` accept portable timestamp strings, `Time` and `DateTime`. Native values are compared by their instant and truncated to milliseconds without rounding. Both the native written year and the UTC year must be within 1 to 9999. Native offsets must have a magnitude of at most 14 hours, including any seconds or fractions supported by the type. Offsets within that limit retain their full precision. A plain `Date` is not accepted because it has no time or offset. Pass `Time.utc(2026, 1, 1)` or `'2026-01-01T00:00:00Z'` instead of `Date.new(2026, 1, 1)`. Invalid values make both operators return `false`.

They are plain hashes:

```ruby
context = {
  userId: '123',
  country: 'nl',
  # ...other attributes
}
```

### Setting initial context

Set context when you create the instance:

```ruby
require 'featurevisor'

f = Featurevisor.create_featurevisor(
  context: {
    deviceId: '123',
    country: 'nl'
  }
)
```

This is useful for values that don't change too frequently and available at the time of application startup.

### Setting after initialization

Add context later:

```ruby
f.set_context({
  userId: '234'
})
```

This will merge the new context with the existing one (if already set).

### Replacing existing context

Replace the context by passing `true` as the second argument:

```ruby
f.set_context({
  deviceId: '123',
  userId: '234',
  country: 'nl',
  browser: 'chrome'
}, true) # replace existing context
```

### Manually passing context

Pass context to one evaluation without changing the instance context:

```ruby
context = {
  userId: '123',
  country: 'nl'
}

is_enabled = f.is_enabled('checkout', context)
variation = f.get_variation('checkout', context)
variable_value = f.get_variable('checkout', 'bgColor', context)
```

When manually passing context, it will merge with existing context set to the SDK instance before evaluating the specific value.

## Check if enabled

Check whether a feature is enabled:

```ruby
feature_key = 'checkout'

is_enabled = f.is_enabled(feature_key)

if is_enabled
  # do something
end
```

Pass additional context to one evaluation:

```ruby
is_enabled = f.is_enabled(feature_key, {
  # ...additional context
})
```

## Getting variation

Evaluate a feature's [variations](https://featurevisor.com/docs/features/#variations):

```ruby
feature_key = 'checkout'

variation = f.get_variation(feature_key)

if variation == 'treatment'
  # do something for treatment variation
else
  # handle default/control variation
end
```

Pass additional context to one evaluation:

```ruby
variation = f.get_variation(feature_key, {
  # ...additional context
})
```

## Getting variables

### Getting feature variables

Evaluate a feature's [variables](https://featurevisor.com/docs/features/#variables):

```ruby
variable_key = 'bgColor'

bg_color_value = f.get_variable('checkout', variable_key)
```

Pass additional context to one evaluation:

```ruby
bg_color_value = f.get_variable('checkout', variable_key, {
  # ...additional context
})
```

### Type specific methods

Next to generic `get_variable()` methods, there are also type specific methods available for convenience:

```ruby
f.get_variable_boolean(feature_key, variable_key, context = {})
f.get_variable_string(feature_key, variable_key, context = {})
f.get_variable_integer(feature_key, variable_key, context = {})
f.get_variable_number(feature_key, variable_key, context = {})
f.get_variable_array(feature_key, variable_key, context = {})
f.get_variable_object(feature_key, variable_key, context = {})
f.get_variable_json(feature_key, variable_key, context = {})
```

Type specific methods do not coerce values. `get_variable_integer` returns `nil` for the string `"1"`, and boolean getters return `nil` for non-boolean values.

`get_variable_number` reads a variable of type `number` as a `Float`, whether it holds `3` or `4.5`. Datafiles built before v4 call that type `double`, and it reads the same way. The v3 name `get_variable_double` was removed in v4.

### Getting global variables

Global variables use the same methods with a single variable key:

```ruby
message = f.get_variable_string('welcomeMessage', context)
value = f.get_variable('checkoutSettings', context)
evaluation = f.evaluate_variable('checkoutSettings', context)
```

Overrides and conditions are applied for you. See [Variables](https://featurevisor.com/docs/variables/#global-variables) and [Conditions](https://featurevisor.com/docs/conditions/) for how to define them.

To see which overrides changed a value, inspect `variable_override_paths` in the detailed evaluation:

```ruby
evaluation = f.evaluate_variable('runtimePolicy', country: 'nl')
value = evaluation[:variable_value]
matched_paths = evaluation[:variable_override_paths]
```

Treat sticky feature and variable maps, including nested values passed to the SDK or returned by modules, as read only during evaluation. Use the SDK setters to change owned sticky state.

Modules should return the same result for the same input during one evaluation. Pass values that change through context.

## Conditions

[Conditions](https://featurevisor.com/docs/conditions/) are shared by segments, feature and global variable root gates, force entries, traffic rules and variable overrides. Generated v4 datafiles use `schemaVersion: "4"`. Arrays imply AND. Logical expressions use `and`, `or` and `not`. NOT negates the AND of its direct children. Empty expressions are false.

Leaves compare context attributes, reference a segment by its literal string key, check a feature's enabled state and optional variation, or compare an evaluated variable. Feature enabled checks default to true. Variable leaves may name a feature owner and use already compiled path arrays. Dots and slashes in variable keys remain literal.

For example, a compiled root gate can combine all four leaf kinds:

```json
{
  "conditions": [
    {"attribute": "country", "operator": "equals", "value": "nl"},
    "eligibleAudience",
    {"feature": "checkout", "variation": "treatment"},
    {"variable": "policy", "path": ["items", 0, "enabled"], "operator": "equals", "value": true}
  ]
}
```

Continue using ordinary getters:

```ruby
enabled = f.is_enabled('checkout', country: 'nl')
policy = f.get_variable('policy')
```

Feature evaluation checks sticky state, force, its root gate and then traffic rules. Force bypasses the gate. Global variables check sticky state and their gate before reading sources or applying overrides. A missed root gate reports `conditions_unmet` and `evaluation[:conditions]`. Variation and feature variable evaluations retain their ordinary disabled reasons and fallbacks.

Conditions preserve written order and short circuit. Segments and getter dependencies share the current request session and a combined depth limit of 256 internal handoffs. Cycles and excessive depth fail the whole evaluation. Later independent calls start fresh sessions. An ordinary completed false or nil getter result remains a value.

## Composition

[Composed variables](https://featurevisor.com/docs/variables/#compose-values) read sources through ordinary getters with the effective context, modules and sticky state. A compiled list assembles one fresh outer hash with literal property names:

```json
{
  "type": "object",
  "compose": [
    {"key": "enabled", "feature": "checkout"},
    {"key": "assignment", "feature": "checkout", "variation": true},
    {"key": "title", "feature": "checkout", "variable": "title"},
    {"key": "policy", "variable": "policy"}
  ]
}
```

The string form, `"compose": "policy"`, is an alias of that literal global variable key. It returns the evaluated source directly, including false, zero, empty strings, arrays and nil. JSON sources are decoded exactly once, including when their decoded strings resemble JSON.

```ruby
screen = f.get_variable('screen', country: 'nl')
details = f.evaluate_variable('screen', country: 'nl')
```

Compositions do not declare `defaultValue` or `useDefaultWhenDisabled`. They may have root `conditions` and `disabledValue`. An unmet gate skips every source and override and returns the disabled value or nil. Whole variable sticky state bypasses both assembly and overrides. Explicit defaults supplied to the outer getter are never forwarded to sources.

All members are read before runtime overrides. Overrides use the existing mutation operations and provenance fields. The reason is `variable_composed`, or `variable_override_rule` when an override matches. Mutations copy changed containers without modifying source values, sibling properties or sticky values.

Treat returned hashes and arrays as read only. Composition properties and aliases keep ordinary getter ownership, so descendants may be shared. Only the map composition's outer hash is guaranteed to be fresh. Ordinary source getter failures retain their normal fallbacks. Dependency failures invalidate the whole composition.

## Getting evaluations

Evaluate all features available in the instance:

```ruby
all_evaluations = f.get_feature_evaluations({})

puts all_evaluations
# {
#   checkout: {
#     enabled: true,
#     variation: "control",
#     variables: {
#       myVariableKey: "myVariableValue",
#     },
#   },
#
#   anotherFeature: {
#     enabled: true,
#     variation: "treatment",
#   }
# }
```

This is handy especially when you want to pass all evaluations from a backend application to the frontend.

Global variable values are available separately:

```ruby
global_variables = f.get_variable_evaluations({})
```

## Sticky

Set sticky values to take precedence over feature evaluation against the [datafile](https://featurevisor.com/docs/building-datafiles/):

Sticky values belong to an SDK or child instance. Feature and global variable sticky values are independent.

### Initialize with sticky

```ruby
require 'featurevisor'

f = Featurevisor.create_featurevisor(
  sticky_features: {
    checkout: {
      enabled: true,
      # optional
      variation: 'treatment',
      variables: {
        myVariableKey: 'myVariableValue'
      }
    },
    anotherFeatureKey: {
      enabled: false
    }
  },
  sticky_variables: {
    welcomeMessage: 'Welcome back'
  }
)
```

Once initialized with sticky features, the SDK will look for values there first before evaluating the targeting conditions and going through the bucketing process.

### Set sticky afterwards

Set sticky features after initialization:

```ruby
f.set_sticky_features({
  checkout: {
    enabled: true,
    variation: 'treatment',
    variables: {
      myVariableKey: 'myVariableValue'
    }
  },
  anotherFeatureKey: {
    enabled: false
  }
}, true) # replace existing sticky features (false by default)

f.set_sticky_variables({ welcomeMessage: 'Welcome back' }, true)
```

## Setting datafile

You may also initialize the SDK without passing `datafile`, and set it later on:

```ruby
# Parse with symbolized keys before setting
datafile_content = JSON.parse(json_string, symbolize_names: true)
f.set_datafile(datafile_content)

# Or pass JSON string directly for automatic parsing
f.set_datafile(json_string)
```

`set_datafile` returns `true` when the datafile is accepted, including unchanged content. It returns `false` when the datafile is rejected or the instance is closed. Rejected datafiles leave the last accepted datafile in place. Diagnostics and events keep their existing behaviour.

Schema version `"2"` selectors normalize eagerly before merging. Schema version `"4"` entities normalize lazily on first read. Informational schema metadata is retained. Partial updates invalidate only incoming entities. Replacement clears normalized caches. Caller definitions are never changed.

### Merging by default

By default, `set_datafile(datafile)` merges the incoming datafile into the SDK's current datafile:

- top-level metadata such as `schemaVersion`, `revision`, and `featurevisorVersion` comes from the incoming datafile
- `segments` are merged, with incoming entries overriding existing ones
- `features` are merged, with incoming entries overriding existing ones
- global `variables` are merged, with incoming entries overriding existing ones

Call `set_datafile` with different datafiles to merge their features, segments, and global variables.

### Replacing

To fully replace the stored datafile, pass `true` as the second argument:

```ruby
f.set_datafile(datafile_content, true) # replace
```

### Loading datafiles on demand

Merge datafiles for different [targets](https://featurevisor.com/docs/targets/) into the same instance. Here, the two datafile values have already been loaded and validated by your application from the same published release:

```ruby
f.set_datafile(products_datafile)
f.set_datafile(checkout_datafile)
```

Use immutable release URLs, check HTTP responses and keep shared dependencies consistent. See [Loading datafiles on demand](https://featurevisor.com/docs/use-cases/on-demand-datafiles/) for the complete loading and refresh flow.

### Updating datafile

Each accepted datafile update emits a [`datafile_set`](#datafile-set) event. Subscribe to react to updates.

The triggers for setting the datafile again can be:

- periodic updates based on an interval (like every 5 minutes), or
- reacting to:
  - a specific event in your application (like a user action), or
  - an event served via websocket or server-sent events (SSE)

### Interval-based update

Replace the complete datafile on each refresh so definitions removed upstream are removed from the SDK too. Use merging only when loading partial datafiles intentionally.

```ruby
require 'net/http'
require 'json'

def update_datafile(f, datafile_url)
  loop do
    sleep(5 * 60) # 5 minutes

    begin
      response = Net::HTTP.get_response(URI(datafile_url))
      datafile_content = JSON.parse(response.body)
      f.set_datafile(datafile_content, true) # replace
    rescue => e
      # handle error
      puts "Failed to update datafile: #{e.message}"
    end
  end
end

# Start the update thread
Thread.new { update_datafile(f, datafile_url) }
```

## Diagnostics

By default, Featurevisor reports diagnostics to the console for `info` level and above with a `[Featurevisor]` prefix.

### Levels

Available diagnostic levels are `fatal`, `error`, `warn`, `info`, and `debug`.

Set the level during initialization or update it afterwards:

```ruby
f = Featurevisor.create_featurevisor(log_level: "debug")
f.set_log_level("info")
```

### Handler

Use `on_diagnostic` to send structured diagnostics to your observability system:

```ruby
f = Featurevisor.create_featurevisor(
  log_level: "info",
  on_diagnostic: ->(diagnostic) {
    puts "#{diagnostic[:level]} #{diagnostic[:code]} #{diagnostic[:message]}"
  }
)
```

Every diagnostic has `:level`, `:code`, `:message`, and an object-shaped `:details` hash. Optional `:module`, `:moduleName`, and `:originalError` fields describe provenance. Evaluation metadata belongs in `:details`.

Diagnostic handlers are isolated from SDK behaviour. An exception in a handler does not stop other handlers or evaluations.

Malformed stringified selectors report `conditions_parse_error` at error level once per selector per incoming entity load. Details contain exactly `conditions` with the original string, `entityType` and `entityKey`. Schema 2 diagnostics run after accepted datafile storage. V4 diagnostics run after caching the first entity read. Handlers may safely read the accepted revision again. A malformed selector fails locally, even through NOT or segment references, without rejecting the datafile or disabling unrelated entities.

## Events

Subscribe to SDK events to respond to context, sticky state and datafile changes.

Subscribe to instance lifecycle events:

### `datafile_set`

```ruby
unsubscribe = f.on('datafile_set') do |event|
  revision = event[:revision]        # new revision
  previous_revision = event[:previousRevision]
  revision_changed = event[:revisionChanged] # true if revision has changed

  # list of feature keys that have new updates,
  # and you should re-evaluate them
  features = event[:features]

  # handle here
end

# stop listening to the event
unsubscribe.call
```

The `features` and `variables` arrays include direct changes and transitive dependencies through conditions, segments and composition sources. They contain entities that have been:

- added, or
- updated, or
- removed

compared to the previous datafile content that existed in the SDK instance.

The event also includes `replaced`, which is `true` when the datafile replaced the previous content instead of merging into it.

### `context_set`

```ruby
unsubscribe = f.on('context_set') do |event|
  replaced = event[:replaced] # true if context was replaced
  context = event[:context]   # the new context

  puts 'Context set'
end
```

### `sticky_features_set` and `sticky_variables_set`

```ruby
feature_unsubscribe = f.on('sticky_features_set') do |event|
  replaced = event[:replaced] # true if sticky features got replaced
  features = event[:features] # list of all affected feature keys

  puts 'Sticky features set'
end

variable_unsubscribe = f.on('sticky_variables_set') do |event|
  variables = event[:variables]
end
```

### `error`

```ruby
unsubscribe = f.on('error') do |event|
  diagnostic = event[:diagnostic]
  code = diagnostic[:code]
  message = diagnostic[:message]

  puts "Featurevisor error: #{code} #{message}"
end
```

The `error` event is emitted for diagnostics reported with `level: "error"`.

## Evaluation details

Inspect how variations and variables are evaluated against a context:

```ruby
# flag
evaluation = f.evaluate_flag(feature_key, context = {})

# variation
evaluation = f.evaluate_variation(feature_key, context = {})

# variable
evaluation = f.evaluate_variable(feature_key, variable_key, context = {})

# global variable
global_evaluation = f.evaluate_variable(variable_key, context = {})
```

The returned object will always contain the following properties:

- `feature_key`: the feature key when evaluating a feature
- `reason`: the reason how the value was evaluated

And optionally these properties depending on whether you are evaluating a feature variation or a variable:

- `bucket_value`: the bucket value between 0 and 100,000
- `rule_key`: the rule key
- `error`: the error object
- `enabled`: if feature itself is enabled or not
- `variation`: the variation object
- `variation_value`: the variation value
- `variable_key`: the variable key
- `variable_value`: the variable value
- `variable_schema`: the variable schema
- `variable_override_index`: index of the final matched global variable override
- `variable_override_key`: key of the final matched global variable override
- `variable_override_path`: authoring path of the final matched global variable override
- `variable_override_paths`: all matched authoring paths from an accumulating override
- `conditions`: the normalized root expression when its gate is unmet
- `variable`: the global variable definition when applicable

## Modules

The before evaluation and after evaluation phases each use the module membership at the start of that phase. Where an evaluation uses bucketing, the bucket key and bucket value phases each use their own starting membership. Adding or removing a module during a phase does not change the iteration already in progress. The next phase uses the membership then installed. A module added before the after phase can receive after callbacks for evaluations already in progress, even if it did not receive their before callbacks. A module removed before the after phase receives no after callback.

Module options expose `dependency_of` and `dependency_purpose` on internal reads. The requester contains `type`, optional `feature_key` and optional `variable_key`. Purpose is `condition` for gating reads or `composition` for consumed source values. Application calls have neither marker. Tracking modules can skip condition reads while retaining composition exposures.

Equivalent dependency reads are memoized within one public call, separating purpose, requester, effective context and current SDK state. Condition snapshots are owned. Composition values retain ordinary getter ownership. Callback options do not retain private sessions. Independent public getters called from callbacks start fresh sessions.

Modules can intercept evaluation and participate in SDK lifecycle. The canonical callbacks are `setup`, `bucket_key`, `bucket_value`, `before_evaluation`, `after_evaluation`, and `close`.

`before_evaluation` and `after_evaluation` run for feature and global variable evaluations. Condition and composition dependency getters use the same module pipeline, while an accumulating override publishes only its final result to `after_evaluation`.

### Defining a module

A module is a simple hash with a unique recommended `name` and optional lifecycle functions:

If `setup` raises an exception, the module is not registered. Featurevisor removes subscriptions created during setup, reports `module_setup_error`, and calls `close` when present.

```ruby
require 'featurevisor'

my_custom_module = {
  # recommended, and used for duplicate detection/removal
  name: 'my-custom-module',

  # rest of the properties below are all optional per module

  # setup once, when the module is registered
  setup: ->(api) {
    revision = api[:get_revision].call

    api[:on_diagnostic].call(->(diagnostic) {
      puts diagnostic[:message]
    })
  },

  # before feature or global variable evaluation
  before_evaluation: ->(options) {
    # update context before evaluation
    options[:context] = options[:context].merge({
      someAdditionalAttribute: 'value'
    })
    options
  },

  # after feature or global variable evaluation
  after_evaluation: ->(evaluation, options) {
    reason = evaluation[:reason]
    if reason == 'error'
      # log error
    end
    evaluation
  },

  # configure bucket key
  bucket_key: ->(options) {
    # return custom bucket key
    options[:bucket_key]
  },

  # configure bucket value (between 0 and 100,000)
  bucket_value: ->(options) {
    # return custom bucket value
    options[:bucket_value]
  },

  # cleanup when module is removed or SDK is closed
  close: -> {
    # cleanup here
  }
}
```

The module API passed to `setup` exposes:

- `get_revision`
- `on_diagnostic`
- `report_diagnostic`

### Registering modules

Register modules when you create the instance:

```ruby
require 'featurevisor'

f = Featurevisor.create_featurevisor(
  modules: [my_custom_module]
)
```

Or after initialization:

```ruby
remove_module = f.add_module(my_custom_module)

# remove later by calling the returned function
remove_module.call

# or remove by name
f.remove_module('my-custom-module')
```

## Child instance

A child snapshots the parent keys that exist when it is spawned. Child values win for those keys. Parent keys introduced later are still inherited. Calling `close` removes both child-owned listeners and subscriptions delegated to the parent.

When dealing with purely client-side applications, it is understandable that there is only one user involved, like in browser or mobile applications.

But when using Featurevisor SDK in server-side applications, where a single server instance can handle multiple user requests simultaneously, it is important to isolate the context for each request.

That's where child instances come in handy:

```ruby
child_f = f.spawn({
  # user or request specific context
  userId: '123'
})
```

Pass the child instance to the request handler to evaluate features for that user:

```ruby
is_enabled = child_f.is_enabled('checkout')
variation = child_f.get_variation('checkout')
variable_value = child_f.get_variable('checkout', 'bgColor')
global_value = child_f.get_variable('welcomeMessage')
```

Similar to parent SDK, child instances also support several additional methods:

- `set_context`
- `set_sticky_features`
- `set_sticky_variables`
- `evaluate_flag`
- `is_enabled`
- `evaluate_variation`
- `get_variation`
- `evaluate_variable`
- `get_variable`
- `get_variable_boolean`
- `get_variable_string`
- `get_variable_integer`
- `get_variable_number`
- `get_variable_array`
- `get_variable_object`
- `get_variable_json`
- `get_feature_evaluations`
- `get_variable_evaluations`
- `on`
- `close`

## Close

Both primary and child instances support a `.close()` method. It removes event listeners and child subscriptions. The primary instance also closes modules, clears diagnostic subscriptions and parsed expression caches, and releases its diagnostic handler after reporting any module shutdown errors. Closing is idempotent.

Ruby can collect unreachable reference cycles, but objects still referenced by your application remain alive. Call unsubscribe functions when finished with individual subscriptions, and close instances and children when finished with them. Retained instance handles still own their datafiles and context. Closing does not promise that every allocation is returned to the operating system.

```ruby
f.close()
```

## OpenFeature

The OpenFeature provider is published as a separate gem. This keeps OpenFeature code and dependencies out of applications that only use the Featurevisor SDK.

The provider currently requires Ruby 3.4 or newer because that is the minimum version supported by the official OpenFeature Ruby SDK.

Install the provider:

```ruby
gem "featurevisor-openfeature", "~> 4.0"
```

It installs the matching `featurevisor` gem and the official `openfeature-sdk ~> 0.6.5` dependency. The provider requires Ruby 3.4 or later, while the separate base gem supports Ruby 3.0 or later without OpenFeature. The provider and base SDK deliberately share the same version, and the provider requires that exact Featurevisor version.

```ruby
require "featurevisor/openfeature_provider"

provider = Featurevisor::OpenFeatureProvider.new(
  datafile: datafile_content,
)

OpenFeature::SDK.configure do |config|
  config.set_provider_and_wait(provider)
end

client = OpenFeature::SDK.build_client
enabled = client.fetch_boolean_value(
  flag_key: "checkout",
  default_value: false,
  evaluation_context: OpenFeature::SDK::EvaluationContext.new(targeting_key: "user-123"),
)
```

Use `checkout` for a flag, `checkout:variation` for its variation, `checkout:title` for its `title` variable, and `variable:welcomeMessage` for a global variable. Boolean variables use the boolean resolver. Arrays, hashes, and JSON variables use the object resolver.

OpenFeature's targeting key maps to `userId` by default. `targeting_key_field`, `key_separator`, `variation_key`, and `global_variable_prefix` can customize the mapping. The global variable prefix defaults to `variable` and cannot contain the separator.

Pass Featurevisor initialization options to the provider to configure the instance it owns:

```ruby
provider = Featurevisor::OpenFeatureProvider.new(
  datafile: datafile_content,
  targeting_key_field: "accountId",
  key_separator: "/",
  variation_key: "$variation",
)
```

Reuse an existing Featurevisor instance:

```ruby
f = Featurevisor.create_featurevisor(datafile: datafile_content)
provider = Featurevisor::OpenFeatureProvider.new(featurevisor: f)
```

The caller owns an instance passed this way. Provider shutdown does not close it. Call `f.close` when every consumer is finished with it. When the provider creates the instance from options, the provider owns and closes it. If both are supplied, `featurevisor` takes precedence over the options hash.

An invalid initial datafile in an owned instance fails `set_provider_and_wait` with a provider initialization error carrying `PARSE_ERROR`, independently of `log_level`. A valid datafile update clears the error and emits readiness. Shutdown removes provider subscriptions and closes only an owned instance.

Root `conditions_unmet` outcomes map to OpenFeature `DISABLED`. Composed values and matched overrides map to `TARGETING_MATCH`. The provider does not decode composed JSON values again.

See the [OpenFeature provider guide](https://featurevisor.com/docs/sdks/openfeature/) for resolution reasons, errors, metadata, tracking, lifecycle, and providers for other languages.

## CLI usage

After adding the gem to your Gemfile as shown in [Installation](#installation), install it with:

```bash
bundle install
```

Use `bundle exec featurevisor` for a bundled installation, `featurevisor` for a global gem installation, or `bin/featurevisor` from this SDK repository.

The native test runner requires `@featurevisor/cli` 4.0.0 or later and Node.js 24 or later. Install the Node.js CLI in your Featurevisor project:

```bash
npm install --save-dev @featurevisor/cli@^4.0.0
```

The native CLI provides `test`, `benchmark` and `assess-distribution`. Use the Node.js CLI for authoring commands such as `init`, `lint` and `build`. Native commands delegate project parsing, test listing, matrix expansion and datafile generation to `npx featurevisor`, then evaluate with this Ruby SDK. The SDK runtime has no Node.js dependency.

Options use kebab case, such as `--project-directory-path`. The camelCase forms from earlier releases still work, and `--root-directory-path` is an alias for `--project-directory-path`. Pass values as `--name=value` or `--name value`. Repeat `--target` to select several targets in order. Run `<command> --help` to list every option.

Duplicate targets are evaluated once, at their first position. `--n` and `-n` accept a positive integer.

### Test

Segment owners and checks run through ordinary SDK gates, including feature and variable dependencies, fixed `at`, context, sticky state and child state. Selected Target segment specializations remain authoritative. Compiled execution definitions restore only missing segments. Attribute only chains may run without an environment. Dependent segments require their selected datafile. Transitive references are preflighted before getters run. Synthetic gates are excluded from coverage. Testing does not automatically run lint.

```bash
bundle exec featurevisor test \
  --project-directory-path=/path/to/featurevisor-project \
  --only-failures
```

See [Testing](https://featurevisor.com/docs/testing/) for authoring specs and [Checks](https://featurevisor.com/docs/testing/#checks) for check syntax and operators.

Useful test options:

- `--key-pattern=<pattern>` and `--assertion-pattern=<pattern>` filter tests.
- `--entity-type=scenario` selects scenarios. `--set=<set>` selects one project set. Omitting `--set` runs all sets.
- `--case=<id>` reruns one expanded case. Copy the opaque ID or rerun command from a failure report.
- `--json --pretty` produces an indented JSON report.
- `--coverage` reports observed rule and override selections. `--uncovered` lists features and global variables without associated specs.
- `--only-failures`, `--quiet`, `--verbose` and `--show-datafile` control diagnostic output.

Printed rerun commands use POSIX shell quoting. JSON reports also include raw argument arrays.

### Test against local monorepo's example-1

Contributor instructions are in the [repository development guide](https://github.com/featurevisor/featurevisor-ruby#development).

### Benchmark

The examples below use a project without environments. Add `--environment=<name>` if your project configures environments. In a sets project, omit `--set` to run every set or pass `--set=<name>`. Repeat `--target=<key>` to evaluate specific target datafiles. The Node.js CLI validates these options and builds the datafiles. Ruby evaluates them. Replace `checkout` with a feature defined in your project.

```bash
bundle exec featurevisor benchmark \
  --project-directory-path=/path/to/featurevisor-project \
  --feature=checkout \
  --context='{"country":"nl"}' \
  --n=1000
```

Use `--variation` for a variation or `--variable=<key>` for a feature variable. Omit `--feature` to benchmark a global variable. Do not combine `--variation` with `--variable`. See [Benchmarking](https://featurevisor.com/docs/cli/#benchmarking).

### Assess distribution

```bash
bundle exec featurevisor assess-distribution \
  --project-directory-path=/path/to/featurevisor-project \
  --feature=checkout \
  --populate-uuid=userId \
  --n=1000
```

Repeat `--populate-uuid=<key>` to generate UUID values for multiple context attributes. Supply one key per option. See [Assess distribution](https://featurevisor.com/docs/cli/#assess-distribution).

## GitHub repositories

- SDK: [featurevisor/featurevisor-ruby](https://github.com/featurevisor/featurevisor-ruby)
- Example application: [featurevisor/featurevisor-example-ruby](https://github.com/featurevisor/featurevisor-example-ruby)

<!-- FEATUREVISOR_DOCS_END -->

<a id="getting-aggregate-evaluations"></a>

The aggregate evaluation reference has moved to [Getting evaluations](#getting-evaluations).

<a id="sticky-features-and-variables"></a>

The sticky state reference has moved to [Sticky](#sticky).

## Development

### Setting up

After checking out the repository, run `make install` to install dependencies.

### Running tests

```bash
$ bundle exec rspec
$ make test-base
$ make test-example-1
```

Run `bundle exec rspec spec/readme_initialization_spec.rb` to execute the actual initialization snippet with simulated HTTP responses and transport errors. This check also runs in the ordinary SDK suite and CI.

Build and verify both gems with:

```bash
$ make build
```

The build produces `featurevisor-VERSION.gem` and `featurevisor-openfeature-VERSION.gem`. The artifact verifier confirms that OpenFeature code and dependencies are absent from the base gem and present only in the provider gem.

### Releasing

The next breaking release is `4.0.0` for both gems. Keep both Gemfile lockfiles aligned with the shared version. Run `make test`, `make test-base` and `make build` before tagging. The artefact check verifies the provider's exact dependency on the base gem and their separate contents.

- Update the shared version in `lib/featurevisor/version.rb`
- Run `bundle install`
- Push commit to `main` branch
- Wait for CI to complete
- Tag the release with the same version number, for example `vX.Y.Z`
- The workflow verifies that the tag matches the shared version
- The workflow publishes `featurevisor` first, followed by `featurevisor-openfeature`

The gems are separate RubyGems packages built from the same repository. Publishing the base gem first ensures the provider's exact Featurevisor dependency is available when the provider is published. If the second push fails, rerun or retry the provider publication without republishing the existing base version.

## License

MIT © [Fahad Heylaal](https://fahad19.com)
