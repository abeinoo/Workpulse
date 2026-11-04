module Payroll
  # The central review of a payroll period: the business-level sign-off of its
  # floating employees (no home branch), held by the period's single central
  # review slot (PayrollPeriodBranchReview with no branch).
  #
  # Scope: the period's employees with a floating assignment during it — the
  # same rule Payroll::SubmitForReview opens the slot by — and, for each, the
  # payroll figures and line items the reviewer signed off. #scope_digest
  # fingerprints that content and every completion records it
  # (review_slot_completed audit event), so "is the central review still
  # valid?" is derived from data (#current?), never a stored flag:
  #
  #   no floating employee, no slot           → current (nothing to review)
  #   floating employees, no slot             → not current (review required)
  #   slot not completed                      → not current
  #   slot completed, content changed since   → not current (reopen)
  #   slot completed, content unchanged       → current
  #
  # The fingerprint leaves out review flags (needs_review), so marking entries
  # reviewed never reopens it, and covers floating employees only, so a
  # branch-only change never does. Added or removed floating employees, salary,
  # adjustments, overrides, waivers, line-item reviews and assignment changes
  # that make an employee floating or not all change it.
  #
  # #sync! acts on it: creates the slot, or reopens a completed one, and sends a
  # period whose reviews were complete back to under_review. Payroll::Approver
  # runs it under the period lock before every finalization (the override
  # included), so no path that adds or changes floating payroll — attendance
  # edits, adjustments, waivers, assignment edits in Workforce — can be
  # finalized unreviewed; the review-cycle services run it too. Write paths that
  # hold entry rows without the period lock do not call it (that would invert
  # the request → period → entry lock order): their change shows at once as
  # "not current" on the period page and reopens the review at the next sync.
  class CentralReview
    SYNCABLE_STATUSES = %w[under_review branch_review_completed].freeze

    Result = Struct.new(:created, :reopened, :period_reopened, keyword_init: true) do
      def changed? = created || reopened
    end

    def initialize(period)
      @period = period
    end

    def slot
      @period.payroll_period_branch_reviews.central.first
    end

    def floating_user_ids
      @floating_user_ids ||= ShiftAssignment.floating
                                            .active_during(@period.period_start, @period.period_end)
                                            .where(user_id: @period.payroll_entries.select(:user_id))
                                            .distinct.pluck(:user_id).sort
    end

    def floating? = floating_user_ids.any?

    # What a central reviewer signs off: each floating employee's figures and
    # line items (identities that survive recalculation — an obligation
    # deduction's source row is recreated on every run, so ids are left out).
    def scope_digest
      entries = @period.payroll_entries.where(user_id: floating_user_ids)
                       .includes(:payroll_line_items).order(:user_id)
      payload = entries.map do |entry|
        items = entry.payroll_line_items.map do |li|
          [ li.item_type, li.amount.to_s, li.source_type, li.review_status,
            li.deduction_waived?, li.addition_cancelled?, li.already_paid? ]
        end
        [ entry.user_id, entry.financial_snapshot.transform_values(&:to_s), items.sort_by(&:to_s) ]
      end
      Digest::SHA256.hexdigest(JSON.generate([ floating_user_ids, payload ]))
    end

    # The fingerprint recorded by the latest completion of the central slot.
    def reviewed_digest
      @period.payroll_audit_logs.where(action_type: "review_slot_completed").order(:created_at, :id)
             .reverse_each.map(&:metadata_hash).find { |meta| meta["central"] }&.dig("scope_digest")
    end

    def current?
      review = slot
      return !floating? if review.nil?

      review.completed? && reviewed_digest == scope_digest
    end

    # A completed central review whose content changed since (shown on the
    # period page until the next sync reopens it).
    def stale?
      review = slot
      review.present? && review.completed? && reviewed_digest != scope_digest
    end

    def sync!(actor:)
      unchanged = Result.new(created: false, reopened: false, period_reopened: false)
      return unchanged unless SYNCABLE_STATUSES.include?(@period.status)

      review   = slot
      created  = review.nil? && floating?
      reopened = !review.nil? && stale?
      return unchanged unless created || reopened

      if created
        PayrollPeriodBranchReview.create!(payroll_period: @period, branch: nil, status: :pending)
      else
        review.update!(status: :pending, completed_at: nil, reviewer: nil, notes: nil)
      end

      from_status     = @period.status
      period_reopened = @period.branch_review_completed?
      @period.update!(status: :under_review) if period_reopened

      PayrollAuditLog.create!(
        payroll_period: @period,
        actor:          actor,
        action_type:    :central_review_reopened,
        from_status:    (from_status if period_reopened),
        to_status:      ("under_review" if period_reopened),
        metadata:       { central: true, reason: created ? "floating_employees_added" : "content_changed",
                          floating_employee_count: floating_user_ids.size }.to_json
      )

      Result.new(created: created, reopened: reopened, period_reopened: period_reopened)
    end
  end
end
