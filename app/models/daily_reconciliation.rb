class DailyReconciliation < ApplicationRecord
  include AuditLoggable

  STATES = %w[open waiting_for_opening closed deposited verified].freeze
  enum :state, {
    open:                "open",
    waiting_for_opening: "waiting_for_opening",
    closed:              "closed",
    deposited:           "deposited",
    verified:            "verified"
  }

  # ── Aggregate root associations ──────────────────────────────────────────────
  belongs_to :branch
  belongs_to :business
  belongs_to :verified_by, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true

  # Set when a previous-day self-deposit handover carried next_day_amounts.
  # Cleared (set to nil) once the opening float has been received.
  belongs_to :opening_float_source_handover, class_name: "TillHandover", optional: true

  # TillSession is an internal operational child — never accessed independently.
  # Always created together with this record via create_for!.
  has_one :till_session,  foreign_key: :daily_reconciliation_id,
                          inverse_of:  :daily_reconciliation,
                          dependent:   :destroy

  has_many :till_handovers, foreign_key: :daily_reconciliation_id,
                            inverse_of:  :daily_reconciliation,
                            dependent:   :destroy

  has_many :till_deposits, foreign_key: :daily_reconciliation_id,
                           inverse_of:  :daily_reconciliation,
                           dependent:   :restrict_with_error

  # Official per-payment-method totals snapshot — written at day close.
  # Accounting data; owned by DR, not TillSession.
  has_many :session_amounts, class_name: "TillSessionAmount", dependent: :destroy

  has_many :deposit_responsibility_transfers, dependent: :destroy
  has_many :employee_reconciliation_summaries, dependent: :destroy
  has_many :remaining_deposit_balances, dependent: :destroy, inverse_of: :daily_reconciliation
  has_many :remaining_deposit_balance_transactions,
           through: :remaining_deposit_balances,
           source:  :balance_transactions

  has_many :pos_transactions, dependent: :destroy

  # Direct anchor for a BankDispute reported before any TillDeposit exists
  # (the ATM/POS "failed deposit" flow) — see #open_bank_disputes below for
  # the combined view including disputes anchored on a TillDeposit instead.
  has_many :bank_disputes, dependent: :restrict_with_error

  # ── Validations ──────────────────────────────────────────────────────────────
  validates :state,     inclusion: { in: STATES }
  validates :opened_at, presence: true
  validates :verified_at, presence: true, if: -> { verified_by.present? }

  # ── Scopes ───────────────────────────────────────────────────────────────────
  scope :for_business, ->(business) { where(business: business) }
  scope :for_branch,   ->(branch)   { where(branch: branch) }
  scope :ordered,      ->           { order(opened_at: :desc) }
  scope :verified,     ->           { where.not(verified_at: nil) }
  scope :unverified,   ->           { where(verified_at: nil) }

  def verified?   = verified_at.present?
  def unverified? = !verified?

  def reviewed? = reviewed_at.present?

  # Called by any service that mutates financial data or custody after a
  # review was already completed. No-ops (and logs nothing) if not currently
  # reviewed, matching the "only log if something actually changed"
  # convention used by DayCloseEditor/SessionAmountsEditor.
  def clear_review!(actor:)
    return unless reviewed?

    update!(reviewed_at: nil, reviewed_by_id: nil)
    log_audit(actor: actor, auditable: self, action: "review_auto_cancelled",
              metadata: { reason: "Financial data changed after review." })
  end

  # The self-deposit handover that closed the accounting day (as opposed to a
  # standalone "leave opening float" self-deposit, which also sets
  # self_deposit: true but is not the closing event).
  def day_close_handover
    till_handovers.find_by(self_deposit: true, opening_float_declaration: false)
  end

  def active_deposits = till_deposits.active
  def total_deposited = till_deposits.active.sum(:amount)

  # Sum of cash-like session amounts — the target the depositor is responsible for.
  def expected_cash_deposit
    session_amounts.joins(:payment_method)
                   .where(payment_methods: { settlement_type: "cash" })
                   .sum("collected_amount - refund_amount")
  end

  # Cash already accounted for by an OPEN "cash never reached the bank" ATM
  # Deposit Dispute (BankDispute kind: atm_deposit_failure) — the employee
  # has already declared what happened to this money, so it must not also
  # sit in "still owed" via the ordinary Deposit workflow at the same time.
  # Disputes of the *other* kind (missing_from_bank) are anchored on an
  # already-recorded TillDeposit, so their amount is already inside
  # total_deposited — counting those here too would double-subtract.
  def open_atm_dispute_amount
    bank_disputes.atm_deposit_failure.open_cases.sum(:amount)
  end

  # How much is still outstanding before this deposit form is submitted.
  # Successful deposits AND open ATM Deposit Disputes both reduce this —
  # disputed cash is being tracked by the Bank Dispute workflow instead of
  # the Deposit workflow until that dispute resolves.
  def pending_deposit_amount
    (expected_cash_deposit - total_deposited - open_atm_dispute_amount).clamp(0, Float::INFINITY)
  end

  # Per-payment-method remaining balance still owed — the single source of
  # truth for both the Record Deposit dialog's displayed figures and
  # TillDepositRecorder's over-deposit guard, so the two can never disagree.
  #
  # BankDispute carries no payment_method_id of its own, so an open ATM
  # Deposit Dispute's amount can't be attributed to one specific cash-like
  # payment method — it's spread across all of them *proportionally* to each
  # method's own remaining base, not dumped entirely onto whichever one
  # happens to sort first. That keeps this method's sum, across every
  # payment method, always exactly equal to #pending_deposit_amount (the
  # DR-wide figure) — e.g. Cash A=325 remaining / Cash B=650 remaining with a
  # 200 open dispute yields 258.33 / 516.67 (975 total, minus 200 = 775),
  # never a lopsided 125 / 650 from handing the whole dispute to Cash A alone
  # just because it happens to be positioned first. Never negative.
  def remaining_by_payment_method
    already_deposited = till_deposits.active.group(:payment_method_id).sum(:amount)
    amounts = session_amounts.includes(:payment_method).order("payment_methods.position").to_a

    bases = amounts.to_h do |sa|
      base = sa.net_amount - (already_deposited[sa.payment_method_id] || 0)
      [ sa.payment_method_id, [ base, 0 ].max ]
    end

    cash_pm_ids     = amounts.select { |sa| sa.payment_method.cash_like? }.map(&:payment_method_id)
    cash_base_total = bases.values_at(*cash_pm_ids).sum
    dispute_pool    = open_atm_dispute_amount

    bases.each_with_object({}) do |(pm_id, base), remaining|
      if cash_pm_ids.include?(pm_id) && dispute_pool.positive? && cash_base_total.positive?
        share = dispute_pool * base / cash_base_total
        base  = [ base - share, 0 ].max
      end

      remaining[pm_id] = base
    end
  end

  # Sum of currently outstanding cash across all open remaining balances.
  def total_remaining_balance
    remaining_deposit_balances.open.sum(:remaining_amount)
  end

  # Cash that was outstanding at close but settled later via the ledger.
  def total_settled_later
    remaining_deposit_balance_transactions
      .joins(:remaining_deposit_balance)
      .where(remaining_deposit_balances: { status: "settled" },
             remaining_deposit_balance_transactions: { transaction_type: "settlement" })
      .sum("remaining_deposit_balance_transactions.amount")
  end

  # Cash written off by management decision.
  def total_written_off
    remaining_deposit_balance_transactions
      .where(transaction_type: "write_off")
      .sum("remaining_deposit_balance_transactions.amount")
  end

  # ── Bank reconciliation status ───────────────────────────────────────────────
  # A single derived status representing overall bank-reconciliation progress,
  # in strict priority order (first match wins). Never persisted — always
  # computed live from active_deposits / TillDeposit#match_status / matched
  # BankStatementTransactions, so it can never drift from the underlying data.
  #
  # covering_statements / review_transactions let a caller iterating many DRs
  # (the index page) preload these once for the whole business and pass them
  # in, instead of this method re-querying per DR (see
  # Finance::DailyReconciliationsController#index).
  BANK_RECONCILIATION_STATUSES = %w[
    no_bank_transactions waiting_for_deposit waiting_for_bank_statement
    waiting_for_matching needs_review difference_found partially_matched completed
  ].freeze

  def bank_reconciliation_status(covering_statements: nil, review_transactions: nil)
    return "no_bank_transactions" if expected_cash_deposit.zero?

    deposits = active_deposits.to_a
    return "waiting_for_deposit" if deposits.empty?

    # A deposit's match can come from a bank transaction whose own
    # statement date range does not include the deposit's date at all —
    # Finance::BankStatements::ManualMatcher explicitly allows this (e.g.
    # "the bank processed it after midnight"), and DepositConfirmer's
    # deposits are matched/closed immediately with no date relationship to
    # any statement either. So a deposit that already has ANY match proves
    # a statement covered it in practice, regardless of what the date-range
    # heuristic below says — only fall back to that heuristic while nothing
    # is matched yet. Without this, a fully-matched DR could permanently
    # show "waiting_for_bank_statement" even at 1/1 matched deposits.
    already_matched = deposits.any? { |d| d.match_status != :unmatched }
    unless already_matched || bank_statement_covers_deposits?(deposits, covering_statements)
      return "waiting_for_bank_statement"
    end

    return "needs_review" if bank_transactions_need_review?(deposits, review_transactions)

    return "waiting_for_matching" if deposits.all? { |d| d.match_status == :unmatched }

    return "difference_found" if deposits.any? { |d| deposit_has_bank_difference?(d) }

    deposits.all? { |d| d.match_status == :fully_matched } ? "completed" : "partially_matched"
  end

  def bank_reconciliation_deposits_matched_count
    active_deposits.to_a.count { |d| d.match_status == :fully_matched }
  end

  def bank_reconciliation_deposits_total_count
    active_deposits.to_a.size
  end

  # Sum of every active deposit's matched-in-bank contribution — the
  # "Matched in Bank" figure on the workspace card. Reuses
  # TillDeposit#matched_total; no new query beyond active_deposits itself.
  def total_matched_amount
    active_deposits.to_a.sum(&:matched_total)
  end

  # Every still-open BankDispute on this DR, regardless of which anchor it
  # uses (an already-recorded active TillDeposit that's missing from the bank
  # statement, or a direct report for cash that never reached the bank at
  # all). Single source of truth for the DR show page badge, the index card,
  # and the workspace dashboard's "Open Bank Disputes" count/amount.
  # preloaded_till_deposits lets index-page callers reuse an already-loaded
  # array instead of a fresh query per DR.
  def open_bank_disputes(preloaded_till_deposits: nil)
    from_deposits = (preloaded_till_deposits || active_deposits.to_a).flat_map(&:bank_disputes)
    (from_deposits + bank_disputes).uniq.reject(&:resolved?)
  end

  # ── Single source of truth for the index card's "Next Action" — the ONE
  # highest-priority, permission-gated step guiding the accountant toward
  # completing this reconciliation. Priority order is authoritative: the
  # first matching workflow-state branch wins, and if the current user lacks
  # permission for THAT action, the whole call returns nil (no cascading to
  # a lower-priority action the user might happen to be allowed to do — the
  # workflow order, not permission, decides WHICH action is "next").
  #
  # bank_status/open_disputes are accepted as optional pre-computed args
  # (matching #bank_reconciliation_status's own covering_statements: pattern)
  # so index-page callers can reuse the batch-computed @bank_statuses_by_dr /
  # per-DR dispute arrays already built to avoid N+1 — this method itself
  # runs no additional queries beyond what's already eager-loaded.
  #
  # Every gate below delegates to the SAME Pundit policy method that already
  # authorizes the destination action/page, so this never drifts from real
  # authorization logic. permission: in the returned hash is a human-
  # readable label for the underlying check, not necessarily a literal
  # PermissionRole permission key (e.g. "create_opening_balance" describes
  # DailyReconciliationPolicy#receive_opening_float?'s composite
  # cashier-permission check; "record_deposit" describes the real
  # create_till_deposit permission plus TillDepositPolicy#create?'s
  # depositor-assignment/review-lock rules).
  def next_action_for(user, bank_status: nil, open_disputes: [])
    routes = Rails.application.routes.url_helpers
    t = ->(key) { I18n.t("finance.daily_reconciliations.index.workspace.quick_actions.#{key}") }
    primary_style = "btn btn-primary btn-sm"

    if opening_float_receivable?
      return nil unless DailyReconciliationPolicy.new(user, self).receive_opening_float?

      { label: t.call(:enter_opening_balance), icon: "wallet",
        path: routes.finance_daily_reconciliation_path(self),
        permission: "create_opening_balance", style: primary_style, method: :get }

    elsif closed?
      return nil unless TillDepositPolicy.new(user, TillDeposit.new(daily_reconciliation: self)).create?

      { label: t.call(:record_deposit), icon: "plus-circle",
        path: routes.new_till_deposit_path(daily_reconciliation_id: id),
        permission: "record_deposit", style: primary_style, method: :get }

    elsif remaining_deposit_balances.select(&:open?).sum(&:remaining_amount).positive?
      return nil unless TillDepositPolicy.new(user, TillDeposit.new(daily_reconciliation: self)).create?

      { label: t.call(:record_additional_deposit), icon: "plus-circle",
        path: routes.new_till_deposit_path(daily_reconciliation_id: id),
        permission: "record_deposit", style: primary_style, method: :get }

    elsif bank_status == "waiting_for_bank_statement"
      return nil unless user.can?(:import_bank_statement)

      { label: t.call(:import_statement), icon: "upload",
        path: routes.new_finance_bank_statement_path,
        permission: "import_bank_statement", style: primary_style, method: :get }

    elsif %w[needs_review waiting_for_matching difference_found partially_matched].include?(bank_status)
      return nil unless TillDepositPolicy.new(user, TillDeposit.new(daily_reconciliation: self)).match?

      { label: t.call(:match_transactions), icon: "git-merge",
        path: routes.finance_daily_reconciliation_path(self, anchor: "bank-deposits"),
        permission: "match_bank_transactions", style: primary_style, method: :get }

    elsif deposited? && !reviewed?
      return nil unless DailyReconciliationPolicy.new(user, self).mark_reviewed?

      { label: t.call(:review_reconciliation), icon: "check-square",
        path: routes.finance_daily_reconciliation_path(self, anchor: "approval"),
        permission: "review_daily_reconciliation", style: primary_style, method: :get }

    elsif deposited? && reviewed? && !verified?
      return nil unless DailyReconciliationPolicy.new(user, self).verify?

      { label: t.call(:verify_reconciliation), icon: "shield-check",
        path: routes.finance_daily_reconciliation_path(self, anchor: "approval"),
        permission: "verify_daily_reconciliation", style: primary_style, method: :get }

    elsif open_disputes.any?
      return nil unless BankDisputePolicy.new(user, open_disputes.first).update_case?

      { label: t.call(:review_bank_dispute), icon: "alert-triangle",
        path: routes.finance_daily_reconciliation_path(self, anchor: "bank-deposits"),
        permission: "resolve_bank_dispute", style: "btn btn-warning btn-sm", method: :get }

    end
    # Verified (or any other state not matched above) → no action, View only.
  end

  # Public wrapper around the private bank_statement_covers_deposits? check,
  # for the "Bank Imported" filter and the workflow-timeline stage below.
  # False (not "unknown") when there are no active deposits to check coverage
  # against yet. Same "already matched proves a statement was imported"
  # override as #bank_reconciliation_status above — see its comment — so
  # this can never say "not imported" while a deposit is already matched.
  def bank_statement_imported?(covering_statements: nil)
    deposits = active_deposits.to_a
    return false if deposits.empty?

    deposits.any? { |d| d.match_status != :unmatched } ||
      bank_statement_covers_deposits?(deposits, covering_statements)
  end

  # Ordered stages reached so far, for the compact workflow-timeline
  # indicator. Purely derived from existing signals — no new stored state.
  # covering_statements lets index-page callers reuse the same preloaded
  # array as bank_reconciliation_status instead of a fresh query per DR.
  WORKFLOW_STAGES = %i[open deposit_recorded bank_statement_imported matched verified completed].freeze

  def workflow_stages(covering_statements: nil, review_transactions: nil)
    stages = [ :open ]
    stages << :deposit_recorded if total_deposited.positive?
    stages << :bank_statement_imported if stages.include?(:deposit_recorded) &&
                                         bank_statement_imported?(covering_statements: covering_statements)
    stages << :matched if active_deposits.to_a.any? { |d| d.match_status != :unmatched }
    stages << :verified if reviewed?
    stages << :completed if bank_reconciliation_status(covering_statements: covering_statements,
                                                        review_transactions: review_transactions) == "completed"
    stages
  end

  # Returns the current open reconciliation for a branch, or nil.
  # Never creates — use create_for! to open a new accounting day.
  def self.open_for(branch)
    open.find_by(branch: branch)
  end

  # Returns a waiting_for_opening reconciliation for a branch, or nil.
  def self.waiting_for(branch)
    waiting_for_opening.find_by(branch: branch)
  end

  # True when the DR is blocked pending opening float receipt.
  def blocked_by_opening_float?
    waiting_for_opening?
  end

  # True when the float may actually be received.
  # Receivable as soon as the current Business Day has advanced past the float's
  # date — i.e. business_date is today OR any earlier date still in waiting state
  # (stale record that was never received).  The business day rolls over at
  # business.business_day_start_hour, never at midnight.
  def opening_float_receivable?
    waiting_for_opening? &&
      business_date <= BusinessDay.current(context: business)
  end

  # Creates a new DailyReconciliation and its child TillSession atomically.
  # This is the only place a TillSession may be created.
  # If either record fails, the entire transaction rolls back.
  #
  # business_date is stamped at creation using BusinessDay so the DR carries
  # the correct accounting date even if it is closed after the day rolls over.
  #
  # current_holder is intentionally NOT pre-set.  Custody is established the
  # moment the first handover is accepted; until then no one "holds" the till,
  # and the closing validation ("block only if someone else holds it") correctly
  # allows the acting cashier to proceed.
  def self.create_for!(branch:, created_by: nil) # created_by kept for call-site compatibility
    transaction do
      reconciliation = create!(
        branch:        branch,
        business:      branch.business,
        state:         "open",
        opened_at:     Time.current,
        business_date: BusinessDay.current(context: branch.business)
      )

      reconciliation.create_till_session!

      reconciliation
    end
  end

  # Creates a next-day DR in waiting_for_opening state with a child TillSession
  # (no holder yet). Called only by Finance::NextDayDrPreparer — never directly.
  def self.prepare_for_next_day!(branch:, business_date:, source_handover:)
    transaction do
      reconciliation = create!(
        branch:                       branch,
        business:                     branch.business,
        state:                        "waiting_for_opening",
        opened_at:                    Time.current,
        business_date:                business_date,
        opening_float_source_handover: source_handover
      )

      reconciliation.create_till_session!

      reconciliation
    end
  end

  private

  # Does any completed, non-voided BankStatement (this business, this branch
  # or a business-wide one) overlap the date range spanned by these deposits?
  # An overlap check, not "every individual date covered" — matches the
  # existing simplification already used for the show page's equivalent
  # concept (@bank_statement_covers_day in build_bank_deposit_stats).
  def bank_statement_covers_deposits?(deposits, preloaded = nil)
    dates = deposits.map { |d| d.deposited_at.to_date }
    from, to = dates.min, dates.max

    if preloaded
      preloaded.any? do |s|
        (s.branch_id.nil? || s.branch_id == branch_id) &&
          s.statement_from <= to && s.statement_to >= from
      end
    else
      BankStatement.where(business_id: business_id).active.completed
                   .where("branch_id IS NULL OR branch_id = ?", branch_id)
                   .where("statement_from <= ? AND statement_to >= ?", to, from)
                   .exists?
    end
  end

  # True when either (a) a transaction already matched to one of these
  # deposits was flagged needs_reverification (a post-match edit invalidated
  # it — see TillDeposit#invalidate_bank_verification_if_critical_change), or
  # (b) an unmatched candidate transaction in the same branch/date range is
  # needs_manual_review. (b) transactions have no deposit link by definition
  # (that's precisely why they're ambiguous), so they can only be attributed
  # to this DR by branch + date-range overlap, not by association.
  def bank_transactions_need_review?(deposits, preloaded = nil)
    return true if deposits.any? { |d| d.bank_statement_transactions.any?(&:needs_reverification?) }

    dates = deposits.map { |d| d.deposited_at.to_date }
    from, to = dates.min, dates.max

    if preloaded
      preloaded.any? do |t|
        stmt = t.bank_statement
        (stmt.branch_id.nil? || stmt.branch_id == branch_id) &&
          t.transaction_date.between?(from, to)
      end
    else
      BankStatementTransaction.joins(:bank_statement)
                              .where(bank_statements: { business_id: business_id })
                              .where("bank_statements.branch_id IS NULL OR bank_statements.branch_id = ?", branch_id)
                              .where(status: "needs_manual_review")
                              .where(transaction_date: from..to)
                              .exists?
    end
  end

  def deposit_has_bank_difference?(deposit)
    return true if deposit.match_status == :over_matched

    deposit.bank_statement_transactions.any? { |t| t.amount_mismatch? || t.date_mismatch? }
  end
end
