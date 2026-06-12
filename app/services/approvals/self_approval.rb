module Approvals
  # THE single self-approval rule for every human-requested approval workflow:
  # employee requests (salary advances, late/early permissions, punch corrections)
  # and inventory stock counts. A request may NOT be approved or rejected by the
  # same person who submitted it (segregation of duties) — another authorized
  # approver must review it.
  #
  # The payroll domain enforces the equivalent creator != approver rule through
  # Payroll::AdjustmentApproval (which also bundles the approve_adjustments
  # permission and the business-owner exception); these are deliberately the only
  # two places this logic lives.
  module SelfApproval
    module_function

    # True when `approver` is the very person who submitted the request.
    # `requester` may be a User, a user id, or nil. A nil requester means there is
    # no human author (system-generated), so it can never be a self-approval.
    def by_requester?(approver:, requester:)
      return false if approver.nil?

      rid = requester.is_a?(User) ? requester.id : requester
      rid.present? && approver.id == rid
    end

    # The clear, user-facing message shown when a self-approval is blocked.
    def error_message
      I18n.t("approvals.errors.self_approval")
    end
  end
end
