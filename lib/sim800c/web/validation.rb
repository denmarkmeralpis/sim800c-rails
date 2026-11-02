# frozen_string_literal: true

module Sim800c
  # 400 with every invalid field: {"code": "validation_error", "details": [{path, message}]}.
  class ValidationError < AppError
    def initialize(issues)
      first = issues.first
      message = first ? [first[:path].to_s.empty? ? nil : first[:path], first[:message]].compact.join(": ") : "Invalid request"
      super(400, "validation_error", message, issues)
    end
  end

  module Web
    # Validates a JSON body or query string field by field (the zod schemas of sms-gateway).
    #
    #   v = Validation.new(body)
    #   text = v.string("message", min: 1, max: 5000, min_message: "Message text is required")
    #   v.validate!   # raises ValidationError listing every issue
    class Validation
      MISSING = Object.new.freeze
      private_constant :MISSING

      # coerce: true for query strings (values arrive as strings, like z.coerce).
      def initialize(input, coerce: false)
        @input = input.is_a?(Hash) ? input : nil
        @coerce = coerce
        @issues = []
        @issues << { path: "", message: "Invalid input: expected object" } unless @input
      end

      def issues = @issues.dup

      def validate!
        raise ValidationError, @issues if @issues.any?

        self
      end

      def string(key, min: nil, max: nil, trim: false, format: nil, format_message: nil, min_message: nil,
                 optional: false)
        value = fetch(key)
        return nil if value.equal?(MISSING) && optional
        return issue(key, "Invalid input: expected string, received #{type_name(value)}") unless value.is_a?(String)

        value = value.strip if trim
        return issue(key, min_message || "Too small: expected string to have >=#{min} characters") if min && value.size < min
        return issue(key, "Too big: expected string to have <=#{max} characters") if max && value.size > max
        return issue(key, format_message || "Invalid string: must match pattern #{format.inspect}") if format && !format.match?(value)

        value
      end

      def integer(key, min: nil, max: nil, default: MISSING, optional: false)
        value = number_value(key, default: default, optional: optional) or return nil
        return issue(key, "Invalid input: expected int, received number") unless value == value.to_i

        bounded(key, value.to_i, min, max)
      end

      def number(key, min: nil, max: nil, default: MISSING, optional: false)
        value = number_value(key, default: default, optional: optional) or return nil
        bounded(key, value, min, max)
      end

      def boolean(key, default: MISSING)
        value = fetch(key)
        return default if value.equal?(MISSING) && !default.equal?(MISSING)
        return value if [true, false].include?(value)

        issue(key, "Invalid input: expected boolean, received #{type_name(value)}")
      end

      def enum(key, values, optional: true)
        value = fetch(key)
        return nil if value.equal?(MISSING) && optional
        return value if values.include?(value)

        issue(key, "Invalid option: expected one of #{values.map { |v| %("#{v}") }.join('|')}")
      end

      # Query flag: "true" / "1" are true; "false" / "0" / absent are false.
      def flag(key)
        value = fetch(key)
        return false if value.equal?(MISSING)
        return %w[true 1].include?(value) if %w[true false 1 0].include?(value)

        issue(key, 'Invalid option: expected one of "true"|"false"|"1"|"0"')
        false
      end

      # {"ids": [positive integers]}, 1 to 1000 of them.
      def ids(key = "ids")
        value = fetch(key)
        return issue(key, "Invalid input: expected array, received #{type_name(value)}") unless value.is_a?(Array)
        return issue(key, "Select at least one item") if value.empty?
        return issue(key, "Too big: expected array to have <=1000 items") if value.size > 1000

        bad = value.index { |id| !(id.is_a?(Integer) && id.positive?) }
        return issue("#{key}.#{bad}", "Invalid input: expected a positive integer") if bad

        value.uniq
      end

      def enum_array(key, values, min_message:)
        value = fetch(key)
        return issue(key, "Invalid input: expected array, received #{type_name(value)}") unless value.is_a?(Array)

        bad = value.index { |v| !values.include?(v) }
        return issue("#{key}.#{bad}", "Invalid option: expected one of #{values.map { |v| %("#{v}") }.join('|')}") if bad
        return issue(key, min_message) if value.empty?

        value
      end

      # page >= 1 (default 1), limit 1-200 (default 50).
      def pagination(max_limit: 200)
        [integer("page", min: 1, default: 1), integer("limit", min: 1, max: max_limit, default: 50)]
      end

      def raw(key) = (v = fetch(key)).equal?(MISSING) ? nil : v

      def issue(path, message)
        @issues << { path: path.to_s, message: message }
        nil
      end

      private

      def fetch(key)
        return MISSING unless @input

        @input.key?(key.to_s) ? @input[key.to_s] : MISSING
      end

      def number_value(key, default:, optional:)
        value = fetch(key)
        if value.equal?(MISSING) || (@coerce && value == "")
          return default unless default.equal?(MISSING)
          return nil if optional

          return issue(key, "Invalid input: expected number, received undefined")
        end
        if @coerce && value.is_a?(String)
          value = begin
            Float(value)
          rescue ArgumentError
            nil
          end
        end
        return value if value.is_a?(Numeric) && value.finite?

        issue(key, "Invalid input: expected number, received #{value.nil? ? 'NaN' : type_name(value)}")
      end

      def bounded(key, value, min, max)
        return issue(key, "Too small: expected number to be >=#{min}") if min && value < min
        return issue(key, "Too big: expected number to be <=#{max}") if max && value > max

        value
      end

      def type_name(value)
        case value
        when MISSING then "undefined"
        when nil then "null"
        when String then "string"
        when Integer, Float then "number"
        when true, false then "boolean"
        when Array then "array"
        else "object"
        end
      end
    end
  end
end
