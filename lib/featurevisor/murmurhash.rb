# frozen_string_literal: true

module Featurevisor
  # MurmurHash v3 implementation ported from TypeScript
  # Original: https://github.com/perezd/node-murmurhash
  # @param key [String, Array<Integer>] Input key to hash
  # @param seed [Integer] Seed value for the hash
  # @return [Integer] 32-bit hash value
  def self.murmur_hash_v3(key, seed)
    # Convert string to bytes if needed
    key = key.bytes if key.is_a?(String)

    remainder = key.length & 3  # key.length % 4
    bytes = key.length - remainder
    h1 = seed
    c1 = 0xcc9e2d51
    c2 = 0x1b873593
    i = 0

    # Process 4-byte chunks
    while i < bytes
      k1 = (key[i] & 0xff) |
            ((key[i + 1] & 0xff) << 8) |
            ((key[i + 2] & 0xff) << 16) |
            ((key[i + 3] & 0xff) << 24)
      i += 4

      k1 = ((k1 & 0xffff) * c1 + ((((k1 >> 16) * c1) & 0xffff) << 16)) & 0xffffffff
      k1 = (k1 << 15) | (k1 >> 17)
      k1 = ((k1 & 0xffff) * c2 + ((((k1 >> 16) * c2) & 0xffff) << 16)) & 0xffffffff

      h1 ^= k1
      h1 = (h1 << 13) | (h1 >> 19)
      h1b = ((h1 & 0xffff) * 5 + ((((h1 >> 16) * 5) & 0xffff) << 16)) & 0xffffffff
      h1 = (h1b & 0xffff) + 0x6b64 + ((((h1b >> 16) + 0xe654) & 0xffff) << 16)
    end

    # Process remaining bytes
    k1 = 0

    # Handle remainder processing with fall-through behavior like TypeScript switch
    if remainder >= 3
      k1 ^= (key[i + 2] & 0xff) << 16
    end
    if remainder >= 2
      k1 ^= (key[i + 1] & 0xff) << 8
    end
    if remainder >= 1
      k1 ^= key[i] & 0xff

      k1 = ((k1 & 0xffff) * c1 + ((((k1 >> 16) * c1) & 0xffff) << 16)) & 0xffffffff
      k1 = (k1 << 15) | (k1 >> 17)
      k1 = ((k1 & 0xffff) * c2 + ((((k1 >> 16) * c2) & 0xffff) << 16)) & 0xffffffff
      h1 ^= k1
    end

    h1 ^= key.length

    # Final mixing - use unsigned right shift equivalent
    h1 ^= h1 >> 16
    h1 = ((h1 & 0xffff) * 0x85ebca6b + ((((h1 >> 16) * 0x85ebca6b) & 0xffff) << 16)) & 0xffffffff
    h1 ^= h1 >> 13
    h1 = ((h1 & 0xffff) * 0xc2b2ae35 + ((((h1 >> 16) * 0xc2b2ae35) & 0xffff) << 16)) & 0xffffffff
    h1 ^= h1 >> 16

    # Convert to unsigned 32-bit integer (equivalent to >>> 0 in TypeScript)
    h1 & 0xffffffff
  end
end
