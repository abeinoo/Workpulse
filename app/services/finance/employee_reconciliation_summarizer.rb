module Finance
  # Computes per-employee collected/refund totals for a DailyReconciliation.
  #
  # Data source (current): TillHandoverAmount.operational records from each
  # cashier's finalized handover — handovers that are either accepted or
  # self-deposit (day-close). These represent what each cashier collected and
  # refunded during their custody period(s).
  #
  # Future swap point: when Fresha POS transaction import is available, only
  # #aggregate_by_employee changes — the persistence and display layers stay
  # identical.
  #
  # Usage:
  #   Finance::EmployeeReconciliationSummarizer.new(dr).persist!   # at day close
  #   Finance::EmployeeReconciliationSummarizer.new(dr).summaries  # for display
  class EmployeeReconciliationSummarizer
    # View-layer structs — identical interface whether data comes from DB or live calc.
    SummaryRow = Struct.new(:user, :amounts, :computed_at, keyword_init: true) do
      def grand_total = amounts.sum(&:net_amount)
    end

    AmountRow = Struct.new(:payment_method_name, :collected_amount, :refund_amount,
                           keyword_init: true) do
      def net_amount = collected_amount - refund_amount
    end

    def initialize(daily_reconciliation)
      @dr = daily_reconciliation
    end

    # Compute and persist to DB atomically.
    # Replaces any existing summaries for this DR.
    # Called inside TillHandoverCreator#close_day! — already within a transaction.
    def persist!
      data = aggregate_by_employee
      now  = Time.current

      @dr.employee_reconciliation_summaries.destroy_all

      data.each_value do |entry|
        summary = @dr.employee_reconciliation_summaries.create!(
          user:        entry[:user],
          computed_at: now
        )
        entry[:amounts].each_value do |pm_data|
          summary.amounts.create!(
            payment_method_id:   pm_data[:payment_method_id],
            payment_method_name: pm_data[:name],
            collected_amount:    pm_data[:collected],
            refund_amount:       pm_data[:refund]
          )
        end
      end
    end

    # Returns summaries ready for display.
    # Loads from DB if already persisted; computes live otherwise.
    # Pass for_user: to restrict results to a single user (own-only permission).
    def summaries(for_user: nil)
      stored = @dr.employee_reconciliation_summaries
                  .includes(:user, amounts: :payment_method)
                  .order(:created_at)
      stored = stored.where(user: for_user) if for_user
      return db_to_rows(stored) if stored.any?

      rows = live_rows
      return rows.select { |r| r.user&.id == for_user.id } if for_user

      rows
    end

    private

    # ── Data source (swap this method when POS transactions are available) ─────
    #
    # Correct formula per custody period:
    #
    #   Contribution = Closing handover amounts − Opening balance received
    #
    # The "closing" amounts are what the employee reported in their outgoing
    # handover. The "opening" amounts are what was handed to them when they
    # received the till (the most recently accepted handover TO them, accepted
    # before they created their outgoing handover).
    #
    # The first employee (who opens the till for the day) has no incoming
    # handover, so their opening balance is zero.
    #
    # If an employee holds the till more than once in a day, each custody period
    # is calculated independently, then contributions are summed.

    def aggregate_by_employee
      handovers = @dr.till_handovers
                     .where("accepted_at IS NOT NULL OR self_deposit = TRUE")
                     .includes(:from_user, :to_user, amounts: :payment_method)
                     .order(:created_at)

      # Build a lookup: for each user, which handovers were accepted TO them?
      # Sorted by accepted_at so we can find the most recent one before any
      # given outgoing handover.
      received_by_user = Hash.new { |h, k| h[k] = [] }
      handovers.each do |h|
        next unless h.to_user_id.present? && h.accepted_at.present?
        received_by_user[h.to_user_id] << h
      end
      received_by_user.each_value { |arr| arr.sort_by!(&:accepted_at) }

      # Hash preserves insertion order → employees appear in chronological order
      # of their first custody period.
      by_employee = {}

      handovers.each do |h_out|
        uid   = h_out.from_user_id
        entry = by_employee[uid] ||= { user: h_out.from_user, amounts: {} }

        # Find the opening balance: the most recently accepted handover TO this
        # employee that was accepted before this outgoing handover was created.
        # (The outgoing is always created after the employee accepted the incoming.)
        last_received = received_by_user[uid]
                          .select { |h| h.accepted_at <= h_out.created_at }
                          .last

        opening_by_pm = {}
        last_received&.amounts&.each do |amt|
          next unless amt.kind == "operational"
          opening_by_pm[amt.payment_method_id] = {
            collected: amt.collected_amount,
            refund:    amt.refund_amount
          }
        end

        h_out.amounts.each do |amt|
          next unless amt.kind == "operational"

          pm      = entry[:amounts][amt.payment_method_id] ||= {
            payment_method_id: amt.payment_method_id,
            name:              amt.payment_method_name,
            position:          amt.payment_method&.position || 0,
            collected:         0.to_d,
            refund:            0.to_d
          }
          opening = opening_by_pm[amt.payment_method_id] || { collected: 0.to_d, refund: 0.to_d }

          pm[:collected] += amt.collected_amount - opening[:collected]
          pm[:refund]    += amt.refund_amount    - opening[:refund]
        end
      end

      by_employee
    end

    # ── Adapters ───────────────────────────────────────────────────────────────

    def live_rows
      aggregate_by_employee.map do |_uid, entry|
        SummaryRow.new(
          user:        entry[:user],
          amounts:     sorted_amount_rows(entry[:amounts].values),
          computed_at: nil
        )
      end
    end

    def db_to_rows(records)
      records.map do |rec|
        pm_rows = rec.amounts.sort_by { |a| a.payment_method&.position || 0 }
                             .map { |a|
                                AmountRow.new(payment_method_name: a.payment_method_name,
                                              collected_amount:    a.collected_amount,
                                              refund_amount:       a.refund_amount)
                              }
        SummaryRow.new(user: rec.user, amounts: pm_rows, computed_at: rec.computed_at)
      end
    end

    def sorted_amount_rows(pm_hashes)
      pm_hashes.sort_by { |a| a[:position] }
               .map { |a|
                  AmountRow.new(payment_method_name: a[:name],
                                collected_amount:    a[:collected],
                                refund_amount:       a[:refund])
                }
    end
  end
end
