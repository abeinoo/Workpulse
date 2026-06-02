module Payroll
  # THE single approval rule for the entire payroll system.
  #
  # An adjustment (or an adjustment-sourced payroll line item) may be approved or
  # rejected by a `reviewer` only when BOTH hold:
  #
  #   1. the reviewer holds the `approve_adjustments` permission, and
  #   2. the reviewer is NOT the creator of the adjustment (creator != approver).
  #
  # Every approval surface — standalone adjustments, payroll-review adjustments,
  # the API applier, single line-item review, and bulk "approve all pending" —
  # funnels through this one predicate. There is intentionally no second copy of
  # this logic anywhere else.
  #
  # `creator` may be a User, a user id, or nil. A nil creator means the item is
  # system-generated (e.g. an attendance penalty) and has no human author, so the
  # creator != approver clause is vacuously satisfied; only the permission matters.
  module AdjustmentApproval
    module_function

    def permitted?(reviewer:, creator:)
      has_permission?(reviewer) && !creator?(reviewer, creator)
    end

    # True when `reviewer` is the very person who created the item.
    def creator?(reviewer, creator)
      return false if reviewer.nil?

      cid = creator.is_a?(User) ? creator.id : creator
      cid.present? && reviewer.id == cid
    end

    def has_permission?(reviewer)
      reviewer.respond_to?(:can?) && reviewer.can?(:approve_adjustments)
    end
  end
end
