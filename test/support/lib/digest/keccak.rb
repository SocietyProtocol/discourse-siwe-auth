# frozen_string_literal: true

# Pure-Ruby Keccak-256 fallback for the standalone tests (see ../../pure_keccak.rb).

module Digest
  class Keccak
    MASK = (1 << 64) - 1
    ROUND_CONSTANTS = [
      0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
      0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
      0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
      0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
      0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
      0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
    ].freeze
    ROTATIONS = [
      [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
      [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]
    ].freeze

    def initialize(bits)
      raise ArgumentError, 'only Keccak-256 is supported' unless bits == 256
    end

    def digest(data)
      rate = 136
      msg = data.to_s.b + "\x01".b
      msg << ("\x00".b * ((rate - msg.bytesize % rate) % rate))
      msg.setbyte(msg.bytesize - 1, msg.getbyte(msg.bytesize - 1) | 0x80)

      state = Array.new(5) { Array.new(5, 0) }
      msg.bytes.each_slice(rate) do |block|
        block.each_slice(8).with_index do |lane, i|
          state[i % 5][i / 5] ^= lane.each_with_index.sum { |b, j| b << (8 * j) }
        end
        permute(state)
      end

      out = []
      (0...4).each { |i| v = state[i % 5][i / 5]; 8.times { |j| out << ((v >> (8 * j)) & 0xff) } }
      out.pack('C*')
    end

    private

    def rotl(v, n)
      n.zero? ? v : ((v << n) | (v >> (64 - n))) & MASK
    end

    def permute(a)
      ROUND_CONSTANTS.each do |rc|
        c = (0...5).map { |x| a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] }
        d = (0...5).map { |x| c[(x - 1) % 5] ^ rotl(c[(x + 1) % 5], 1) }
        (0...5).each { |x| (0...5).each { |y| a[x][y] ^= d[x] } }

        b = Array.new(5) { Array.new(5, 0) }
        (0...5).each do |x|
          (0...5).each { |y| b[y][(2 * x + 3 * y) % 5] = rotl(a[x][y], ROTATIONS[x][y]) }
        end

        (0...5).each do |x|
          (0...5).each { |y| a[x][y] = b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) }
        end
        a[0][0] ^= rc
      end
    end
  end
end
