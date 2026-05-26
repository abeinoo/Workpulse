module Attendance
  # Centralized, source-aware timestamp parser for all attendance entry points.
  #
  # WHY THIS EXISTS
  # ───────────────
  # Different sources deliver timestamps with different timezone semantics:
  #
  #   mobile          → server calls Time.current (UTC). No string parsing needed.
  #   biometric_device→ device sends the local clock time (business timezone).
  #                     ISO 8601 WITH explicit offset ("T09:15:00+03:00") → respect the offset.
  #                     Bare datetime ("2026-05-24 09:15:00")              → assume business TZ.
  #   import          → CSV times are bare local datetimes → assume business TZ.
  #   admin_manual    → manager types a local time → assume business TZ.
  #                     ISO 8601 with explicit offset → respected by ActiveSupport's parse.
  #   api             → callers that send explicit ISO 8601 → respect offset.
  #
  # The output is always a UTC-normalised ActiveSupport::TimeWithZone so Rails
  # stores it as UTC in the database.
  #
  # Usage:
  #   Attendance::TimestampParser.parse("2026-05-24 09:15:00",
  #                                     source: :biometric_device,
  #                                     business: business)
  #   # => 2026-05-24 06:15:00 UTC  (if business is Cairo, UTC+3)
  #
  class TimestampParser
    SOURCES = %w[mobile biometric_device import admin_manual api].freeze

    def self.parse(value, source:, business:)
      return nil if value.blank?
      new(value.to_s.strip, source.to_sym, business).parse
    end

    def initialize(value, source, business)
      @value    = value
      @source   = source
      @business = business
    end

    def parse
      result = case @source
               when :biometric_device then parse_biometric
               when :mobile           then parse_utc_string   # rare; usually Time.current
               when :import           then parse_in_business_tz
               when :admin_manual     then parse_in_business_tz
               when :api              then parse_utc_string
               else                        parse_in_business_tz
               end

      result&.in_time_zone(@business.timezone_object)
    rescue ArgumentError, TypeError => e
      Rails.logger.warn("[TimestampParser] Could not parse #{@value.inspect} source=#{@source} business=#{@business.id}: #{e.message}")
      nil
    end

    private

    # Biometric devices send the local clock time.
    # - ISO 8601 with explicit offset → respect the offset (device already tagged it).
    # - Bare datetime (no offset) → treat as business local time to avoid double conversion.
    def parse_biometric
      if explicit_offset?
        Time.iso8601(@value)
      else
        @business.timezone_object.parse(@value)
      end
    end

    # Mobile/API senders that provide an explicit UTC or offset-tagged ISO 8601 string.
    # Falls back to business timezone if offset is absent.
    def parse_utc_string
      if explicit_offset?
        Time.iso8601(@value)
      else
        @business.timezone_object.parse(@value)
      end
    end

    # CSV imports and admin manual entries provide bare local datetimes.
    # ActiveSupport's timezone#parse respects explicit offsets when present.
    def parse_in_business_tz
      @business.timezone_object.parse(@value)
    end

    # Returns true when the string carries an explicit timezone offset or Z suffix.
    # Matches: …Z  …+03:00  …-05:30  …+0300  …-0530
    def explicit_offset?
      @value.match?(/[Zz]$|[+-]\d{2}:?\d{2}$/)
    end
  end
end
