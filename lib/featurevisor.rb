require_relative "featurevisor/version"
require_relative "featurevisor/murmurhash"
require_relative "featurevisor/compare_versions"
require_relative "featurevisor/logger"
require_relative "featurevisor/emitter"
require_relative "featurevisor/conditions"
require_relative "featurevisor/datafile_reader"
require_relative "featurevisor/bucketer"
require_relative "featurevisor/hooks"
require_relative "featurevisor/evaluate"
require_relative "featurevisor/instance"
require_relative "featurevisor/child_instance"
require_relative "featurevisor/events"

module Featurevisor
  class Error < StandardError; end
end
