# frozen_string_literal: true

module Featurevisor
  # Semantic version comparison functionality
  # Original: https://github.com/omichelsen/compare-versions
  # Ported from TypeScript to Ruby

  # Regular expression for semantic version parsing
  SEMVER_REGEX = /^[v^~<>=]*?(\d+)(?:\.([x*]|\d+)(?:\.([x*]|\d+)(?:\.([x*]|\d+))?(?:-([\da-z\-]+(?:\.[\da-z\-]+)*))?(?:\+[\da-z\-]+(?:\.[\da-z\-]+)*)?)?)?$/i

  # Validates and parses a version string
  # @param version [String] Version string to validate and parse
  # @return [Array<String>] Array of version segments
  # @raise [TypeError] If version is not a string
  # @raise [ArgumentError] If version is not valid semver
  def self.validate_and_parse(version)
    unless version.is_a?(String)
      raise TypeError, "Invalid argument expected string"
    end

    match = version.match(SEMVER_REGEX)
    unless match
      raise ArgumentError, "Invalid argument not valid semver ('#{version}' received)"
    end

    # Remove the first element (full match) and return the rest
    match.to_a[1..-1]
  end

  # Checks if a string is a wildcard
  # @param s [String] String to check
  # @return [Boolean] True if wildcard
  def self.wildcard?(s)
    s == "*" || s.downcase == "x"
  end

  # Forces types to be the same for comparison
  # @param a [String, Integer] First value
  # @param b [String, Integer] Second value
  # @return [Array] Array with both values converted to same type
  def self.force_type(a, b)
    if a.is_a?(Integer) != b.is_a?(Integer)
      [a.to_s, b.to_s]
    else
      [a, b]
    end
  end

  # Tries to parse a string as an integer
  # @param v [String] String to parse
  # @return [Integer, String] Parsed integer or original string
  def self.try_parse(v)
    Integer(v, 10)
  rescue ArgumentError
    v
  end

  # Compares two strings for version comparison
  # @param a [String] First string
  # @param b [String] Second string
  # @return [Integer] -1 if a < b, 0 if equal, 1 if a > b
  def self.compare_strings(a, b)
    return 0 if wildcard?(a) || wildcard?(b)

    ap, bp = force_type(try_parse(a), try_parse(b))

    if ap > bp
      1
    elsif ap < bp
      -1
    else
      0
    end
  end

  # Compares version segments
  # @param a [Array<String>, MatchData] First version segments
  # @param b [Array<String>, MatchData] Second version segments
  # @return [Integer] -1 if a < b, 0 if equal, 1 if a > b
  def self.compare_segments(a, b)
    # Convert to arrays if needed
    a_array = a.is_a?(MatchData) ? a.to_a[1..-1] : a.to_a
    b_array = b.is_a?(MatchData) ? b.to_a[1..-1] : b.to_a

    max_length = [a_array.length, b_array.length].max

    (0...max_length).each do |i|
      a_val = a_array[i] || "0"
      b_val = b_array[i] || "0"

      result = compare_strings(a_val, b_val)
      return result unless result == 0
    end

    0
  end

  # Compares two version strings
  # @param v1 [String] First version string
  # @param v2 [String] Second version string
  # @return [Integer] -1 if v1 < v2, 0 if equal, 1 if v1 > v2
  # @raise [TypeError] If either version is not a string
  # @raise [ArgumentError] If either version is not valid semver
  def self.compare_versions(v1, v2)
    # Validate input and split into segments
    n1 = validate_and_parse(v1)
    n2 = validate_and_parse(v2)

    # Pop off the patch
    p1 = n1.pop
    p2 = n2.pop

    # Validate numbers
    r = compare_segments(n1, n2)
    return r unless r == 0

    # Validate pre-release
    if p1 && p2
      compare_segments(p1.split("."), p2.split("."))
    elsif p1 || p2
      p1 ? -1 : 1
    else
      0
    end
  end
end
