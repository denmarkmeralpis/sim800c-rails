# frozen_string_literal: true

module Sim800c
  module PDU
    # GSM 03.38 default alphabet and extension table, plus 7-bit packing helpers.
    module GSM7
      ESC = 0x1b

      BASIC = [
        "@", "£", "$", "¥", "è", "é", "ù", "ì", "ò", "Ç", "\n", "Ø", "ø", "\r", "Å", "å",
        "Δ", "_", "Φ", "Γ", "Λ", "Ω", "Π", "Ψ", "Σ", "Θ", "Ξ", "\e", "Æ", "æ", "ß", "É",
        " ", "!", "\"", "#", "¤", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
        "¡", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
        "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "Ä", "Ö", "Ñ", "Ü", "§",
        "¿", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
        "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "ä", "ö", "ñ", "ü", "à"
      ].map(&:freeze).freeze

      EXTENSION = {
        0x0a => "\f", 0x14 => "^", 0x28 => "{", 0x29 => "}", 0x2f => "\\",
        0x3c => "[", 0x3d => "~", 0x3e => "]", 0x40 => "|", 0x65 => "€"
      }.freeze

      ALPHABET_SIZE = BASIC.size

      BASIC_LOOKUP = BASIC.each_with_index.each_with_object({}) { |(ch, i), h| h[ch] = i unless i == ESC }.freeze
      EXTENSION_LOOKUP = EXTENSION.invert.freeze
      private_constant :BASIC_LOOKUP, :EXTENSION_LOOKUP

      module_function

      # Septets a character occupies (1, or 2 for extension characters), or nil when it is not
      # representable in GSM 7-bit.
      def char_length(ch)
        return 1 if BASIC_LOOKUP.key?(ch)
        return 2 if EXTENSION_LOOKUP.key?(ch)

        nil
      end

      def gsm7?(text)
        text.each_char.all? { |ch| char_length(ch) }
      end

      def to_septets(text)
        text.each_char.each_with_object([]) do |ch, out|
          if (b = BASIC_LOOKUP[ch])
            out << b
          elsif (e = EXTENSION_LOOKUP[ch])
            out << ESC << e
          else
            raise Error, "Character \"#{ch}\" is not in the GSM 7-bit alphabet"
          end
        end
      end

      def from_septets(septets)
        out = +""
        i = 0
        while i < septets.size
          s = septets[i]
          if s == ESC
            i += 1
            nxt = septets[i]
            break if nxt.nil?

            # Unknown extension codes fall back to the basic character (per 03.38).
            out << (EXTENSION[nxt] || BASIC[nxt] || "")
          else
            out << (BASIC[s] || "")
          end
          i += 1
        end
        out
      end

      # Packs septets LSB-first into octets, starting after `fill_bits` padding bits.
      def pack_septets(septets, fill_bits = 0)
        out = Array.new((fill_bits + (septets.size * 7) + 7) / 8, 0)
        bit = fill_bits
        septets.each do |s|
          7.times do |b|
            out[bit >> 3] |= (1 << (bit & 7)) if s[b] == 1
            bit += 1
          end
        end
        out.pack("C*")
      end

      # Unpacks `count` septets starting at bit offset `start_bit`.
      def unpack_septets(bytes, count, start_bit = 0)
        bytes = bytes.bytes if bytes.is_a?(String)
        out = []
        bit = start_bit
        count.times do
          v = 0
          7.times do |b|
            byte = bytes[bit >> 3]
            return out if byte.nil?

            v |= (1 << b) if byte[bit & 7] == 1
            bit += 1
          end
          out << v
        end
        out
      end
    end
  end
end
