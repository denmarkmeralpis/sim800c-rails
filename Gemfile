# frozen_string_literal: true

source "https://rubygems.org"

gemspec

rails_requirement = ENV.fetch("RAILS_VERSION", ">= 7.2")
gem "rails", rails_requirement

group :development, :test do
  # Rails < 8.1's test runner does not support Minitest 6.
  gem "minitest", rails_requirement.match?(/\A~> (7\.|8\.0)/) ? "~> 5.25" : ">= 5.25"
  gem "puma"
  gem "rake"
  gem "sqlite3"
end
