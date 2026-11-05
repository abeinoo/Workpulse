module Payroll
  # Read-only: the payment state of payroll entries under Salary Payment Holds,
  # derived from the data — no stored balance. Payroll calculation never reads
  # holds; this only says what of the calculated (earned) net salary is held,
  # payable or paid.
  #
  # Per entry (net = the entry's net_salary, never below zero here):
  #   period not paid yet
  #     :on_hold   — an active hold covers the period: will be withheld at Mark Paid
  #     :normal    — payable through the normal Mark Paid
  #   period paid
  #     :held      — withheld, hold still active (payment blocked)
  #     :released  — withheld, hold released, not yet paid (payable: Pay Released Salary)
  #     :disbursed — withheld, then paid after the release
  #     :paid      — paid with the period
  #
  # Earned is always the full net; held / payable / paid split it.
  class SalaryPaymentStatus
    Status = Struct.new(:entry, :state, :hold, :withholding, keyword_init: true) do
      def earned  = [ entry.net_salary.to_d, 0.to_d ].max
      def held    = %i[on_hold held].include?(state) ? earned : 0.to_d
      def payable = %i[normal released].include?(state) ? earned : 0.to_d
      def paid    = %i[paid disbursed].include?(state) ? earned : 0.to_d
    end

    Totals = Struct.new(:earned, :held, :payable, :paid, :held_count, keyword_init: true)

    def initialize(period:, entries:)
      @period  = period
      @entries = entries.to_a
    end

    def for(entry) = statuses.fetch(entry.id)

    def statuses
      @statuses ||= @entries.to_h { |entry| [ entry.id, status_of(entry) ] }
    end

    def totals
      list = statuses.values
      Totals.new(earned: list.sum(0.to_d, &:earned), held: list.sum(0.to_d, &:held),
                 payable: list.sum(0.to_d, &:payable), paid: list.sum(0.to_d, &:paid),
                 held_count: list.count { |s| %i[on_hold held].include?(s.state) })
    end

    private

    def status_of(entry)
      if @period.paid?
        withholding = withholdings[entry.id]
        state = if withholding.nil? then :paid
        elsif withholding.disbursed? then :disbursed
        elsif withholding.salary_payment_hold.active? then :held
        else :released
        end
        Status.new(entry: entry, state: state, hold: withholding&.salary_payment_hold, withholding: withholding)
      else
        hold = covering_holds[entry.user_id]
        Status.new(entry: entry, state: hold ? :on_hold : :normal, hold: hold)
      end
    end

    def withholdings
      @withholdings ||= SalaryPaymentWithholding.live.where(payroll_entry_id: @entries.map(&:id))
                                                .includes(:salary_payment_hold).index_by(&:payroll_entry_id)
    end

    def covering_holds
      @covering_holds ||= SalaryPaymentHold.covering(@period).where(business_id: @period.business_id,
                                                                    user_id: @entries.map(&:user_id))
                                           .index_by(&:user_id)
    end
  end
end
