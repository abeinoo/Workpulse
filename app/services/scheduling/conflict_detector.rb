module Scheduling
  # Checks whether a proposed ShiftAssignment would conflict with existing data.
  # Returns a Result with status :valid, :warning, or :blocked and an optional reason key.
  #
  # :blocked — assignment cannot be created (inactive employee, hard overlap)
  # :warning — assignment can proceed but has a soft concern (branch mismatch)
  # :valid   — no conflicts found
  class ConflictDetector
    Result = Struct.new(:status, :reason, keyword_init: true) do
      def valid?   = status == :valid
      def warning? = status == :warning
      def blocked? = status == :blocked
    end

    def self.call(user:, shift:, branch:, effective_from:, effective_to:)
      new(user: user, shift: shift, branch: branch,
          effective_from: effective_from, effective_to: effective_to).call
    end

    def initialize(user:, shift:, branch:, effective_from:, effective_to:)
      @user           = user
      @shift          = shift
      @branch         = branch
      @effective_from = effective_from
      @effective_to   = effective_to
    end

    def call
      return blocked(:employee_inactive) unless @user.active?

      # Branch mismatch is a warning (not hard blocked) — manager may be assigning
      # to a branch the employee hasn't formally joined yet.
      warning_reason = user_not_in_branch? ? :branch_mismatch : nil

      test = ShiftAssignment.new(
        user:           @user,
        shift:          @shift,
        branch:         @branch,
        effective_from: @effective_from,
        effective_to:   @effective_to
      )

      unless test.valid?
        return blocked(test.errors.full_messages.first)
      end

      warning_reason ? warning(warning_reason) : Result.new(status: :valid, reason: nil)
    end

    private

    def user_not_in_branch?
      @branch.present? && !@user.branches.exists?(@branch.id)
    end

    def blocked(reason)
      Result.new(status: :blocked, reason: reason)
    end

    def warning(reason)
      Result.new(status: :warning, reason: reason)
    end
  end
end
