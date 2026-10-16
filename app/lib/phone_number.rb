# Decides whether a phone number someone typed is the same number as one we
# have stored, tolerating the formats people actually use:
#
#   * Arabic-Indic / Persian digits (٠١٠… / ۰۱۰…) from Arabic phone keyboards
#   * spaces, dashes and brackets (stripped by User's phone normalization)
#   * the "00" international dialing prefix instead of "+"
#   * Egyptian mobiles in national (01XXXXXXXXX), international (+201XXXXXXXXX)
#     or bare-country-code (201XXXXXXXXX) form
#
# The Egyptian rule only applies to the strict mobile pattern 01[0125] + 8
# digits, so numbers from other countries (e.g. Saudi +9665…) are never
# reinterpreted as Egyptian — they still have to match after normalization.
module PhoneNumber
  EASTERN_DIGITS = "٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹".freeze
  ASCII_DIGITS   = ("0123456789" * 2).freeze

  EGYPT_MOBILE_NATIONAL      = /\A0(1[0125]\d{8})\z/
  EGYPT_MOBILE_BARE_COUNTRY  = /\A20(1[0125]\d{8})\z/
  EGYPT_MOBILE_NATIONAL_SUFFIX = /\A1[0125]\d{8}\z/

  module_function

  def equivalent?(stored, input)
    stored_key = comparison_key(stored)
    stored_key.present? && stored_key == comparison_key(input)
  end

  # Every stored (User-normalized) phone_number value that is equivalent to
  # `input`, so callers can look it up with an indexed `WHERE phone_number IN`.
  # The inverse of #comparison_key; [] when `input` has no digits.
  def stored_forms(input)
    key = comparison_key(input)
    return [] if key.nil?
    return [ key ] unless key.start_with?("+")

    forms = [ key, "00#{key.delete_prefix('+')}" ]
    subscriber = key.delete_prefix("+20")
    if key.start_with?("+20") && subscriber.match?(EGYPT_MOBILE_NATIONAL_SUFFIX)
      forms += [ "0#{subscriber}", "20#{subscriber}" ]
    end
    forms
  end

  # A canonical form used only for comparison — never persisted.
  def comparison_key(value)
    normalized = User.normalize_value_for(:phone_number, value.to_s.tr(EASTERN_DIGITS, ASCII_DIGITS))
    return nil if normalized.blank? || normalized == "+"

    normalized = "+#{normalized.delete_prefix('00')}" if normalized.start_with?("00")

    if (match = EGYPT_MOBILE_NATIONAL.match(normalized) || EGYPT_MOBILE_BARE_COUNTRY.match(normalized))
      "+20#{match[1]}"
    else
      normalized
    end
  end
end
