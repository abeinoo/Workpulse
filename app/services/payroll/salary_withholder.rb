module Payroll
  # Withholds, at Mark Paid, the entries of employees under an active Salary
  # Payment Hold that covers the period (effective on or before its last day).
  # Called only by Payroll::Approver inside the finalized → paid transaction,
  # under the period lock: the holds read here are the committed ones at that
  # moment — a hold created after this read applies from the next period paid;
  # a hold released after it leaves its withholding payable at once.
  #
  # The other employees are paid as always; nothing about any entry changes.
  # Entries whose net is not positive have nothing to withhold.
  class SalaryWithholder
    include AuditLoggable

    # Returns the created withholdings.
    def self.withhold!(period:, actor:) = new(period: period, actor: actor).withhold!

    def initialize(period:, actor:)
      @period = period
      @actor  = actor
    end

    def withhold!
      period = @period
      actor  = @actor
      holds = SalaryPaymentHold.covering(period).where(business_id: period.business_id).index_by(&:user_id)
      return [] if holds.empty?

      entries = period.payroll_entries.where(user_id: holds.keys).where("net_salary > 0")
                      .where.not(id: SalaryPaymentWithholding.live.select(:payroll_entry_id))
                      .order(:id)
      entries.map do |entry|
        hold = holds.fetch(entry.user_id)
        SalaryPaymentWithholding.create!(business_id: period.business_id, payroll_entry: entry,
                                         salary_payment_hold: hold, withheld_at: Time.current,
                                         withheld_by: actor).tap do |withholding|
          log_audit!(actor: actor, auditable: hold, action: "salary_payment_withheld",
                     metadata: { withholding_id: withholding.id, payroll_period_id: period.id,
                                 payroll_entry_id: entry.id, user_id: entry.user_id,
                                 amount: entry.net_salary.to_s })
        end
      end
    end
  end
end
