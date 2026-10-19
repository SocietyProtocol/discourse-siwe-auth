# frozen_string_literal: true

# Makes `require 'digest/keccak'` work in the standalone tests. Uses the
# native `keccak` gem when installed (plugin gems dir or system), otherwise a
# pure-Ruby Keccak-256 with the same `Digest::Keccak.new(256).digest(data)` API.
#
# Usage: require_relative 'support/pure_keccak' before loading lib/ files.

$LOAD_PATH.unshift(*Dir[File.join(__dir__, '..', '..', 'gems/*/gems/keccak-*/lib')])
begin
  require 'digest/keccak'
rescue LoadError
  $LOAD_PATH.unshift(File.join(__dir__, 'lib'))
  require 'digest/keccak'
end
