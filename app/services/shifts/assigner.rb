module Shifts
  class Assigner
    Result = Struct.new(:success, :assignment, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(business:, params:)
      new(business: business, params: params).call
    end

    def initialize(business:, params:)
      @business = business
      @params   = params.to_h.symbolize_keys
    end

    def call
      return invalid_scope_result unless valid_business_scope?
      return invalid_user_result  unless valid_business_user?

      assignment = ShiftAssignment.new(@params)

      ActiveRecord::Base.transaction do
        close_existing_assignment!(assignment)
        assignment.save!
      end

      Result.new(success: true, assignment: assignment)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, error: e.record.errors.full_messages.join(", "))
    rescue ActiveRecord::RecordNotFound
      invalid_scope_result
    end

    private

    def valid_business_scope?
      branch_ok = @params[:branch_id].nil? || @business.branches.exists?(@params[:branch_id])
      branch_ok && @business.shifts.exists?(@params[:shift_id])
    end

    # The employee must belong to the same business as the branch and shift —
    # never trusted just because the user_id exists. A blank user_id is left to
    # ShiftAssignment's own presence validation.
    def valid_business_user?
      @params[:user_id].blank? || @business.users.exists?(@params[:user_id])
    end

    def invalid_scope_result
      Result.new(success: false, error: "Branch or shift not found in this business")
    end

    def invalid_user_result
      Result.new(success: false, error: "Employee not found in this business")
    end

    # Closes the current open assignment for this user+branch so date ranges never overlap.
    def close_existing_assignment!(new_assignment)
      existing = ShiftAssignment
        .where(user_id: new_assignment.user_id, branch_id: new_assignment.branch_id)
        .where(effective_to: nil)
        .first

      return unless existing

      close_date = new_assignment.effective_from - 1.day
      existing.update!(effective_to: close_date)
    end
  end
end
