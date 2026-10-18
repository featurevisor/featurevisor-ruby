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
    unless match && version.ascii_only? && match[0] == version
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

  # Compares two strings for version comparison
  # @param a [String] First string
  # @param b [String] Second string
  # @return [Integer] -1 if a < b, 0 if equal, 1 if a > b
  def self.compare_strings(a, b, prerelease = false)
    return 0 if !prerelease && (wildcard?(a) || wildcard?(b))
    an = /\A[0-9]+\z/.match?(a)
    bn = /\A[0-9]+\z/.match?(b)
    if an && bn
      a = a.sub(/\A0+/, "")
      b = b.sub(/\A0+/, "")
      return a.length <=> b.length if a.length != b.length
    elsif prerelease && an != bn
      return an ? -1 : 1
    end
    a <=> b
  end

  # Compares version segments
  # @param a [Array<String>, MatchData] First version segments
  # @param b [Array<String>, MatchData] Second version segments
  # @return [Integer] -1 if a < b, 0 if equal, 1 if a > b
  def self.compare_segments(a, b, prerelease = false)
    # Convert to arrays if needed
    a_array = a.is_a?(MatchData) ? a.to_a[1..-1] : a.to_a
    b_array = b.is_a?(MatchData) ? b.to_a[1..-1] : b.to_a

    max_length = [a_array.length, b_array.length].max

    (0...max_length).each do |i|
      if prerelease && (i == a_array.length || i == b_array.length)
        return a_array.length <=> b_array.length
      end
      a_val = a_array[i] || "0"
      b_val = b_array[i] || "0"

      result = compare_strings(a_val, b_val, prerelease)
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
      compare_segments(p1.split("."), p2.split("."), true)
    elsif p1 || p2
      p1 ? -1 : 1
    else
      0
    end
  end
end
