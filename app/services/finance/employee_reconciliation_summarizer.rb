module Finance
  # Computes, per employee, the TOTAL amount handed over during a
  # DailyReconciliation's business day — the "Total Handed Over" figure shown
  # in the Sales Transactions Verification Summary.
  #
  # This is a custody-PERIOD calculation, not a custody-graph or net-custody
  # calculation. An employee's day is split into custody periods, each one
  # ending in one of their own outgoing operational handovers (a peer
  # handover or a self-deposit/day-close — anything that transfers custody
  # away from them). Each period's contribution is that outgoing amount minus
  # whatever the employee received (as to_user on an accepted handover) since
  # their previous outgoing handover, or since the start of the DR for their
  # first period. The employee's total is the sum of every period's
  # contribution.
  #
  # Only two kinds of event affect custody:
  #   - Incoming: an accepted handover where the employee is to_user (this
  #     includes receiving the opening float — OpeningFloatReceiver creates
  #     that as an ordinary accepted handover, so it needs no special case).
  #   - Outgoing: an operational handover where the employee is from_user,
  #     including self-deposit/day-close.
  #
  # opening_float_declaration? handovers ("Opening Float Left") are NOT a
  # custody event at all — they don't transfer custody to anyone (no
  # to_user), so they never start or end a period, and are excluded from both
  # the outgoing and incoming sets entirely.
  #
  # A period with no incoming handovers in its window is valid and expected —
  # its contribution is simply its full outgoing amount. This covers an
  # employee resuming the same till later in the day without a new "receive"
  # event, with no special-casing: an empty window is a normal input to the
  # subtraction, not an edge case to detect.
  #
  # Data source (current): TillHandoverAmount.operational records from each
  # cashier's finalized handover — handovers that are either accepted or
  # self-deposit (day-close).
  #
  # Future swap point: when Fresha Sales transaction import is available, only
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

    # preloaded_handovers lets a caller iterating many DRs (the index page's
    # Employee Sales Reconciliation issue badges — see
    # Finance::DailyReconciliationsController#build_employee_issue_badges)
    # batch-fetch every DR's till_handovers (+ from_user/financial_adjustments/
    # amounts:payment_method) in one query for the whole page and pass this
    # DR's slice in, instead of #aggregate_by_employee re-querying per DR.
    # Must already match the same predicate/order #aggregate_by_employee
    # would otherwise apply itself (see below) and carry the same
    # associations preloaded.
    def initialize(daily_reconciliation, preloaded_handovers: nil)
      @dr = daily_reconciliation
      @preloaded_handovers = preloaded_handovers
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
    # use (e.g. Sales snapshot swap) but is not used for rendering.
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

    # ── Data source (swap this method when Sales transactions are available) ─────
    #
    # Formula (per employee, per custody period, per payment method):
    #
    #   Period Contribution = Outgoing operational amount
    #                          − Sum(incoming operational amounts received
    #                            since the previous outgoing period, or since
    #                            the start of the DR for the first period)
    #
    #   Employee Total = Sum(Period Contribution) across every period
    #
    # A period boundary is any operational handover where the employee is
    # from_user (a peer handover or a self-deposit/day-close). An incoming
    # handover — accepted, employee is to_user — is assigned to exactly one
    # period: the next one that ends after it. opening_float_declaration?
    # handovers are excluded entirely (not a custody event — see class comment).

    def aggregate_by_employee
      handovers = @preloaded_handovers || @dr.till_handovers
                     .where("accepted_at IS NOT NULL OR self_deposit = TRUE")
                     .where(opening_float_declaration: false)
                     .includes(:from_user, :financial_adjustments, amounts: :payment_method)
                     .order(:created_at)

      outgoing_by_user = Hash.new { |h, k| h[k] = [] }
      incoming_by_user = Hash.new { |h, k| h[k] = [] }

      handovers.each do |h|
        outgoing_by_user[h.from_user_id] << h if h.from_user_id.present?
        incoming_by_user[h.to_user_id] << h if h.to_user_id.present? && h.accepted_at.present?
      end

      # Hash preserves insertion order → employees appear in chronological
      # order of their first outgoing handover.
      by_employee = {}

      outgoing_by_user.each do |uid, outgoing_list|
        entry         = by_employee[uid] ||= { user: outgoing_list.first.from_user, amounts: {} }
        incoming_list = incoming_by_user[uid]
        window_start  = nil # nil == since the beginning of the DR

        outgoing_list.each do |outgoing|
          period_incoming = Hash.new { |h, k| h[k] = { collected: 0.to_d, refund: 0.to_d } }

          incoming_list.each do |h_in|
            next unless h_in.accepted_at <= outgoing.created_at
            next if window_start.present? && h_in.accepted_at <= window_start

            h_in.effective_operational_amounts.each do |amt|
              period_incoming[amt[:payment_method_id]][:collected] += amt[:collected_amount]
              period_incoming[amt[:payment_method_id]][:refund]    += amt[:refund_amount]
            end
          end

          outgoing.effective_operational_amounts.each do |amt|
            pm_in = period_incoming[amt[:payment_method_id]]
            pm = entry[:amounts][amt[:payment_method_id]] ||= {
              payment_method_id: amt[:payment_method_id],
              name:              amt[:payment_method_name],
              position:          amt[:payment_method]&.position || 0,
              collected:         0.to_d,
              refund:            0.to_d
            }

            pm[:collected] += amt[:collected_amount] - pm_in[:collected]
            pm[:refund]    += amt[:refund_amount]    - pm_in[:refund]
          end

          window_start = outgoing.created_at
        end
      end

      Rails.logger.debug do
        by_employee.map { |uid, entry|
          amt_str = entry[:amounts].values.map { |a| "#{a[:name]}: collected=#{a[:collected]} refund=#{a[:refund]}" }.join(", ")
          "[ERS DR=#{@dr.id}] employee=#{entry[:user]&.full_name}(#{uid}) → #{amt_str}"
        }.join("\n")
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
