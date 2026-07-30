# frozen_string_literal: true

require "yaml"
require "relaton/itu/data_fetcher" # pulls in Relaton::Index + ::Pubid::Itu

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.disable_monkey_patching!
end

ROOT = File.expand_path("..", __dir__)
