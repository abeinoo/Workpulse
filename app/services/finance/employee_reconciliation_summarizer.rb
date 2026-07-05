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

    AmountRow = Struct.new(:payment_method_id, :payment_method_name, :collected_amount, :refund_amount,
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
    # Always computed live from the handover graph so the display always reflects
    # the current algorithm. The persist!/db_to_rows path is preserved for future
    # use (e.g. POS snapshot swap) but is not used for rendering.
    # Pass for_user: to restrict results to a single user (own-only permission).
    def summaries(for_user: nil)
      rows = live_rows
      Rails.logger.debug do
        rows.map { |r|
          amounts_str = r.amounts.map { |a| "#{a.payment_method_name}: #{a.collected_amount}" }.join(", ")
          "[ERS] #{r.user&.full_name} → #{amounts_str} | net=#{r.grand_total}"
        }.join("\n")
      end
      return rows.select { |r| r.user&.id == for_user.id } if for_user

      rows
    end

    private

    # ── Data source (swap this method when POS transactions are available) ─────
    #
    # Formula (per cashier, per payment method):
    #
    #   Net Custody Increase = Last Outgoing Operational − Sum(All Incoming Operational)
    #
    # "Last outgoing" is the chronologically final handover FROM this cashier —
    # either a mid-day handoff to the next cashier, or the day-close handover.
    # "All incoming" is every accepted handover TO this cashier, including the
    # opening-float handover (which OpeningFloatReceiver stores as operational
    # amounts, so it is naturally part of the incoming sum and excluded from
    # the net result).
    #
    # This measures the net change in the cashier's custody balance for the day:
    # how much the till grew (or shrank) across all time this cashier held it,
    # regardless of how many custody periods they had.

    def aggregate_by_employee
      handovers = @dr.till_handovers
                     .where("accepted_at IS NOT NULL OR self_deposit = TRUE")
                     .includes(:from_user, :to_user, amounts: :payment_method)
                     .order(:created_at)

      # Identify the opening-float receiving handover for this DR, if any.
      # OpeningFloatReceiver creates it as the very first accepted handover
      # in the DR, with from_user = the previous day's final holder (the seeder).
      # We need its ID and the seeder's user_id to apply the exclusion rule below.
      of_source    = @dr.opening_float_source_handover
      of_seeder_id = of_source&.from_user_id
      of_recv_id   = nil   # id of the receiving handover in today's DR

      if of_seeder_id
        recv_h = handovers.find { |h| h.from_user_id == of_seeder_id && h.to_user_id.present? && h.accepted_at.present? }
        of_recv_id = recv_h&.id
      end

      # Separate into outgoing (from_user) and incoming (to_user) per employee.
      # outgoing_by_user preserves created_at order so .last gives the final one.
      outgoing_by_user = Hash.new { |h, k| h[k] = [] }
      incoming_by_user = Hash.new { |h, k| h[k] = [] }

      handovers.each do |h|
        outgoing_by_user[h.from_user_id] << h if h.from_user_id.present?
        if h.to_user_id.present? && h.accepted_at.present?
          incoming_by_user[h.to_user_id] << h
        end
      end

      # Hash preserves insertion order → employees appear in chronological order
      # of their first outgoing handover.
      by_employee = {}

      outgoing_by_user.each do |uid, outgoing_list|
        last_outgoing = outgoing_list.last
        entry = by_employee[uid] ||= { user: last_outgoing.from_user, amounts: {} }

        # Sum all operational amounts received by this cashier (all incoming handovers).
        # Exception: if the opening-float receiving handover was seeded by this same
        # cashier (i.e. they carried their own float forward from the previous business
        # day), exclude it — the float already belongs to their custody and must not
        # reduce their collected amount.
        incoming_by_pm = Hash.new { |h, k| h[k] = { collected: 0.to_d, refund: 0.to_d } }
        incoming_by_user[uid].each do |h_in|
          next if h_in.id == of_recv_id && of_seeder_id == uid

          h_in.amounts.each do |amt|
            next unless amt.kind == "operational"
            incoming_by_pm[amt.payment_method_id][:collected] += amt.collected_amount
            incoming_by_pm[amt.payment_method_id][:refund]    += amt.refund_amount
          end
        end

        # Net = last outgoing operational − total incoming operational.
        last_outgoing.amounts.each do |amt|
          next unless amt.kind == "operational"
          incoming_pm = incoming_by_pm[amt.payment_method_id]

          pm = entry[:amounts][amt.payment_method_id] ||= {
            payment_method_id: amt.payment_method_id,
            name:              amt.payment_method_name,
            position:          amt.payment_method&.position || 0,
            collected:         0.to_d,
            refund:            0.to_d
          }

          pm[:collected] = amt.collected_amount - incoming_pm[:collected]
          pm[:refund]    = amt.refund_amount    - incoming_pm[:refund]
          Rails.logger.debug do
            "[ERS] #{last_outgoing.from_user&.full_name} | #{amt.payment_method_name}: " \
              "last_out=#{amt.collected_amount} incoming_sum=#{incoming_pm[:collected]} net=#{pm[:collected]}"
          end
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
                                AmountRow.new(payment_method_id:   a.payment_method_id,
                                              payment_method_name: a.payment_method_name,
                                              collected_amount:    a.collected_amount,
                                              refund_amount:       a.refund_amount)
                              }
        SummaryRow.new(user: rec.user, amounts: pm_rows, computed_at: rec.computed_at)
      end
    end

    def sorted_amount_rows(pm_hashes)
      pm_hashes.sort_by { |a| a[:position] }
               .map { |a|
                  AmountRow.new(payment_method_id:   a[:payment_method_id],
                                payment_method_name: a[:name],
                                collected_amount:    a[:collected],
                                refund_amount:       a[:refund])
                }
    end
  end
end
