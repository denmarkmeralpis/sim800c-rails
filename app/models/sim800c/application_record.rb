# frozen_string_literal: true

module Sim800c
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    # Escapes LIKE wildcards in user input (used with ESCAPE '\').
    def self.like_pattern(query)
      "%#{query.to_s.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
    end

    def self.iso(time) = Sim800c.iso(time)
  end
end
