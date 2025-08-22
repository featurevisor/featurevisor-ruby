# Featurevisor Ruby SDK <!-- omit in toc -->

This is a port of Featurevisor [JavaScript SDK](https://featurevisor.com/docs/sdks/javascript/) v2.x to Ruby, providing a way to evaluate feature flags, variations, and variables in your Ruby applications.

This SDK is compatible with [Featurevisor](https://featurevisor.com/) v2.0 projects and above.

## Table of contents <!-- omit in toc -->

- [Installation](#installation)
- [Initialization](#initialization)
- [Evaluation types](#evaluation-types)
- [Context](#context)
  - [Setting initial context](#setting-initial-context)
  - [Setting after initialization](#setting-after-initialization)
  - [Replacing existing context](#replacing-existing-context)
  - [Manually passing context](#manually-passing-context)
- [Check if enabled](#check-if-enabled)
- [Getting variation](#getting-variation)
- [Getting variables](#getting-variables)
  - [Type specific methods](#type-specific-methods)
- [Getting all evaluations](#getting-all-evaluations)
- [Sticky](#sticky)
  - [Initialize with sticky](#initialize-with-sticky)
  - [Set sticky afterwards](#set-sticky-afterwards)
- [Setting datafile](#setting-datafile)
  - [Updating datafile](#updating-datafile)
  - [Interval-based update](#interval-based-update)
- [Logging](#logging)
  - [Levels](#levels)
  - [Customizing levels](#customizing-levels)
  - [Handler](#handler)
- [Events](#events)
  - [`datafile_set`](#datafile_set)
  - [`context_set`](#context_set)
  - [`sticky_set`](#sticky_set)
- [Evaluation details](#evaluation-details)
- [Hooks](#hooks)
  - [Defining a hook](#defining-a-hook)
  - [Registering hooks](#registering-hooks)
- [Child instance](#child-instance)
- [Close](#close)
- [CLI usage](#cli-usage)
  - [Test](#test)
  - [Benchmark](#benchmark)
  - [Assess distribution](#assess-distribution)
- [Development](#development)
  - [Setting up](#setting-up)
  - [Running tests](#running-tests)
  - [Releasing](#releasing)
- [License](#license)

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'featurevisor'
```

And then execute:

```bash
$ bundle install
```

Or install it yourself as:

```bash
$ gem install featurevisor
```

## Initialization

The SDK can be initialized by passing [datafile](https://featurevisor.com/docs/building-datafiles/) content directly:

```ruby
require 'featurevisor'
require 'net/http'
require 'json'

# Fetch datafile from URL
datafile_url = 'https://cdn.yoursite.com/datafile.json'
response = Net::HTTP.get_response(URI(datafile_url))

# Parse JSON with symbolized keys (required)
datafile_content = JSON.parse(response.body, symbolize_names: true)

# Create SDK instance
f = Featurevisor.create_instance(
  datafile: datafile_content
)
```

**Important**: When parsing JSON datafiles, you must use `symbolize_names: true` to ensure proper key handling by the SDK.

Alternatively, you can pass a JSON string directly and the SDK will parse it automatically:

```ruby
# Option 1: Parse JSON yourself (recommended)
datafile_content = JSON.parse(json_string, symbolize_names: true)
f = Featurevisor.create_instance(datafile: datafile_content)

# Option 2: Pass JSON string directly (automatic parsing)
f = Featurevisor.create_instance(datafile: json_string)
```

## Evaluation types

We can evaluate 3 types of values against a particular [feature](https://featurevisor.com/docs/features/):

- [**Flag**](#check-if-enabled) (`boolean`): whether the feature is enabled or not
- [**Variation**](#getting-variation) (`string`): the variation of the feature (if any)
- [**Variables**](#getting-variables): variable values of the feature (if any)

These evaluations are run against the provided context.

## Context

Contexts are [attribute](https://featurevisor.com/docs/attributes/) values that we pass to SDK for evaluating [features](https://featurevisor.com/docs/features/) against.

Think of the conditions that you define in your [segments](https://featurevisor.com/docs/segments/), which are used in your feature's [rules](https://featurevisor.com/docs/features/#rules).

They are plain hashes:

```ruby
context = {
  userId: '123',
  country: 'nl',
  # ...other attributes
}
```

Context can be passed to SDK instance in various different ways, depending on your needs:

### Setting initial context

You can set context at the time of initialization:

```ruby
require 'featurevisor'

f = Featurevisor.create_instance(
  context: {
    deviceId: '123',
    country: 'nl'
  }
)
```

This is useful for values that don't change too frequently and available at the time of application startup.

### Setting after initialization

You can also set more context after the SDK has been initialized:

```ruby
f.set_context({
  userId: '234'
})
```

This will merge the new context with the existing one (if already set).

### Replacing existing context

If you wish to fully replace the existing context, you can pass `true` in second argument:

```ruby
f.set_context({
  deviceId: '123',
  userId: '234',
  country: 'nl',
  browser: 'chrome'
}, true) # replace existing context
```

### Manually passing context

You can optionally pass additional context manually for each and every evaluation separately, without needing to set it to the SDK instance affecting all evaluations:

```ruby
context = {
  userId: '123',
  country: 'nl'
}

is_enabled = f.is_enabled('my_feature', context)
variation = f.get_variation('my_feature', context)
variable_value = f.get_variable('my_feature', 'my_variable', context)
```

When manually passing context, it will merge with existing context set to the SDK instance before evaluating the specific value.

Further details for each evaluation types are described below.

## Check if enabled

Once the SDK is initialized, you can check if a feature is enabled or not:

```ruby
feature_key = 'my_feature'

is_enabled = f.is_enabled(feature_key)

if is_enabled
  # do something
end
```

You can also pass additional context per evaluation:

```ruby
is_enabled = f.is_enabled(feature_key, {
  # ...additional context
})
```

## Getting variation

If your feature has any [variations](https://featurevisor.com/docs/features/#variations) defined, you can evaluate them as follows:

```ruby
feature_key = 'my_feature'

variation = f.get_variation(feature_key)

if variation == 'treatment'
  # do something for treatment variation
else
  # handle default/control variation
end
```

Additional context per evaluation can also be passed:

```ruby
variation = f.get_variation(feature_key, {
  # ...additional context
})
```

## Getting variables

Your features may also include [variables](https://featurevisor.com/docs/features/#variables), which can be evaluated as follows:

```ruby
variable_key = 'bgColor'

bg_color_value = f.get_variable('my_feature', variable_key)
```

Additional context per evaluation can also be passed:

```ruby
bg_color_value = f.get_variable('my_feature', variable_key, {
  # ...additional context
})
```

### Type specific methods

Next to generic `get_variable()` methods, there are also type specific methods available for convenience:

```ruby
f.get_variable_boolean(feature_key, variable_key, context = {})
f.get_variable_string(feature_key, variable_key, context = {})
f.get_variable_integer(feature_key, variable_key, context = {})
f.get_variable_double(feature_key, variable_key, context = {})
f.get_variable_array(feature_key, variable_key, context = {})
f.get_variable_object(feature_key, variable_key, context = {})
f.get_variable_json(feature_key, variable_key, context = {})
```

## Getting all evaluations

You can get evaluations of all features available in the SDK instance:

```ruby
all_evaluations = f.get_all_evaluations({})

puts all_evaluations
# {
#   myFeature: {
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

## Sticky

For the lifecycle of the SDK instance in your application, you can set some features with sticky values, meaning that they will not be evaluated against the fetched [datafile](https://featurevisor.com/docs/building-datafiles/):

### Initialize with sticky

```ruby
require 'featurevisor'

f = Featurevisor.create_instance(
  sticky: {
    myFeatureKey: {
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
  }
)
```

Once initialized with sticky features, the SDK will look for values there first before evaluating the targeting conditions and going through the bucketing process.

### Set sticky afterwards

You can also set sticky features after the SDK is initialized:

```ruby
f.set_sticky({
  myFeatureKey: {
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

**Important**: When calling `set_datafile()`, ensure JSON is parsed with `symbolize_names: true` if you're parsing it yourself.

### Updating datafile

You can set the datafile as many times as you want in your application, which will result in emitting a [`datafile_set`](#datafile_set) event that you can listen and react to accordingly.

The triggers for setting the datafile again can be:

- periodic updates based on an interval (like every 5 minutes), or
- reacting to:
  - a specific event in your application (like a user action), or
  - an event served via websocket or server-sent events (SSE)

### Interval-based update

Here's an example of using interval-based update:

```ruby
require 'net/http'
require 'json'

def update_datafile(f, datafile_url)
  loop do
    sleep(5 * 60) # 5 minutes
    
    begin
      response = Net::HTTP.get_response(URI(datafile_url))
      datafile_content = JSON.parse(response.body)
      f.set_datafile(datafile_content)
    rescue => e
      # handle error
      puts "Failed to update datafile: #{e.message}"
    end
  end
end

# Start the update thread
Thread.new { update_datafile(f, datafile_url) }
```

## Logging

By default, Featurevisor SDKs will print out logs to the console for `info` level and above.

### Levels

These are all the available log levels:

- `error`
- `warn`
- `info`
- `debug`

### Customizing levels

If you choose `debug` level to make the logs more verbose, you can set it at the time of SDK initialization.

Setting `debug` level will print out all logs, including `info`, `warn`, and `error` levels.

```ruby
require 'featurevisor'

f = Featurevisor.create_instance(
  logger: Featurevisor.create_logger(level: 'debug')
)
```

Alternatively, you can also set `log_level` directly:

```ruby
f = Featurevisor.create_instance(
  log_level: 'debug'
)
```

You can also set log level from SDK instance afterwards:

```ruby
f.set_log_level('debug')
```

### Handler

You can also pass your own log handler, if you do not wish to print the logs to the console:

```ruby
require 'featurevisor'

f = Featurevisor.create_instance(
  logger: Featurevisor.create_logger(
    level: 'info',
    handler: ->(level, message, details) {
      # do something with the log
    }
  )
)
```

Further log levels like `info` and `debug` will help you understand how the feature variations and variables are evaluated in the runtime against given context.

## Events

Featurevisor SDK implements a simple event emitter that allows you to listen to events that happen in the runtime.

You can listen to these events that can occur at various stages in your application:

### `datafile_set`

```ruby
unsubscribe = f.on('datafile_set') do |event|
  revision = event[:revision]        # new revision
  previous_revision = event[:previous_revision]
  revision_changed = event[:revision_changed] # true if revision has changed

  # list of feature keys that have new updates,
  # and you should re-evaluate them
  features = event[:features]

  # handle here
end

# stop listening to the event
unsubscribe.call
```

The `features` array will contain keys of features that have either been:

- added, or
- updated, or
- removed

compared to the previous datafile content that existed in the SDK instance.

### `context_set`

```ruby
unsubscribe = f.on('context_set') do |event|
  replaced = event[:replaced] # true if context was replaced
  context = event[:context]   # the new context

  puts 'Context set'
end
```

### `sticky_set`

```ruby
unsubscribe = f.on('sticky_set') do |event|
  replaced = event[:replaced] # true if sticky features got replaced
  features = event[:features] # list of all affected feature keys

  puts 'Sticky features set'
end
```

## Evaluation details

Besides logging with debug level enabled, you can also get more details about how the feature variations and variables are evaluated in the runtime against given context:

```ruby
# flag
evaluation = f.evaluate_flag(feature_key, context = {})

# variation
evaluation = f.evaluate_variation(feature_key, context = {})

# variable
evaluation = f.evaluate_variable(feature_key, variable_key, context = {})
```

The returned object will always contain the following properties:

- `feature_key`: the feature key
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

## Hooks

Hooks allow you to intercept the evaluation process and customize it further as per your needs.

### Defining a hook

A hook is a simple hash with a unique required `name` and optional functions:

```ruby
require 'featurevisor'

my_custom_hook = {
  # only required property
  name: 'my-custom-hook',

  # rest of the properties below are all optional per hook

  # before evaluation
  before: ->(options) {
    # update context before evaluation
    options[:context] = options[:context].merge({
      someAdditionalAttribute: 'value'
    })
    options
  },

  # after evaluation
  after: ->(evaluation, options) {
    reason = evaluation[:reason]
    if reason == 'error'
      # log error
      return
    end
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
  }
}
```

### Registering hooks

You can register hooks at the time of SDK initialization:

```ruby
require 'featurevisor'

f = Featurevisor.create_instance(
  hooks: [my_custom_hook]
)
```

Or after initialization:

```ruby
f.add_hook(my_custom_hook)
```

## Child instance

When dealing with purely client-side applications, it is understandable that there is only one user involved, like in browser or mobile applications.

But when using Featurevisor SDK in server-side applications, where a single server instance can handle multiple user requests simultaneously, it is important to isolate the context for each request.

That's where child instances come in handy:

```ruby
child_f = f.spawn({
  # user or request specific context
  userId: '123'
})
```

Now you can pass the child instance where your individual request is being handled, and you can continue to evaluate features targeting that specific user alone:

```ruby
is_enabled = child_f.is_enabled('my_feature')
variation = child_f.get_variation('my_feature')
variable_value = child_f.get_variable('my_feature', 'my_variable')
```

Similar to parent SDK, child instances also support several additional methods:

- `set_context`
- `set_sticky`
- `is_enabled`
- `get_variation`
- `get_variable`
- `get_variable_boolean`
- `get_variable_string`
- `get_variable_integer`
- `get_variable_double`
- `get_variable_array`
- `get_variable_object`
- `get_variable_json`
- `get_all_evaluations`
- `on`
- `close`

## Close

Both primary and child instances support a `.close()` method, that removes forgotten event listeners (via `on` method) and cleans up any potential memory leaks.

```ruby
f.close()
```

## CLI usage

This package also provides a CLI tool for running your Featurevisor [project](https://featurevisor.com/docs/projects/)'s test specs and benchmarking against this Ruby SDK.

- Global installation: you can access it as `featurevisor`
- Local installation: you can access it as `bundle exec featurevisor`
- From this repository: you can access it as `bin/featurevisor`

### Test

Learn more about testing [here](https://featurevisor.com/docs/testing/).

```bash
$ bundle exec featurevisor test --projectDirectoryPath="/absolute/path/to/your/featurevisor/project"
```

Additional options that are available:

```bash
$ bundle exec featurevisor test \
  --projectDirectoryPath="/absolute/path/to/your/featurevisor/project" \
  --quiet|verbose \
  --onlyFailures \
  --keyPattern="myFeatureKey" \
  --assertionPattern="#1"
```

### Benchmark

Learn more about benchmarking [here](https://featurevisor.com/docs/cmd/#benchmarking).

```bash
$ bundle exec featurevisor benchmark \
  --projectDirectoryPath="/absolute/path/to/your/featurevisor/project" \
  --environment="production" \
  --feature="myFeatureKey" \
  --context='{"country": "nl"}' \
  --n=1000
```

### Assess distribution

Learn more about assessing distribution [here](https://featurevisor.com/docs/cmd/#assess-distribution).

```bash
$ bundle exec featurevisor assess-distribution \
  --projectDirectoryPath="/absolute/path/to/your/featurevisor/project" \
  --environment=production \
  --feature=foo \
  --variation \
  --context='{"country": "nl"}' \
  --populateUuid=userId \
  --populateUuid=deviceId \
  --n=1000
```

## Development

### Setting up

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

### Running tests

```bash
$ bundle exec rspec
```

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

### Releasing

- Update version in `lib/featurevisor/version.rb`
- Run `bundle install`
- Push commit to `main` branch
- Wait for CI to complete
- Tag the release with the version number
- This will trigger a new release to [RubyGems](https://rubygems.org/gems/featurevisor)

## License

MIT © [Fahad Heylaal](https://fahad19.com)
