#!/usr/bin/env ruby
# frozen_string_literal: true

Encoding.default_external = Encoding::UTF_8

Dir[File.join(__dir__, "tests/test_*.rb")].sort.each { |path| require path }
