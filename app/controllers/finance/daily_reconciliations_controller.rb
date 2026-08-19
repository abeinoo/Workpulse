class Finance::DailyReconciliationsController < Finance::BaseController
  # Lightweight value object for displaying override amounts in the view.
  # Mirrors the TillHandoverAmount interface used by the waiting card partial.
  OpeningFloatDisplayAmount = Struct.new(:payment_method_name, :collected_amount, :refund_amount) do
    def net_amount = collected_amount - refund_amount
  end

  before_action :set_reconciliation, only: %i[show verify assign_depositor
                                               edit_opening_float update_opening_float_amounts receive_opening_float
                                               edit_session_totals update_session_totals
                                               edit_day_close_amounts update_day_close_amounts
                                               correct_opening_float update_opening_float_correction]

  # GET /finance/daily_reconciliations
  def index
    authorize DailyReconciliation

    @current_business_day = BusinessDay.current(context: current_user.business)

    @show_verification = current_user.can?(:view_deposit_verification)

    query = DailyReconciliation
              .where(business_id: current_user.business_id)
              .includes(:branch, :business, :bank_disputes,
                        remaining_deposit_balances: :responsible_user,
                        opening_float_source_handover: :from_user,
                        till_session: %i[current_holder depositor],
                        session_amounts:               :payment_method)
              .order(opened_at: :desc)
              .limit(200)

    query = query.includes(till_deposits: [ :deposit_matches, :bank_statement_transactions, :bank_disputes ]) if @show_verification
    query = query.includes(:till_deposits) unless @show_verification

    unless current_user.owner?
      scope_name = current_user.scope_for(:view_daily_reconciliation)
      if scope_name
        branch_ids = BranchScope.new(current_user).for_scope(scope_name)
        if branch_ids.empty? && scope_name != "business"
          branch_ids = current_user.shift_assignments.current.pluck(:branch_id).uniq
        end
        query = query.where(branch_id: branch_ids) unless branch_ids.empty?
      end
    end

    @accessible_branches = accessible_branches_for_dr

    # ── Optional filters ─────────────────────────────────────────────────────
    @filter_status       = params[:status].presence
    @filter_branch       = sticky_branch_filter
    @filter_date_from    = params[:from].presence
    @filter_date_to      = params[:to].presence
    @filter_bank_status  = @show_verification ? params[:verification_status].presence : nil
    @filter_bank_imported     = @show_verification && params[:bank_imported].presence == "1"
    @filter_outstanding_exists = @show_verification && params[:outstanding_exists].presence == "1"
    @filter_depositor_id = @show_verification ? params[:depositor_id].presence&.to_i : nil
    @selected_branch     = @accessible_branches.find { |b| b.id.to_s == @filter_branch.to_s } if @filter_branch.present?

    query = apply_dr_filters(query)

    if @show_verification
      all_drs = query.to_a

      # Preloaded once for the whole page instead of per-DR, so deriving
      # bank_reconciliation_status for up to 200 rows costs O(1) queries
      # total, not O(N).
      covering_statements = BankStatement.where(business_id: current_user.business_id)
                                         .active.completed.to_a
      review_transactions = BankStatementTransaction
                              .joins(:bank_statement)
                              .where(bank_statements: { business_id: current_user.business_id },
                                     status: "needs_manual_review")
                              .includes(:bank_statement)
                              .to_a

      statuses_by_dr = all_drs.index_with do |dr|
        dr.bank_reconciliation_status(covering_statements: covering_statements,
                                      review_transactions: review_transactions)
      end
      @bank_statement_imported_by_dr = all_drs.index_with do |dr|
        dr.bank_statement_imported?(covering_statements: covering_statements)
      end

      @bank_statuses_by_dr = statuses_by_dr

      # One query for the whole page (not one per DR) — which of these DRs
      # already has at least one matched SalesTransaction. Feeds the unified
      # "Next Step" workflow (DailyReconciliation#workflow_progress) — step 5
      # (Sales Import) counts as complete once any row exists for the DR.
      @sales_imported_dr_ids = SalesTransaction.where(daily_reconciliation_id: all_drs.map(&:id))
                                            .distinct.pluck(:daily_reconciliation_id).to_set

      # Same pattern for step 6 (POS Import) — one query for the whole page,
      # a plain existence check (no financial figures read here). Deliberately
      # ungated by view_pos_import — same as the Sales Import existence check
      # above, this only proves "was anything imported?", never amounts.
      @pos_imported_dr_ids = build_pos_imported_dr_ids(all_drs)

      # Issue badges (Unmatched POS Transactions / Unmatched Sales
      # Transactions / Outstanding Bank Deposits) surfaced directly on each
      # card — see build_dr_issue_badges. No new reconciliation rule: same
      # Finance::PosVerification::Comparator the DR show page already uses,
      # just precomputed once for the whole page instead of per-DR.
      build_dr_issue_badges(all_drs)

      # Orthogonal (non-exclusive) filters — apply first, independent of
      # bank_status/depositor ordering below.
      scope = all_drs
      scope = scope.select { |dr| @bank_statement_imported_by_dr[dr] } if @filter_bank_imported
      scope = scope.select { |dr| dr.total_remaining_balance.positive? } if @filter_outstanding_exists

      # Depositor facet (the <select> options + Top Depositors card) — tallied
      # from everything EXCEPT the depositor filter itself (so every
      # depositor stays choosable/switchable), but INCLUDING bank_status, so
      # the facet still narrows sensibly when a status card is active.
      # Depositor is already eager-loaded via till_session: depositor above —
      # no new query.
      scope_for_depositor_facet = @filter_bank_status ?
        scope.select { |dr| statuses_by_dr[dr] == @filter_bank_status } :
        scope
      depositor_counts = Hash.new(0)
      scope_for_depositor_facet.each do |dr|
        depositor = dr.till_session&.depositor
        depositor_counts[depositor] += 1 if depositor
      end
      @depositor_counts = depositor_counts.sort_by { |_user, count| -count }.to_h
      @top_depositors    = @depositor_counts.first(5)

      # Single source of truth for everything below: dashboard cards, the
      # reconciliation list, and every counter/total/percentage on the page.
      # When a depositor is selected, this — and therefore all of the
      # above — reflects ONLY that depositor's reconciliations; nothing here
      # is computed from the wider, unfiltered set.
      scope_for_dashboard = @filter_depositor_id ?
        scope.select { |dr| dr.till_session&.depositor_id == @filter_depositor_id } :
        scope

      # Workflow dashboard — count + total expected-cash amount per status,
      # computed from scope_for_dashboard (i.e. every active filter except
      # bank_status itself, which is what the cards toggle).
      @bank_status_counts  = Hash.new(0)
      @bank_status_amounts = Hash.new(0)
      scope_for_dashboard.each do |dr|
        status = statuses_by_dr[dr]
        @bank_status_counts[status]  += 1
        @bank_status_amounts[status] += dr.expected_cash_deposit
      end
      @bank_status_total_count = scope_for_dashboard.size

      # "Open Disputes" card — reactive to every active filter via
      # scope_for_dashboard, same single-source-of-truth pattern as the rest
      # of the dashboard. till_deposits/bank_disputes are already eager
      # loaded above, so this is pure Ruby, no new queries. Covers both
      # dispute kinds (missing-from-bank on a deposit, and ATM/POS failures
      # reported before any deposit exists) via DailyReconciliation#open_bank_disputes.
      open_disputes = scope_for_dashboard.flat_map { |dr|
        dr.open_bank_disputes(preloaded_till_deposits: dr.till_deposits.select(&:active?))
      }
      @open_dispute_count  = open_disputes.size
      @open_dispute_amount = open_disputes.sum(&:amount)

      @reconciliations = @filter_bank_status ?
        scope_for_dashboard.select { |dr| statuses_by_dr[dr] == @filter_bank_status } :
        scope_for_dashboard

      # Employee Sales Reconciliation issue badges — the heaviest per-DR
      # figure (Finance::EmployeeReconciliationSummarizer re-runs the
      # handover graph per DR, unchanged), so it only runs for the DRs
      # actually being rendered (@reconciliations, after every filter) —
      # never the wider up-to-200-row all_drs set — and is skipped entirely
      # for a DR with no imported Sales data at all.
      build_employee_issue_badges(@reconciliations)

      # Amount summary strip — totals across the final filtered set.
      @summary_expected = @reconciliations.sum(&:expected_cash_deposit)
      @summary_deposited = @reconciliations.sum(&:total_deposited)
      @summary_matched   = @reconciliations.sum(&:total_matched_amount)
      @summary_outstanding = @reconciliations.sum(&:total_remaining_balance)

      @empty_state_key = empty_state_key_for(@filter_bank_status) if @reconciliations.empty?
    else
      @reconciliations = query
    end

    @latest_sales_import = current_user.business.sales_imports.imported.order(updated_at: :desc)
                                     .includes(:imported_by).first if current_user.can?(:manage_sales_import)
  end

  # POST /finance/daily_reconciliations/bulk_settle
  def bulk_settle
    authorize DailyReconciliation, :bulk_settle?

    ids = Array(params[:ids]).map(&:to_i).uniq.reject(&:zero?)
    if ids.empty?
      return redirect_to finance_daily_reconciliations_path,
                         alert: t("finance.daily_reconciliations.errors.bulk_none_selected")
    end

    pm = business_payment_methods.find_by(id: params[:payment_method_id])
    unless pm
      return redirect_to finance_daily_reconciliations_path,
                         alert: t("finance.daily_reconciliations.errors.bulk_settle_no_pm")
    end

    reconciliations = policy_scope(DailyReconciliation)
                        .where(id: ids)
                        .includes(:business, :branch,
                                  remaining_deposit_balances: :balance_transactions)

    successes = 0
    failures  = 0

    reconciliations.each do |dr|
      dr.remaining_deposit_balances.open.each do |rdb|
        result = Finance::RemainingDepositBalanceSettler.new(
          rdb.id,
          actor:             current_user,
          amount:            rdb.remaining_amount,
          notes:             params[:notes].presence || t("finance.daily_reconciliations.bulk_settle_default_notes"),
          payment_method_id: pm.id,
          reference_number:  params[:reference_number].presence
        ).call
        result.ok? ? successes += 1 : failures += 1
      end
    end

    if failures.zero? && successes > 0
      redirect_to finance_daily_reconciliations_path(filter_params),
                  notice: t("finance.daily_reconciliations.bulk_settle_done", count: successes)
    elsif successes > 0
      redirect_to finance_daily_reconciliations_path(filter_params),
                  notice: t("finance.daily_reconciliations.bulk_settle_partial",
                             success: successes, failure: failures)
    else
      redirect_to finance_daily_reconciliations_path(filter_params),
                  alert: t("finance.daily_reconciliations.errors.bulk_settle_failed")
    end
  end

  # POST /finance/daily_reconciliations/bulk_receive_opening_float
  def bulk_receive_opening_float
    authorize DailyReconciliation, :bulk_receive_opening_float?

    ids = Array(params[:ids]).map(&:to_i).uniq.reject(&:zero?)
    if ids.empty?
      return redirect_to finance_daily_reconciliations_path,
                         alert: t("finance.daily_reconciliations.errors.bulk_none_selected")
    end

    reconciliations = policy_scope(DailyReconciliation)
                        .where(id: ids)
                        .includes(:business, :branch, :till_session,
                                  opening_float_source_handover: { amounts: :payment_method, from_user: [] })

    successes = 0
    failures  = 0

    reconciliations.each do |dr|
      next unless dr.opening_float_receivable?

      result = Finance::OpeningFloatReceiver.new(
        daily_reconciliation_id: dr.id,
        actor:                   current_user
      ).call
      result.ok? ? successes += 1 : failures += 1
    end

    if failures.zero? && successes > 0
      redirect_to finance_daily_reconciliations_path,
                  notice: t("finance.daily_reconciliations.bulk_opening_float_received", count: successes)
    elsif successes > 0
      redirect_to finance_daily_reconciliations_path,
                  notice: t("finance.daily_reconciliations.bulk_opening_float_partial",
                             success: successes, failure: failures)
    else
      redirect_to finance_daily_reconciliations_path,
                  alert: t("finance.daily_reconciliations.errors.bulk_receive_failed")
    end
  end

  # GET /finance/daily_reconciliations/export
  # Exports the currently selected (or, if none selected, currently filtered)
  # reconciliations as CSV, reusing Finance::Reports::CsvExporter/Table — no
  # new CSV-generation logic.
  def export
    authorize DailyReconciliation, :export?

    ids = Array(params[:ids]).map(&:to_i).uniq.reject(&:zero?)
    scope = policy_scope(DailyReconciliation)
              .includes(:branch, till_session: :depositor,
                        till_deposits: [ :deposit_matches, :bank_statement_transactions ],
                        remaining_deposit_balances: [])
    scope = ids.any? ? scope.where(id: ids) : apply_dr_filters(scope)

    table = Finance::Reports::Table.new(
      title: t("finance.daily_reconciliations.index.export_title"),
      columns: [
        Finance::Reports::Column.new(key: :branch,     label: t("finance.daily_reconciliations.index.export_col_branch")),
        Finance::Reports::Column.new(key: :date,       label: t("finance.daily_reconciliations.index.export_col_date")),
        Finance::Reports::Column.new(key: :status,     label: t("finance.daily_reconciliations.index.export_col_status")),
        Finance::Reports::Column.new(key: :expected,   label: t("finance.daily_reconciliations.index.export_col_expected"), money: true),
        Finance::Reports::Column.new(key: :deposited,  label: t("finance.daily_reconciliations.index.export_col_deposited"), money: true),
        Finance::Reports::Column.new(key: :matched,    label: t("finance.daily_reconciliations.index.export_col_matched"), money: true),
        Finance::Reports::Column.new(key: :remaining,  label: t("finance.daily_reconciliations.index.export_col_remaining"), money: true),
        Finance::Reports::Column.new(key: :outstanding, label: t("finance.daily_reconciliations.index.export_col_outstanding"), money: true),
        Finance::Reports::Column.new(key: :depositor,  label: t("finance.daily_reconciliations.index.export_col_depositor"))
      ],
      rows: scope.map { |dr|
        {
          branch:      dr.branch.name,
          date:        dr.business_date.iso8601,
          status:      t("finance.daily_reconciliations.index.bank_status.#{dr.bank_reconciliation_status}"),
          expected:    dr.expected_cash_deposit,
          deposited:   dr.total_deposited,
          matched:     dr.total_matched_amount,
          remaining:   dr.pending_deposit_amount,
          outstanding: dr.total_remaining_balance,
          depositor:   dr.till_session&.depositor&.full_name
        }
      }
    )

    send_data Finance::Reports::CsvExporter.new(table).to_csv,
              filename: "daily_reconciliations_#{Date.current.iso8601}.csv", type: "text/csv"
  end

  # GET /finance/daily_reconciliations/new
  def new
    authorize DailyReconciliation, :create?
    @branches = accessible_branches_for_dr
    redirect_to finance_daily_reconciliations_path,
                alert: t("finance.daily_reconciliations.errors.no_branch") if @branches.empty?
  end

  # GET /finance/daily_reconciliations/:id
  def show
    authorize @reconciliation

    # Previous/Next Day navigation — same branch only, adjacency is by
    # business_date (not id, which reflects creation order and can diverge
    # from the business-date sequence). policy_scope keeps this within
    # whatever branches/records the current user is authorized to see.
    @previous_reconciliation = policy_scope(DailyReconciliation)
                                  .where(branch_id: @reconciliation.branch_id)
                                  .where("business_date < ?", @reconciliation.business_date)
                                  .order(business_date: :desc)
                                  .first
    @next_reconciliation = policy_scope(DailyReconciliation)
                              .where(branch_id: @reconciliation.branch_id)
                              .where("business_date > ?", @reconciliation.business_date)
                              .order(business_date: :asc)
                              .first

    @session  = @reconciliation.till_session
    @handovers = @reconciliation.till_handovers
                                .includes(:from_user, :to_user, :cancelled_by,
                                          :reversed_by, :superseded_by,
                                          reversal_of_handover: :from_user,
                                          corrects_handover:    :from_user,
                                          amounts:              :payment_method,
                                          seeded_daily_reconciliation: [])
                                .order(:created_at)
    @waiting_for_opening_float = @reconciliation.blocked_by_opening_float?
    @opening_float_receivable  = @reconciliation.opening_float_receivable?

    if @waiting_for_opening_float
      source_handover = @reconciliation.opening_float_source_handover
      source_amounts  = source_handover&.amounts
                                       &.next_day
                                       &.includes(:payment_method)
                                       &.order("payment_methods.position")
                                       &.to_a || []

      @opening_float_source_handover    = source_amounts
      @opening_float_amounts_overridden = @reconciliation.opening_float_override_amounts.present?

      if @opening_float_amounts_overridden
        override_list = @reconciliation.opening_float_override_amounts

        # Load payment methods for canonical position ordering.
        pm_ids   = override_list.map { |o| o["payment_method_id"].to_i }.uniq
        pm_by_id = PaymentMethod.where(id: pm_ids).index_by(&:id)

        # Show only entries that will actually be transferred (non-zero amounts),
        # ordered by the payment method's configured position.
        @opening_float_display_amounts = override_list
          .select { |o| o["collected_amount"].to_d.positive? || o["refund_amount"].to_d.positive? }
          .sort_by { |o| pm_by_id[o["payment_method_id"].to_i]&.position || 9999 }
          .map do |o|
            OpeningFloatDisplayAmount.new(
              o["payment_method_name"],
              o["collected_amount"].to_d,
              o["refund_amount"].to_d
            )
          end
      else
        @opening_float_display_amounts = source_amounts
      end
    end

    @can_edit_opening_float = @waiting_for_opening_float &&
                              @reconciliation.opening_float_source_handover_id.present? &&
                              policy(@reconciliation).update_opening_float_amounts?
    @deposits  = @reconciliation.active_deposits
                               .includes(:payment_method, :deposited_by, :bank_disputes)
                               .order(:deposited_at)

    # "Open Deposit Verification" should land on whichever day(s) the actual
    # deposit(s) were recorded — which can differ from the DR's own business
    # date (e.g. a deposit made just after midnight). Falls back to the DR's
    # business date only when there are no active deposits yet to derive it
    # from. Voided deposits are excluded since @deposits is already
    # active-only.
    if @deposits.any?
      @deposit_verification_from = @deposits.first.deposited_at.to_date
      @deposit_verification_to   = @deposits.last.deposited_at.to_date
    else
      @deposit_verification_from = @reconciliation.business_date
      @deposit_verification_to   = @reconciliation.business_date
    end

    # Full deposit history (including voided) is needed only by the timeline.
    @all_deposits = @reconciliation.till_deposits
                                   .includes(:payment_method, :deposited_by, :voided_by,
                                             :bank_statement_transactions, :bank_disputes)
                                   .order(:deposited_at)

    @amounts_by_method = @reconciliation.session_amounts
                                        .includes(:payment_method)
                                        .order("payment_methods.position")
    @total_deposited   = @reconciliation.total_deposited

    # Independent refunds — never tied to a TillHandover. Loaded here (not
    # inside build_timeline_events) so the timeline builder stays query-free.
    @till_refunds = @reconciliation.till_refunds
                                   .includes(:payment_method, :processed_by)
                                   .order(:refunded_at)
    @total_refunds = @reconciliation.total_refunds
    # Traceability: lets the Session Totals table link the refund figure for a
    # payment method back to the individual TillRefund records behind it.
    @till_refunds_by_payment_method = @till_refunds.group_by(&:payment_method_id)

    @i_am_depositor = @session&.depositor_id == current_user.id
    @pending_handover_for_me   = @reconciliation.till_handovers.pending.find_by(to_user_id: current_user.id)
    @pending_outgoing_handover = @reconciliation.till_handovers.pending
                                               .find_by(from_user_id: current_user.id, self_deposit: false)

    @all_deposit_transfers     = @reconciliation.deposit_responsibility_transfers
                                                .includes(:from_user, :to_user, :cancelled_by)
                                                .order(:created_at)
    @pending_deposit_transfer          = @all_deposit_transfers.find(&:pending?)
    @pending_deposit_transfer_for_me   = @pending_deposit_transfer if @pending_deposit_transfer&.to_user_id   == current_user.id
    @pending_deposit_transfer_from_me  = @pending_deposit_transfer if @pending_deposit_transfer&.from_user_id == current_user.id

    @all_remaining_balances = @reconciliation.remaining_deposit_balances
                                              .includes(:responsible_user, :created_by, till_deposit: :payment_method)
                                              .includes(balance_transactions: %i[performed_by
                                                                                 previous_responsible_user
                                                                                 new_responsible_user
                                                                                 payment_method])
                                              .order(:created_at)
    @total_remaining_balance  = @reconciliation.total_remaining_balance
    @total_settled_later      = @reconciliation.total_settled_later
    @total_written_off        = @reconciliation.total_written_off

    @opening_float_leavable = (@reconciliation.closed? || @reconciliation.deposited?) &&
                              @handovers.none?(&:opening_float_declaration?) &&
                              BusinessDay.current(context: @reconciliation.business) == @reconciliation.business_date

    @can_view_session_totals     = policy(@reconciliation).view_session_totals?
    @can_edit_session_totals     = policy(@reconciliation).edit_session_totals?
    @can_edit_day_close_amounts  = policy(@reconciliation).edit_day_close_amounts?
    @can_view_all_summary        = policy(@reconciliation).view_all_employee_reconciliation_summary?
    @can_view_own_summary        = policy(@reconciliation).view_own_employee_reconciliation_summary?

    summarizer = Finance::EmployeeReconciliationSummarizer.new(@reconciliation)
    @employee_summaries = if @can_view_all_summary
      summarizer.summaries
    elsif @can_view_own_summary
      summarizer.summaries(for_user: current_user)
    end


    @session_amount_edits = AuditLog
                              .where(auditable: @reconciliation, action: "edit_session_totals")
                              .includes(:actor)
                              .order(:created_at)
                              .to_a

    day_close_handover = @reconciliation.day_close_handover
    @day_close_edits = if day_close_handover
      AuditLog
        .where(auditable: day_close_handover, action: "edit_day_close_amounts")
        .includes(:actor)
        .order(:created_at)
        .to_a
    else
      []
    end

    handover_ids = @handovers.map(&:id)
    @all_adjustments = handover_ids.any? ?
      FinancialAdjustment
        .where(adjustable_type: "TillHandover", adjustable_id: handover_ids)
        .includes(:actor, :approved_by)
        .order(:created_at) :
      []
    # Grouped for O(1) lookup per handover in the view (avoids N+1 on .select).
    @adjustments_by_handover_id = @all_adjustments.group_by(&:adjustable_id)

    # Historical events only — the Deposit Review workflow stage that
    # generated these has been removed, but past AuditLog rows still render
    # in the timeline/approval history for businesses that used it.
    @review_events = AuditLog
                        .where(auditable: @reconciliation,
                               action: %w[review_completed review_cancelled review_auto_cancelled])
                        .includes(:actor)
                        .order(:created_at)
                        .to_a

    deposit_ids = @all_deposits.map(&:id)
    @deposit_override_events = deposit_ids.any? ?
      AuditLog
        .where(auditable_type: "TillDeposit", auditable_id: deposit_ids, action: "deposit_review_overridden")
        .includes(:actor)
        .order(:created_at)
        .to_a :
      []

    bank_dispute_ids = (@reconciliation.bank_disputes.to_a + @all_deposits.flat_map(&:bank_disputes)).map(&:id).uniq
    @bank_dispute_events = bank_dispute_ids.any? ?
      AuditLog
        .where(auditable_type: "BankDispute", auditable_id: bank_dispute_ids)
        .includes(:actor)
        .order(:created_at)
        .to_a :
      []

    @timeline_events = build_timeline_events

    @can_manage_sales_import = policy(@reconciliation).manage_sales_import?
    @can_view_sales_transactions_verification = policy(@reconciliation).view_sales_transactions_verification?
    @can_view_pos_transaction_verification    = policy(@reconciliation).view_pos_transaction_verification?

    # Load Sales transactions linked to this DR for the comparison sections.
    # Gated on view_sales_transactions_verification — without it, none of this
    # data is loaded, so every Sales-derived UI section (comparison columns,
    # per-cashier breakdown, the dedicated verification section) stays hidden.
    if @can_view_sales_transactions_verification
      @sales_transactions = @reconciliation.sales_transactions
                                         .order(:transaction_date, :cashier_name, :payment_method_name)
                                         .to_a

      # Display-only ordering (transaction datetime ascending) for the "Sales
      # Transactions" review table — a separate array so @sales_transactions'
      # own order (grouping-friendly, used by the totals below) is untouched.
      # Sorts the already-loaded records in memory; no additional query.
      @sales_transactions_all_rows = @sales_transactions
        .sort_by { |t| [ t.transaction_date, t.transaction_time&.strftime("%H:%M:%S") || "" ] }

      # Sales CSV stores English payment method names; TillSessionAmount stores locale-specific
      # display names (e.g. "Cash" vs "نقداً"). Normalise on payment_method_id so comparisons
      # work regardless of the UI language. Fall back to the raw English name for any CSV method
      # that has no matching PaymentMethod record (shows as an unrecognised entry).
      biz_payment_methods      = PaymentMethod.for_business(@reconciliation.business).to_a
      @sales_payment_methods_by_id = biz_payment_methods.index_by(&:id)
      pm_id_by_english_name    = biz_payment_methods
                                   .each_with_object({}) { |pm, h| h[pm.name.downcase.strip] = pm.id }
      sales_method_key = ->(txn) { pm_id_by_english_name[txn.payment_method_name.downcase.strip] || txn.payment_method_name }

      # Groups the same, already-sorted @sales_transactions_all_rows by the
      # same key used for @sales_totals_by_method, so the per-payment-method
      # "Sales Transactions" disclosures below line up exactly with the
      # Session Totals rows they're nested under — no new query, no new
      # matching logic.
      @sales_transactions_by_payment_method = @sales_transactions_all_rows.group_by(&sales_method_key)

      # POS Transaction Verification — compares the Sales Transactions whose
      # payment method is flagged include_in_pos_verification (configured per
      # PaymentMethod — never hardcoded by name; see PaymentMethod#include_in_pos_verification)
      # against the real payment-terminal transactions imported for this
      # branch on this calendar date. Requires view_pos_import in addition to
      # the Sales gate above (see DailyReconciliationPolicy#view_pos_transaction_verification?)
      # since it displays Sales data alongside POS data.
      #
      # Deliberately uses PosTransaction.for_calendar_date, NOT
      # business_day/BusinessDay.for_timestamp — POS transactions are
      # external financial records reconciled against their actual Paid At
      # timestamp; business_day_start_hour rollover is an operational-data
      # concept (appointments, sales sessions, cash reconciliation) and must
      # never shift which day an imported POS transaction is attributed to.
      if @can_view_pos_transaction_verification
        pos_verification_method_ids = biz_payment_methods.select(&:include_in_pos_verification).map(&:id).to_set
        pos_verification_sales_transactions = @sales_transactions.select { |txn| pos_verification_method_ids.include?(sales_method_key.call(txn)) }

        pos_transactions = PosTransaction.for_calendar_date(
          branch: @reconciliation.branch, date: @reconciliation.business_date, business: @reconciliation.business
        ).order(:transaction_date).to_a

        @pos_verification = Finance::PosVerification::Comparator.call(pos_verification_sales_transactions, pos_transactions)
        @pos_verification_pos_transactions       = build_pos_verification_pos_transactions(@pos_verification)
        @pos_verification_unmatched_rows         = build_pos_verification_unmatched_rows(@pos_verification)
        @pos_verification_unmatched_sales_rows   = build_pos_verification_unmatched_sales_rows(@pos_verification)
      end

      # Gross/Refund/Net per payment method — refund? (transaction_type) is the
      # sole source of truth for which imported rows are refunds; amount itself
      # always stays a positive magnitude (see SalesTransaction#signed_amount).
      # Net (gross - refund) is what every downstream comparison against
      # WorkPulse's own totals must use, so refunds are never double-counted.
      @sales_totals_by_method  = @sales_transactions
                                 .group_by(&sales_method_key)
                                 .transform_values { |txns|
                                   sales, refunds = txns.partition(&:sale?)
                                   gross  = sales.sum(&:amount)
                                   refund = refunds.sum(&:amount)
                                   { gross: gross, refund: refund, net: gross - refund }
                                 }
      # Same Gross/Refund/Net shape as @sales_totals_by_method, scoped per
      # cashier — each SalesTransaction row (sale or refund) already carries
      # its own cashier_name from the import, so a refund performed by a
      # different employee than the original sale is naturally attributed to
      # whoever the source data says processed it, with no extra lookup.
      @sales_totals_by_cashier = @sales_transactions
                                 .group_by(&:cashier_name)
                                 .transform_values { |txns|
                                   txns.group_by(&sales_method_key)
                                       .transform_values { |t|
                                         sales, refunds = t.partition(&:sale?)
                                         gross  = sales.sum(&:amount)
                                         refund = refunds.sum(&:amount)
                                         { gross: gross, refund: refund, net: gross - refund }
                                       }
                                 }
      @latest_sales_import = current_user.business.sales_imports
                                       .where(id: @sales_transactions.map(&:sales_import_id).uniq)
                                       .order(updated_at: :desc).first

      # Electronic Payments always shows WorkPulse's own totals — by configured
      # payment method — regardless of whether a Sales file has been imported yet.
      # Reuses biz_payment_methods (already loaded above) rather than re-querying.
      @electronic_payment_methods = biz_payment_methods
                                       .reject(&:cash_like?)
                                       .select(&:active)
                                       .sort_by { |pm| [ pm.position, pm.name ] }
      amounts_by_pm_id = @amounts_by_method.index_by(&:payment_method_id)
      # WorkPulse's own Gross/Refund/Net per payment method, straight off
      # TillSessionAmount — the same record Finance::TillHandoverCreator.sync_session_amounts!
      # writes, which already folds independent TillRefund amounts into
      # refund_amount exactly once (see DailyReconciliation#refunds_by_payment_method).
      # No second refund calculation — this only exposes the three components
      # of a figure that was previously shown net-only.
      workpulse_breakdown = ->(pm) {
        sa = amounts_by_pm_id[pm.id]
        { collected: sa&.collected_amount || 0, refund: sa&.refund_amount || 0, net: sa&.net_amount || 0 }
      }
      @electronic_totals_by_method = @electronic_payment_methods.each_with_object({}) do |pm, h|
        h[pm.id] = workpulse_breakdown.call(pm)
      end
      @electronic_total = @electronic_totals_by_method.values.sum { |v| v[:net] }

      # Session Totals table: every configured payment method (cash included) as
      # a daily sales overview, distinct from the reconciliation table below
      # (which stays electronic-only). Cash figures are session-totals data, so
      # this is only built when the viewer also holds that permission —
      # otherwise it falls back to the electronic-only totals already built above.
      if @can_view_session_totals
        @all_payment_methods_for_cards = biz_payment_methods
                                            .select(&:active)
                                            .sort_by { |pm| [ pm.position, pm.name ] }
        @all_payment_method_totals = @all_payment_methods_for_cards.each_with_object({}) do |pm, h|
          h[pm.id] = workpulse_breakdown.call(pm)
        end
      end

      @session_totals_rows, @session_totals_grand_total = build_session_totals_rows
    end

    # Read-only display aggregates for the redesigned section layout.
    build_show_summary_aggregates
  end

  # POST /finance/daily_reconciliations
  def create
    authorize DailyReconciliation, :create?

    branch = resolve_branch
    return unless branch

    today = BusinessDay.current(context: branch.business)

    open_recon = DailyReconciliation.open_for(branch)
    if open_recon
      return redirect_to finance_daily_reconciliation_path(open_recon),
                         notice: t("finance.daily_reconciliations.errors.already_exists")
    end

    waiting_recon = DailyReconciliation.waiting_for(branch)
    if waiting_recon
      return redirect_to finance_daily_reconciliation_path(waiting_recon),
                         notice: t("finance.daily_reconciliations.errors.already_waiting")
    end

    closed_today = DailyReconciliation.where(branch: branch, business_date: today).first
    if closed_today
      return redirect_to finance_daily_reconciliation_path(closed_today),
                         notice: t("finance.daily_reconciliations.errors.already_exists")
    end

    recon = DailyReconciliation.create_for!(branch: branch, created_by: current_user)
    redirect_to finance_daily_reconciliation_path(recon),
                notice: t("finance.daily_reconciliations.created")
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    existing = DailyReconciliation.open_for(branch) ||
               DailyReconciliation.waiting_for(branch) ||
               DailyReconciliation.where(branch: branch, business_date: today).first
    if existing
      redirect_to finance_daily_reconciliation_path(existing),
                  notice: t("finance.daily_reconciliations.errors.already_exists")
    else
      redirect_to finance_daily_reconciliations_path,
                  alert: t("finance.daily_reconciliations.errors.create_failed")
    end
  end

  # PATCH /finance/daily_reconciliations/:id/verify
  def verify
    authorize @reconciliation, :verify?

    result = Finance::DailyReconciliationVerifier.new(
      @reconciliation.id,
      actor: current_user,
      notes: params[:notes]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.verified")
    else
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: result.error
    end
  end

  # GET /finance/daily_reconciliations/:id/edit_opening_float
  def edit_opening_float
    authorize @reconciliation, :update_opening_float_amounts?

    unless @reconciliation.blocked_by_opening_float?
      redirect_to finance_daily_reconciliation_path(@reconciliation) and return
    end

    load_edit_opening_float_data
  end

  # PATCH /finance/daily_reconciliations/:id/update_opening_float_amounts
  def update_opening_float_amounts
    authorize @reconciliation, :update_opening_float_amounts?

    result = Finance::OpeningFloatAmountsEditor.new(
      daily_reconciliation_id: @reconciliation.id,
      actor:                   current_user,
      amounts:                 params[:amounts]&.to_unsafe_h || {}
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.opening_float_amounts_saved")
    else
      load_edit_opening_float_data
      flash.now[:alert] = result.error
      render :edit_opening_float, status: :unprocessable_entity
    end
  end

  # POST /finance/daily_reconciliations/:id/receive_opening_float
  def receive_opening_float
    authorize @reconciliation, :receive_opening_float?

    result = Finance::OpeningFloatReceiver.new(
      daily_reconciliation_id: @reconciliation.id,
      actor:                   current_user
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.opening_float_received")
    else
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: result.error
    end
  end

  # GET /finance/daily_reconciliations/:id/correct_opening_float
  def correct_opening_float
    authorize @reconciliation, :correct_opening_float?

    unless @reconciliation.open? && @reconciliation.opening_float_source_handover_id.present?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: t("finance.daily_reconciliations.errors.correction_not_open")
      return
    end

    @opening_receipt = @reconciliation.till_handovers
                                      .peer.accepted
                                      .includes(amounts: :payment_method)
                                      .order(:created_at)
                                      .first

    if @opening_receipt.nil?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: t("finance.daily_reconciliations.errors.correction_no_opening_float")
      return
    end

    if @opening_receipt.superseded?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: t("finance.daily_reconciliations.errors.correction_already_corrected")
      return
    end

    @current_amounts = @opening_receipt.amounts.operational
                                       .includes(:payment_method)
                                       .order("payment_methods.position")
  end

  # PATCH /finance/daily_reconciliations/:id/update_opening_float_correction
  def update_opening_float_correction
    authorize @reconciliation, :correct_opening_float?

    result = Finance::OpeningFloatCorrector.new(
      daily_reconciliation_id: @reconciliation.id,
      actor:                   current_user,
      amounts:                 params[:amounts]&.to_unsafe_h || {},
      correction_reason:       params[:correction_reason]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.opening_float_correction_applied")
    else
      @opening_receipt = @reconciliation.till_handovers
                                        .peer.accepted
                                        .includes(amounts: :payment_method)
                                        .order(:created_at)
                                        .first
      @current_amounts = @opening_receipt&.amounts&.operational
                                         &.includes(:payment_method)
                                         &.order("payment_methods.position") || []
      flash.now[:alert] = result.error
      render :correct_opening_float, status: :unprocessable_entity
    end
  end

  # GET /finance/daily_reconciliations/:id/edit_session_totals
  def edit_session_totals
    authorize @reconciliation, :edit_session_totals?
    @amounts_by_method = @reconciliation.session_amounts
                                        .includes(:payment_method)
                                        .order("payment_methods.position")
    @edit_history = AuditLog
                      .where(auditable: @reconciliation, action: "edit_session_totals")
                      .includes(:actor)
                      .order(:created_at)
  end

  # PATCH /finance/daily_reconciliations/:id/update_session_totals
  def update_session_totals
    authorize @reconciliation, :edit_session_totals?

    result = Finance::SessionAmountsEditor.new(
      @reconciliation,
      actor:   current_user,
      amounts: (params[:amounts]&.to_unsafe_h || {}).transform_values { |v|
                 { collected_amount: v[:collected_amount], refund_amount: v[:refund_amount] }
               },
      notes:   params[:notes]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.session_totals_updated")
    else
      @amounts_by_method = @reconciliation.session_amounts
                                          .includes(:payment_method)
                                          .order("payment_methods.position")
      @edit_history = AuditLog
                        .where(auditable: @reconciliation, action: "edit_session_totals")
                        .includes(:actor)
                        .order(:created_at)
      flash.now[:alert] = result.error
      render :edit_session_totals, status: :unprocessable_entity
    end
  end

  # GET /finance/daily_reconciliations/:id/edit_day_close_amounts
  def edit_day_close_amounts
    authorize @reconciliation, :edit_day_close_amounts?
    @handover = @reconciliation.day_close_handover
    @amounts_by_method = @handover.amounts.operational
                                  .includes(:payment_method)
                                  .order("payment_methods.position")
    @edit_history = AuditLog
                      .where(auditable: @handover, action: "edit_day_close_amounts")
                      .includes(:actor)
                      .order(:created_at)
  end

  # PATCH /finance/daily_reconciliations/:id/update_day_close_amounts
  def update_day_close_amounts
    authorize @reconciliation, :edit_day_close_amounts?

    result = Finance::DayCloseEditor.new(
      @reconciliation,
      actor:   current_user,
      amounts: (params[:amounts]&.to_unsafe_h || {}).transform_values { |v|
                 { collected_amount: v[:collected_amount], refund_amount: v[:refund_amount] }
               },
      reason:  params[:reason]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.day_close_amounts_updated")
    else
      @handover = @reconciliation.day_close_handover
      @amounts_by_method = @handover.amounts.operational
                                    .includes(:payment_method)
                                    .order("payment_methods.position")
      @edit_history = AuditLog
                        .where(auditable: @handover, action: "edit_day_close_amounts")
                        .includes(:actor)
                        .order(:created_at)
      flash.now[:alert] = result.error
      render :edit_day_close_amounts, status: :unprocessable_entity
    end
  end

  # PATCH /finance/daily_reconciliations/:id/assign_depositor
  def assign_depositor
    authorize @reconciliation, :assign_depositor?

    result = Finance::DepositorAssigner.new(
      @reconciliation.id,
      actor:        current_user,
      depositor_id: params[:depositor_id]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.depositor_assigned")
    else
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: result.error
    end
  end

  private

  # Builds a flat, chronologically sorted array of timeline event hashes.
  # Each hash: { type: Symbol, time: Time, actor: User|nil, data: AR record }
  #
  # To add a new event type: push a hash here, then add a `when :new_type`
  # block in the view's case statement and add it to the appropriate stage in
  # STAGE_DEFS (see show.html.erb).
  def build_timeline_events
    events = []

    # The handover that received today's opening float (first transfer on this DR
    # when opening_float_source_handover is present).  Rendered differently from
    # a regular handover so it carries its own event type.
    opening_receipt_handover = if @reconciliation.opening_float_source_handover
                                 @handovers.first
    end

    @handovers.each do |h|
      if h.self_deposit? && h.opening_float_declaration?
        # A standalone "Leave Opening Float" action recorded after day close.
        if h.seeded_daily_reconciliation.present?
          events << { type: :opening_float_left, time: h.created_at, actor: h.from_user,
                      data: h, next_dr: h.seeded_daily_reconciliation }
        end
      elsif h.self_deposit?
        events << { type: :day_closed, time: h.created_at, actor: h.from_user, data: h }
        # If this self-deposit seeded the next day's DR, record the prepared event.
        # Pass the seeded DR (not the handover) so the view can display its business_date.
        if h.seeded_daily_reconciliation.present?
          events << { type: :opening_float_prepared, time: h.created_at, actor: h.from_user,
                      data: h.seeded_daily_reconciliation }
        end
      elsif h == opening_receipt_handover
        events << { type: :opening_float_received, time: h.accepted_at, actor: h.to_user, data: h } if h.accepted?
        events << { type: :opening_float_superseded, time: h.superseded_at, actor: h.superseded_by, data: h } if h.superseded?
      elsif h.correction?
        events << { type: :opening_float_corrected, time: h.accepted_at, actor: h.to_user, data: h }
      elsif h.reversal?
        # A compensating reversal handover — auto-accepted by the service.
        events << { type: :handover_reversal_applied, time: h.accepted_at, actor: h.from_user, data: h }
      else
        events << { type: :handover_created,   time: h.created_at,   actor: h.from_user,    data: h }
        events << { type: :handover_accepted,  time: h.accepted_at,  actor: h.to_user,      data: h } if h.accepted? && !h.reversed?
        events << { type: :handover_cancelled, time: h.cancelled_at, actor: h.cancelled_by, data: h } if h.cancelled?
        events << { type: :handover_rejected,  time: h.rejected_at,  actor: h.rejected_by,  data: h } if h.rejected?
        events << { type: :handover_reversed,  time: h.reversed_at,  actor: h.reversed_by,  data: h } if h.reversed?
      end
    end

    (@all_adjustments || []).each do |adj|
      events << { type: :handover_adjusted, time: adj.created_at, actor: adj.actor, data: adj }
    end

    (@all_deposit_transfers || []).each do |drt|
      events << { type: :deposit_assigned,  time: drt.created_at,   actor: drt.from_user,    data: drt }
      events << { type: :deposit_accepted,  time: drt.accepted_at,  actor: drt.to_user,      data: drt } if drt.accepted?
      events << { type: :deposit_cancelled, time: drt.cancelled_at, actor: drt.cancelled_by, data: drt } if drt.cancelled?
    end

    # Use @all_deposits (includes voided) so voids appear in the audit trail.
    (@all_deposits || @deposits).each do |d|
      events << { type: :deposit_recorded, time: d.deposited_at, actor: d.deposited_by, data: d }
      events << { type: :deposit_voided,   time: d.voided_at,    actor: d.voided_by,    data: d } if d.voided?
    end

    # Map ledger transaction types to timeline event symbols.
    txn_type_map = {
      "created"     => :remaining_created,
      "settlement"  => :remaining_settled,
      "reassignment"=> :remaining_reassigned,
      "write_off"   => :remaining_written_off,
      "adjustment"  => :remaining_adjusted
    }

    (@all_remaining_balances || []).each do |rdb|
      rdb.balance_transactions.each do |txn|
        type = txn_type_map[txn.transaction_type]
        next unless type

        event = { type: type, time: txn.created_at, actor: txn.performed_by, data: txn, balance: rdb }
        event.merge!(settlement_detail_for(txn, rdb)) if type == :remaining_settled
        events << event
      end
    end

    (@session_amount_edits || []).each do |log|
      events << { type: :session_totals_edited, time: log.created_at, actor: log.actor, data: log }
    end

    (@day_close_edits || []).each do |log|
      events << { type: :day_close_edited, time: log.created_at, actor: log.actor, data: log }
    end

    (@till_refunds || []).each do |r|
      events << { type: :till_refund_recorded, time: r.refunded_at, actor: r.processed_by, data: r }
    end

    review_type_map = {
      "review_completed"      => :review_completed,
      "review_cancelled"      => :review_cancelled,
      "review_auto_cancelled" => :review_auto_cancelled
    }

    (@review_events || []).each do |log|
      type = review_type_map[log.action]
      next unless type
      events << { type: type, time: log.created_at, actor: log.actor, data: log }
    end

    (@deposit_override_events || []).each do |log|
      events << { type: :deposit_review_overridden, time: log.created_at, actor: log.actor, data: log }
    end

    (@bank_dispute_events || []).each do |log|
      events << { type: :bank_dispute_activity, time: log.created_at, actor: log.actor, data: log }
    end

    if @reconciliation.verified?
      events << { type: :day_verified, time: @reconciliation.verified_at,
                  actor: @reconciliation.verified_by, data: @reconciliation }
    end

    events.sort_by! { |e| e[:time] }
  end

  # ── Partial Settlement timeline detail (presentation only) ────────────────
  # Adds payment_method / triggering_deposit / remaining_after to a
  # :remaining_settled timeline event so the audit timeline can show which
  # payment method was settled, the deposit that triggered it, and the
  # balance left afterward — without the accountant opening the deposit or
  # the Remaining Deposit Balance page. Reads only already-loaded
  # associations (@all_deposits, @all_remaining_balances); never touches
  # RemainingDepositBalance, its ledger, or any settlement rule.
  def settlement_detail_for(txn, rdb)
    triggering_deposit = triggering_deposit_for(txn, rdb)
    payment_method = txn.payment_method || triggering_deposit&.payment_method || rdb.till_deposit&.payment_method

    {
      payment_method:     payment_method,
      triggering_deposit: triggering_deposit,
      remaining_after:    remaining_balance_after(rdb, txn)
    }
  end

  # Finance::TillDepositRecorder#reconcile_remaining_balance! always creates
  # the TillDeposit row first, then synchronously — same request, same DB
  # transaction, a few milliseconds later — creates the resulting
  # "settlement" ledger transaction. The nearest deposit at-or-before the
  # settlement's own created_at, for the same payment method as the
  # balance's originating deposit, is therefore reliably the one that
  # triggered it. Manual settlements (recorded directly from the Remaining
  # Deposit Balance page, via Finance::RemainingDepositBalanceSettler) have
  # no triggering deposit at all — returns nil, and settlement_detail_for
  # falls back to the transaction's own payment_method_id in that case.
  def triggering_deposit_for(txn, rdb)
    return nil unless rdb.till_deposit

    pm_id = rdb.till_deposit.payment_method_id
    (@all_deposits || [])
      .select { |d| d.payment_method_id == pm_id && d.created_at <= txn.created_at }
      .max_by(&:created_at)
  end

  # Read-only replay of this balance's own ledger up to and including txn,
  # mirroring — never altering — the exact remaining_amount arithmetic each
  # service already applies: Finance::RemainingDepositBalanceSettler
  # (settlement: subtract), Finance::TillDepositRecorder#increase_remaining_balance!
  # (adjustment: add), Finance::RemainingDepositBalanceWriteOff (write_off:
  # zero), Finance::BankDisputes::RemainingBalanceReserver/Releaser
  # (dispute_reserved: subtract / dispute_released: add). reassignment never
  # touches the amount. balance.remaining_amount already holds the current/
  # latest value; this recomputes historical snapshots for past events only.
  def remaining_balance_after(rdb, txn)
    running = 0
    rdb.balance_transactions.sort_by(&:created_at).each do |t|
      case t.transaction_type
      when "created"          then running = t.amount
      when "settlement"       then running -= t.amount
      when "adjustment"       then running += t.amount
      when "write_off"        then running = 0
      when "dispute_reserved" then running -= t.amount
      when "dispute_released" then running += t.amount
      end
      break if t.id == txn.id
    end
    running
  end

  # Session Totals table: one row per configured payment method (cash included
  # when the viewer holds view_session_totals; electronic-only otherwise, same
  # fallback as the summary figures above) plus a Grand Total row. Reuses the
  # already-computed per-method totals and sales_totals_by_method — no new math,
  # just a join/sum over data built earlier in #show.
  # Gross/Refund/Net rows for the Session Totals table, on both sides:
  #   - workpulse_* comes from TillSessionAmount (via @all_payment_method_totals /
  #     @electronic_totals_by_method), which already folds independent
  #     TillRefund amounts in exactly once (sync_session_amounts!).
  #   - sales_* comes from @sales_totals_by_method, itself built from each
  #     SalesTransaction#refund? (transaction_type) — never guessed, never
  #     defaulted to cash.
  # difference/comparison always uses the two NET figures, per payment method,
  # so refunds are represented (not hidden) but never double-subtracted.
  def build_session_totals_rows
    methods      = @all_payment_methods_for_cards || @electronic_payment_methods
    totals_by_id = @all_payment_method_totals || @electronic_totals_by_method
    has_sales_data = @sales_totals_by_method.any?
    zero_breakdown = { gross: 0.to_d, refund: 0.to_d, net: 0.to_d }

    rows = methods.map do |pm|
      workpulse = totals_by_id[pm.id] || { collected: 0.to_d, refund: 0.to_d, net: 0.to_d }
      sales     = has_sales_data ? (@sales_totals_by_method[pm.id] || zero_breakdown) : nil
      difference = sales ? (workpulse[:net].to_d - sales[:net].to_d) : nil
      {
        payment_method:   pm,
        workpulse_gross:  workpulse[:collected],
        workpulse_refund: workpulse[:refund],
        workpulse_total:  workpulse[:net],
        sales_gross:      sales&.[](:gross),
        sales_refund:     sales&.[](:refund),
        sales_total:      sales&.[](:net),
        difference:       difference
      }
    end

    grand_total = {
      workpulse_gross:  rows.sum { |r| r[:workpulse_gross] },
      workpulse_refund: rows.sum { |r| r[:workpulse_refund] },
      workpulse_total:  rows.sum { |r| r[:workpulse_total] },
      sales_gross:      has_sales_data ? rows.sum { |r| r[:sales_gross].to_d } : nil,
      sales_refund:     has_sales_data ? rows.sum { |r| r[:sales_refund].to_d } : nil,
      sales_total:      has_sales_data ? rows.sum { |r| r[:sales_total].to_d } : nil,
      difference:       has_sales_data ? rows.sum { |r| r[:difference].to_d } : nil
    }

    [ rows, grand_total ]
  end

  # Every POS Transaction for the day, time-sorted — this section exposes
  # only the POS side (the DR already shows the Sales side elsewhere), with
  # no per-row match status displayed (the summary cards above already
  # surface the Difference; see Finance::PosVerification::Comparator::Result
  # for the matching detail this is derived from). Pure presentation
  # ordering — no financial totals are computed here; those are read
  # directly off the Result's own methods in the view.
  def build_pos_verification_pos_transactions(result)
    (result.matched_pairs.map(&:pos_transaction) + result.extra_in_pos).sort_by(&:transaction_date)
  end

  # Every POS Transaction the Comparator could NOT cleanly reconcile —
  # extra_in_pos (no matching Sales Transaction at all) and matched_pairs
  # flagged amount_mismatch? (matched by reference, but the amounts
  # disagree). No new reconciliation rule is introduced here; this only
  # reads the existing Result. Each row is
  # { transaction:, reason:, sales_employee: } — reason is one of
  # :no_matching_sales / :amount_mismatch, and sales_employee is the
  # matched SalesTransaction's cashier_name when one exists, else nil (view
  # renders "—").
  def build_pos_verification_unmatched_rows(result)
    rows = result.extra_in_pos.map { |txn| { transaction: txn, reason: :no_matching_sales, sales_employee: nil } }
    rows += result.matched_pairs.select(&:amount_mismatch?).map do |pair|
      { transaction: pair.pos_transaction, reason: :amount_mismatch, sales_employee: pair.sales_transaction.cashier_name }
    end
    rows.sort_by { |r| r[:transaction].transaction_date }
  end

  # Every Sales Transaction the Comparator could not match to any POS
  # Transaction at all (result.missing_from_pos) — no new reconciliation
  # rule, this only reads the existing Result. Sales Transactions matched by
  # reference but flagged amount_mismatch? did match (see
  # build_pos_verification_unmatched_rows) so they are excluded here.
  def build_pos_verification_unmatched_sales_rows(result)
    result.missing_from_pos
      .map { |txn| { transaction: txn, reason: :no_matching_pos } }
      .sort_by { |r| r[:transaction].transaction_date }
  end

  # DR ids where a PosTransaction already exists for the DR's own
  # (branch_id, business_date) — one query for the whole page, grouped in
  # Ruby by [branch_id, business-timezone calendar date] to mirror
  # PosTransaction.for_calendar_date's per-branch bucketing exactly. Feeds
  # DailyReconciliation#workflow_progress's step 6 (POS Import) completion
  # check — existence only, never reads amounts.
  def build_pos_imported_dr_ids(drs)
    dated_drs = drs.select(&:business_date)
    return Set.new if dated_drs.empty?

    business    = current_user.business
    tz          = business.timezone_object
    min_date    = dated_drs.map(&:business_date).min
    max_date    = dated_drs.map(&:business_date).max
    range_start = tz.local(min_date.year, min_date.month, min_date.day)
    range_end   = tz.local(max_date.year, max_date.month, max_date.day) + 1.day

    imported_branch_dates = PosTransaction
      .where(branch_id: dated_drs.map(&:branch_id).uniq, business_id: business.id)
      .where(transaction_date: range_start...range_end)
      .pluck(:branch_id, :transaction_date)
      .map { |branch_id, txn_date| [ branch_id, txn_date.in_time_zone(tz).to_date ] }
      .to_set

    dated_drs.select { |dr| imported_branch_dates.include?([ dr.branch_id, dr.business_date ]) }.map(&:id).to_set
  end

  # ── Index card issue badges ──────────────────────────────────────────────
  # Precomputes, for the whole page (up to 200 DRs) in a fixed small number
  # of queries, the same actionable-issue figures the DR show page already
  # surfaces one DR at a time — Outstanding (unmatched) Bank Deposits, and
  # (via the unchanged Finance::PosVerification::Comparator) counts of
  # Unmatched POS Transactions and Unmatched Sales Transactions. Sets
  # @unmatched_bank_deposits_count_by_dr, @pos_unmatched_count_by_dr and
  # @sales_unmatched_count_by_dr (both nil when the viewer lacks
  # view_sales_transactions_verification + view_pos_import) — the card
  # partial only reads these hashes. Cash Difference and overall Sales
  # Difference are deliberately NOT surfaced here — both are already visible
  # elsewhere on the card/page and would only duplicate that figure.
  def build_dr_issue_badges(drs)
    # Outstanding Bank Deposits — pure Ruby over the already-eager-loaded
    # till_deposits/deposit_matches associations (see index's .includes), so
    # this adds zero new queries.
    @unmatched_bank_deposits_count_by_dr = drs.index_with do |dr|
      dr.till_deposits.to_a.select(&:active?).count { |d| d.deposit_matches.to_a.empty? }
    end

    @can_view_pos_verification_index =
      current_user.can?(:view_sales_transactions_verification) && current_user.can?(:view_pos_import)
    return unless @can_view_pos_verification_index

    biz_payment_methods = PaymentMethod.for_business(current_user.business).to_a
    pm_id_by_english_name = biz_payment_methods.each_with_object({}) { |pm, h| h[pm.name.downcase.strip] = pm.id }
    pos_verification_method_ids = biz_payment_methods.select(&:include_in_pos_verification).map(&:id).to_set

    # One query for the whole page — every Sales Transaction belonging to
    # any of these DRs, grouped in Ruby by daily_reconciliation_id.
    sales_by_dr = SalesTransaction.where(daily_reconciliation_id: drs.map(&:id)).group_by(&:daily_reconciliation_id)

    # One query for the whole page — every PosTransaction for any branch/date
    # combination appearing in this list, grouped in Ruby by
    # [branch_id, business-timezone calendar date] to mirror
    # PosTransaction.for_calendar_date's per-branch bucketing exactly.
    business    = current_user.business
    tz          = business.timezone_object
    dated_drs   = drs.select(&:business_date)
    pos_by_branch_date = {}
    if dated_drs.any?
      min_date = dated_drs.map(&:business_date).min
      max_date = dated_drs.map(&:business_date).max
      range_start = tz.local(min_date.year, min_date.month, min_date.day)
      range_end   = tz.local(max_date.year, max_date.month, max_date.day) + 1.day

      pos_by_branch_date = PosTransaction
        .where(branch_id: dated_drs.map(&:branch_id).uniq, business_id: business.id)
        .where(transaction_date: range_start...range_end)
        .to_a
        .group_by { |t| [ t.branch_id, t.transaction_date.in_time_zone(tz).to_date ] }
    end

    @pos_unmatched_count_by_dr   = {}
    @sales_unmatched_count_by_dr = {}

    drs.each do |dr|
      next unless dr.business_date

      sales_for_dr = (sales_by_dr[dr.id] || []).select do |txn|
        pm_id = pm_id_by_english_name[txn.payment_method_name.downcase.strip] || txn.payment_method_name
        pos_verification_method_ids.include?(pm_id)
      end
      pos_for_dr = pos_by_branch_date[[ dr.branch_id, dr.business_date ]] || []
      next if sales_for_dr.empty? && pos_for_dr.empty?

      result = Finance::PosVerification::Comparator.call(sales_for_dr, pos_for_dr)
      unmatched_pos_count = result.extra_in_pos.size + result.matched_pairs.count(&:amount_mismatch?)
      @pos_unmatched_count_by_dr[dr.id]   = unmatched_pos_count if unmatched_pos_count.positive?
      @sales_unmatched_count_by_dr[dr.id] = result.missing_from_pos.size if result.missing_from_pos.any?
    end
  end

  # ── Index card issue badges: Employee Sales Reconciliation ──────────────
  # One badge per employee whose WorkPulse-recorded total (from the SAME
  # live Finance::EmployeeReconciliationSummarizer the DR show page's
  # "Sales Transactions Verification Summary" uses, unchanged) falls short
  # of what Sales Transactions show they actually took in — i.e. a
  # negative (WorkPulse − Sales Imported) difference. Deliberately the
  # heaviest figure on the card (the summarizer re-walks the handover graph
  # per DR), so it only ever runs for `drs` — callers must pass the final,
  # already-filtered/paginated set actually being rendered, never the wider
  # unfiltered list — and skips any DR with no imported Sales data at all
  # (has_sales_data false, same gate the show page's own partial uses).
  # Sets @employee_sales_issues_by_dr (dr.id => [{ user:, amount: }, ...]).
  def build_employee_issue_badges(drs)
    @employee_sales_issues_by_dr = Hash.new { |h, k| h[k] = [] }

    return unless current_user.can?(:view_all_employee_reconciliation_summary) &&
                  current_user.can?(:view_sales_transactions_verification)

    dr_ids = drs.map(&:id)
    return if dr_ids.empty?

    sales_by_dr = SalesTransaction.where(daily_reconciliation_id: dr_ids).group_by(&:daily_reconciliation_id)

    # Finance::EmployeeReconciliationSummarizer re-walks the handover graph
    # per DR (see its own class comment), but the query it runs to do so
    # (till_handovers + from_user/financial_adjustments/amounts:payment_method)
    # doesn't need to be per-DR — only the graph-walking algorithm does. One
    # query for every DR-with-sales-data on this page, grouped in Ruby,
    # instead of Finance::EmployeeReconciliationSummarizer#aggregate_by_employee
    # re-issuing that same shape of query once per DR.
    dr_ids_with_sales = sales_by_dr.keys
    handovers_by_dr = if dr_ids_with_sales.any?
      TillHandover.where(daily_reconciliation_id: dr_ids_with_sales)
                  .where("accepted_at IS NOT NULL OR self_deposit = TRUE")
                  .where(opening_float_declaration: false)
                  .includes(:from_user, :financial_adjustments, amounts: :payment_method)
                  .order(:created_at)
                  .group_by(&:daily_reconciliation_id)
    else
      {}
    end

    drs.each do |dr|
      sales_for_dr = sales_by_dr[dr.id]
      next if sales_for_dr.blank?

      sales_total_by_cashier = sales_for_dr
        .group_by { |txn| txn.cashier_name.to_s.downcase.strip }
        .transform_values { |txns| txns.sum(&:amount) }

      summarizer = Finance::EmployeeReconciliationSummarizer.new(dr, preloaded_handovers: handovers_by_dr[dr.id] || [])
      summarizer.summaries.each do |summary|
        next unless summary.user

        employee_sales_total = sales_total_by_cashier[summary.user.full_name.downcase.strip] || 0
        employee_difference  = summary.grand_total.to_d - employee_sales_total
        next unless employee_difference.negative?

        @employee_sales_issues_by_dr[dr.id] << { user: summary.user, amount: employee_difference.abs }
      end
    end
  end

  # ── Redesign display aggregates ─────────────────────────────────────────────
  # Pure read-only presentation figures (no mutation), assembled the same way as
  # the existing @sales_totals_* aggregates. Consumed by the section partials.
  def build_show_summary_aggregates
    # Cash payment-method ids drive the Cash Reconciliation per-employee filter.
    @cash_payment_method_ids = @amounts_by_method
                                 .select { |sa| sa.payment_method&.settlement_type == "cash" }
                                 .map(&:payment_method_id)

    # Financial headline figures (permission-gated).
    @total_sales     = @can_view_session_totals ? @amounts_by_method.sum(&:net_amount) : nil
    @expected_cash   = @can_view_session_totals ? @reconciliation.expected_cash_deposit : nil
    # Gross/Refund decomposition of @expected_cash, for display only ("Gross
    # Cash Sales" / "Cash Refunds" / "Expected Cash") — same @amounts_by_method
    # rows already loaded above, not a second query or a second calculation.
    # refund_amount here already includes any independent TillRefund, folded
    # in by Finance::TillHandoverCreator.sync_session_amounts! at close.
    if @can_view_session_totals
      cash_amounts        = @amounts_by_method.select { |sa| @cash_payment_method_ids.include?(sa.payment_method_id) }
      @expected_cash_gross   = cash_amounts.sum(&:collected_amount)
      @expected_cash_refunds = cash_amounts.sum(&:refund_amount)
    end
    # Open ATM Deposit Disputes (BankDispute kind: atm_deposit_failure) are cash
    # the employee has already accounted for outside the ordinary Deposit flow —
    # see DailyReconciliation#open_atm_dispute_amount/#pending_deposit_amount,
    # the same figures the Record Deposit dialog uses. They must be added to the
    # deposited side here too, or the difference wrongly shows the full expected
    # amount as missing even though it has been explained by an open dispute.
    @bank_dispute_amount = @expected_cash ? @reconciliation.open_atm_dispute_amount : nil
    @cash_difference     = @expected_cash ? (@total_deposited + @bank_dispute_amount - @expected_cash) : nil

    # Sales comparison headline (only when Sales data is loaded and viewable).
    # Uses @electronic_total (electronic payment methods only) rather than summing
    # all session amounts — cash never appears in a Sales import, so including it
    # here would show a permanent false "difference" equal to the day's cash sales.
    if @can_view_sales_transactions_verification && @sales_totals_by_method&.any?
      @sales_entered_total  = @electronic_total
      @sales_imported_total = @sales_totals_by_method.values.sum { |v| v[:net] }
      @sales_difference     = @sales_entered_total - @sales_imported_total
    end

    @can_view_deposit_verification = current_user.can?(:view_deposit_verification)
    build_bank_deposit_stats if @can_view_deposit_verification

    build_exceptions
  end

  # Compares this DR's deposits against the imported bank statement, scoped to
  # this branch + business_date. Mirrors Finance::DepositVerificationsController's
  # query style but narrowed to a single reconciliation.
  def build_bank_deposit_stats
    deposits = @reconciliation.till_deposits.active.left_joins(:bank_statement_transactions)

    # .distinct guards against a deposit matched by more than one transaction
    # being counted once per matching row (a plain LEFT JOIN fans out).
    @bank_matched_count      = deposits.where(bank_statement_transactions: { status: "verified" }).distinct.count
    @bank_needs_review_count = deposits.where(bank_statement_transactions: { status: "needs_manual_review" })
                                       .distinct.count
    @bank_imported_sum       = deposits.where(bank_statement_transactions: { status: "verified" })
                                       .sum("bank_statement_transactions.amount")

    unmatched = deposits.where(bank_statement_transactions: { id: nil })

    # A deposit only counts as "missing from bank" when a completed statement
    # actually covers this business day; otherwise it is just not imported yet.
    @bank_statement_covers_day = BankStatement
      .where(business_id: @reconciliation.business_id)
      .active.completed
      .where("statement_from <= :d AND statement_to >= :d", d: @reconciliation.business_date)
      .where("branch_id IS NULL OR branch_id = ?", @reconciliation.branch_id)
      .exists?
    unmatched_count          = unmatched.count
    @bank_missing_count      = @bank_statement_covers_day ? unmatched_count : 0
    @bank_not_imported_count = @bank_statement_covers_day ? 0 : unmatched_count

    # Bank transactions with no matching WorkPulse deposit for this branch/day.
    @bank_unexpected_transactions = BankStatementTransaction
      .for_business(@reconciliation.business)
      .joins(:bank_statement)
      .where(bank_statements: { branch_id: [ nil, @reconciliation.branch_id ] })
      .where.missing(:deposit_matches)
      .where(status: "unexpected", transaction_date: @reconciliation.business_date)
      .includes(:bank_statement)
      .to_a

    # Bank transactions matched to this DR's deposits but needing manual review.
    active_deposit_ids = @all_deposits.reject(&:voided?).map(&:id)
    @bank_review_transactions = if active_deposit_ids.any?
      BankStatementTransaction
        .joins(:deposit_matches)
        .where(deposit_matches: { till_deposit_id: active_deposit_ids }, status: "needs_manual_review")
        .includes(:bank_statement, :till_deposits)
        .to_a
    else
      []
    end

    @bank_difference = @total_deposited - @bank_imported_sum
  end

  # Assembles the unified Exceptions list from already-computed figures/records.
  def build_exceptions
    @exceptions = []

    (@bank_review_transactions || []).each do |txn|
      @exceptions << { type: :bank_needs_review, record: txn, amount: txn.amount, severity: :warning }
    end
    (@bank_unexpected_transactions || []).each do |txn|
      @exceptions << { type: :bank_unexpected, record: txn, amount: txn.amount, severity: :danger }
    end
    if @bank_missing_count.to_i.positive?
      @exceptions << { type: :missing_from_bank, count: @bank_missing_count, severity: :warning }
    end
    # Uses @total_remaining_balance (open RemainingDepositBalance amounts only —
    # same figure the Cash Reconciliation section and the index page's
    # outstanding badge use), not the raw @cash_difference. A shortfall always
    # gets an RDB created for it at deposit time (Finance::TillDepositRecorder);
    # once that RDB is settled or written off, @total_remaining_balance drops to
    # zero even though @cash_difference (the historical expected-vs-deposited
    # gap) still shows the original mismatch — so this exception must track the
    # former, not the latter, or a resolved shortfall would still page as open.
    if @total_remaining_balance.to_d.abs >= 0.01
      @exceptions << { type: :cash_difference, amount: @total_remaining_balance, severity: :warning, anchor: "cash-reconciliation" }
    end
    if @sales_difference && @sales_difference.abs >= 0.01
      @exceptions << { type: :sales_difference, amount: @sales_difference, severity: :warning, anchor: "electronic-payments" }
    end
    if @bank_difference && @bank_difference.abs >= 0.01
      @exceptions << { type: :bank_difference, amount: @bank_difference, severity: :warning, anchor: "bank-deposits" }
    end
  end

  def load_edit_opening_float_data
    @source_handover = @reconciliation.opening_float_source_handover
    source_amounts   = @source_handover&.amounts&.next_day&.includes(:payment_method)&.to_a || []
    source_by_pm_id  = source_amounts.index_by(&:payment_method_id)

    all_pms = PaymentMethod.active.ordered
                           .where(business_id: @reconciliation.business_id)
                           .to_a

    override_by_pm_id = (@reconciliation.opening_float_override_amounts || [])
                          .index_by { |o| o["payment_method_id"].to_i }

    # One row per active PM: pre-filled from override > source > 0
    @edit_rows = all_pms.map do |pm|
      src = source_by_pm_id[pm.id]
      ov  = override_by_pm_id[pm.id]
      {
        payment_method:   pm,
        source_amount_id: src&.id,
        collected:        ov ? ov["collected_amount"].to_d : (src&.collected_amount || 0),
        refund:           ov ? ov["refund_amount"].to_d    : (src&.refund_amount || 0)
      }
    end
  end

  def set_reconciliation
    @reconciliation = policy_scope(DailyReconciliation)
                        .includes(:branch, :business, :verified_by,
                                  session_amounts:               :payment_method,
                                  till_session:                  %i[depositor closed_by current_holder],
                                  opening_float_source_handover: { amounts: :payment_method, from_user: [] })
                        .find(params[:id])
  end

  def resolve_branch
    if params[:branch_id].present?
      accessible = accessible_branches_for_dr
      branch = accessible.find { |b| b.id == params[:branch_id].to_i }
      unless branch
        redirect_to new_finance_daily_reconciliation_path,
                    alert: t("finance.daily_reconciliations.errors.invalid_branch")
        return nil
      end
      branch
    else
      branches = accessible_branches_for_dr
      case branches.size
      when 0
        redirect_to finance_daily_reconciliations_path,
                    alert: t("finance.daily_reconciliations.errors.no_branch")
        nil
      when 1
        branches.first
      else
        redirect_to new_finance_daily_reconciliation_path
        nil
      end
    end
  end

  # The header branch selector is "sticky": once chosen, it stays selected
  # across filter changes, opening a reconciliation, returning to the index,
  # and plain page refreshes — without every link on the page needing to
  # carry branch_id explicitly. An explicit branch_id param (including a
  # blank one, from picking "All Branches") always wins and is remembered for
  # next time; only a request with no branch_id key at all (e.g. a nav link
  # elsewhere in the app) falls back to the last remembered choice — or, the
  # very first time (nothing remembered yet), to default_branch_filter's
  # priority order.
  def sticky_branch_filter
    if params.key?(:branch_id)
      session[:daily_reconciliations_branch_id] = params[:branch_id].presence
    elsif !session.key?(:daily_reconciliations_branch_id)
      session[:daily_reconciliations_branch_id] = default_branch_filter
    end

    session[:daily_reconciliations_branch_id]
  end

  # First-ever visit only (no explicit param, nothing remembered in session
  # yet). Priority: the user's only accessible sales branch (nothing else to
  # pick) > the branch from their current shift assignment (the same
  # "what's this user's branch" fallback already used above in
  # accessible_branches_for_dr) > All Branches.
  def default_branch_filter
    return @accessible_branches.first.id.to_s if @accessible_branches.size == 1

    shift_branch = current_user.effective_branch_on(Date.current)
    return shift_branch.id.to_s if shift_branch && @accessible_branches.include?(shift_branch)

    nil
  end

  # Only "sales" branches actually run Daily Reconciliations — warehouse,
  # laundry, headquarters, maintenance, and other operational units never
  # appear in this picker (see Branch#branch_type).
  def accessible_branches_for_dr
    return sales_branches.active.order(:name).to_a if current_user.owner?

    scope_name = current_user.scope_for(:view_daily_reconciliation)

    # nil scope is consistent with the index query: no explicit restriction → all branches.
    # An explicit scope (branch / area / business) narrows access via BranchScope.
    return sales_branches.active.order(:name).to_a unless scope_name

    ids = BranchScope.new(current_user).for_scope(scope_name)
    if ids.empty? && scope_name != "business"
      shift_branch = current_user.effective_branch_on(Date.current)
      return (shift_branch && shift_branch.branch_type == "sales") ? [ shift_branch ] : []
    end
    sales_branches.active.where(id: ids).order(:name).to_a
  end

  def sales_branches
    current_user.business.branches.where(branch_type: "sales")
  end

  def apply_dr_filters(query)
    case @filter_status
    when "waiting_opening"
      query = query.waiting_for_opening
    when "waiting_deposit"
      # Workflow-stage filter: day closed, no deposit recorded yet.
      # Distinct from "outstanding" below, which is a financial condition
      # (an open shortfall) that can co-exist with any state, including
      # verified.
      query = query.closed
    when "outstanding"
      query = query.joins(:remaining_deposit_balances)
                   .where(remaining_deposit_balances: { status: "open" })
                   .distinct
    when "waiting_verification"
      query = query.where(state: "closed").or(query.where(state: "deposited"))
                   .where(verified_at: nil)
    when "verified"
      query = query.where.not(verified_at: nil)
    end

    if @filter_branch.present?
      query = query.where(branch_id: @filter_branch.to_i)
    end

    date_from = Date.parse(@filter_date_from) rescue nil if @filter_date_from.present?
    date_to   = Date.parse(@filter_date_to) rescue nil if @filter_date_to.present?

    if date_from && date_to
      query = query.where(business_date: date_from..date_to)
    elsif date_from
      query = query.where(business_date: date_from..)
    elsif date_to
      query = query.where(business_date: ..date_to)
    end

    query
  end

  def filter_params
    params.permit(:status, :branch_id, :from, :to, :verification_status,
                  :bank_imported, :outstanding_exists, :depositor_id)
  end

  # Keys into finance.daily_reconciliations.index.empty_states.* — tailors the
  # empty-list message to whichever bank-status filter is active instead of a
  # single generic message.
  def empty_state_key_for(bank_status)
    return "generic" unless DailyReconciliation::BANK_RECONCILIATION_STATUSES.include?(bank_status)

    bank_status
  end
end
