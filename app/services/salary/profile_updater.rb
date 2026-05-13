module Salary
  # Creates a new SalaryProfile for a user and deactivates all previous ones.
  # A user should only ever have one active profile at a time.
  # Historical profiles are preserved (never deleted) for payroll audit.
  class ProfileUpdater
    Result = Struct.new(:success, :profile, :errors, keyword_init: true) do
      def success? = success
    end

    def self.call(user:, params:)
      new(user: user, params: params).call
    end

    def initialize(user:, params:)
      @user   = user
      @params = params.to_h.symbolize_keys
    end

    def call
      ActiveRecord::Base.transaction do
        @user.salary_profiles.where(active: true).update_all(active: false)
        profile = @user.salary_profiles.create!(@params.merge(active: true))
        Result.new(success: true, profile: profile)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, errors: e.record.errors.full_messages)
    end
  end
end
