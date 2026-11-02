# frozen_string_literal: true

module Sim800c
  # Phone number, dial string and USSD code normalisation.
  module Phone
    SEPARATORS = /[[:space:]\-().]/

    module_function

    # Strips spaces, dashes, dots and parentheses and validates the result (optional leading +,
    # 3-20 digits; short codes allowed).
    def normalize(input)
      n = input.to_s.strip.gsub(SEPARATORS, "")
      raise AppError.bad_request("Invalid phone number: \"#{input}\"") unless n.match?(/\A\+?\d{3,20}\z/)

      n
    end

    # Dial strings may additionally contain * and # (USSD-style / extensions).
    def normalize_dial_string(input)
      n = input.to_s.strip.gsub(SEPARATORS, "")
      raise AppError.bad_request("Invalid phone number: \"#{input}\"") unless n.match?(/\A\+?[0-9*#]{2,32}\z/)

      n
    end

    # USSD and supplementary service codes start with * or # and end with # (*123#, *143*2#).
    def ussd_code?(string)
      string.to_s.match?(/\A[*#][0-9*#]{1,30}#\z/)
    end

    def normalize_ussd_code(input)
      n = input.to_s.strip.gsub(/[[:space:]]/, "")
      unless ussd_code?(n)
        raise AppError.bad_request("Invalid USSD code: \"#{input}\" (expected something like *123#)")
      end

      n
    end

    # Loose equality for numbers the network may report in a different format
    # (09171234567 vs +639171234567): compares the trailing 9 digits.
    def match?(a, b)
      da = a.to_s.gsub(/\D/, "")
      db = b.to_s.gsub(/\D/, "")
      return a == b if da.empty? || db.empty?

      n = [9, da.size, db.size].min
      da[-n..] == db[-n..]
    end
  end
end
