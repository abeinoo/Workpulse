module EmployeeDataRequests
  # Reviewer-only consistency checks on a revision, shown on the review page to
  # help verify the data against the ID photos. Advisory — they never block
  # approval — and never rendered to the requesting manager
  # (EmployeeDataRequestPolicy#review_details?).
  #
  #   national_id_birth_date — an Egyptian national ID encodes the birth date:
  #                            digit 1 = century (2 → 19xx, 3 → 20xx),
  #                            digits 2-7 = YYMMDD.
  #   id_expiry              — expired / expiring within EXPIRY_WARNING_DAYS.
  #   age_at_hire            — under MINIMUM_WORKING_AGE on the hire date.
  class VerificationChecks
    Check = Struct.new(:key, :status, :params, keyword_init: true) do
      def ok?      = status == :ok
      def warning? = status == :warning
    end

    EXPIRY_WARNING_DAYS = 60
    MINIMUM_WORKING_AGE = 18
    CENTURIES = { "2" => 1900, "3" => 2000 }.freeze

    def self.for(revision, today:)
      new(revision, today).checks
    end

    # Birth date encoded in an Egyptian national ID, or nil when unparseable.
    def self.birth_date_from_national_id(national_id)
      return nil unless national_id.to_s.match?(/\A\d{14}\z/)

      century = CENTURIES[national_id[0]] or return nil
      Date.new(century + national_id[1, 2].to_i, national_id[3, 2].to_i, national_id[5, 2].to_i)
    rescue Date::Error
      nil
    end

    def initialize(revision, today)
      @revision = revision
      @today    = today
    end

    def checks
      [ national_id_birth_date, id_expiry, age_at_hire ].compact
    end

    private

    def national_id_birth_date
      encoded = self.class.birth_date_from_national_id(@revision.national_id)
      return Check.new(key: :national_id_unreadable, status: :warning, params: {}) unless encoded

      if encoded == @revision.date_of_birth
        Check.new(key: :national_id_matches_birth_date, status: :ok, params: {})
      else
        Check.new(key: :national_id_birth_date_mismatch, status: :warning, params: { encoded: encoded })
      end
    end

    def id_expiry
      expiry = @revision.identity_card_expiry_date
      return Check.new(key: :id_expiry_missing, status: :warning, params: {}) unless expiry
      return Check.new(key: :id_expired, status: :warning, params: { date: expiry }) if expiry < @today
      if expiry <= @today + EXPIRY_WARNING_DAYS
        return Check.new(key: :id_expiring_soon, status: :warning, params: { date: expiry })
      end

      Check.new(key: :id_valid, status: :ok, params: { date: expiry })
    end

    def age_at_hire
      hire = @revision.hire_date
      dob  = @revision.date_of_birth
      return nil unless hire && dob

      age = hire.year - dob.year - (hire.change(year: dob.year) < dob ? 1 : 0)
      status = age < MINIMUM_WORKING_AGE ? :warning : :ok
      Check.new(key: status == :ok ? :age_at_hire_ok : :age_at_hire_minor, status: status, params: { age: age })
    rescue Date::Error
      nil
    end
  end
end
