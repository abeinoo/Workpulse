module Finance
  module Dashboard
    # Human-readable presentation layer for the Recent Activity feed
    # (Finance::DashboardController#load_recent_activity) — wraps a single
    # AuditLog and turns its raw (auditable_type, action) pair into a
    # business-facing Arabic/English sentence, never a Rails class/action
    # name. This is the ONLY translation from AuditLog into display text;
    # the view must not build its own labels.
    #
    # Does not read/write anything — pure presentation over an already-
    # written AuditLog row. Adding a new log_audit call site for one of the
    # four RECENT_ACTIVITY_TYPES models means adding an entry to LABEL_KEYS
    # (and the matching config/locales/{ar,en}.yml keys) — anything left
    # unmapped renders a safe generic sentence and logs a warning instead of
    # ever leaking a class/action name to a user.
    class ActivityPresenter
      # {auditable_type => {action => i18n key suffix}} — every (model,
      # action) pair reachable through Finance::DashboardController::
      # RECENT_ACTIVITY_TYPES, enumerated against every log_audit call site
      # for each of those four models.
      LABEL_KEYS = {
        "Expense" => {
          "submit"                       => "expense_submit",
          "approve"                      => "expense_approve",
          "reject"                       => "expense_reject",
          "settle_from_custody"          => "expense_settle_from_custody",
          "pos_import_expense_generated" => "expense_pos_import_generated",
          "recurring_generate"           => "expense_recurring_generate"
        },
        "TillDeposit" => {
          "create"                     => "till_deposit_create",
          "deposit_review_overridden"  => "till_deposit_review_overridden",
          "void"                       => "till_deposit_void"
        },
        "CustodyTransaction" => {
          "balance_top_up"                     => "custody_balance_top_up",
          "balance_expense_deduction"          => "custody_balance_expense_deduction",
          "balance_transfer"                   => "custody_balance_transfer",
          "balance_adjustment"                 => "custody_balance_adjustment",
          "balance_inventory_purchase"         => "custody_balance_inventory_purchase",
          "balance_inventory_purchase_reversal" => "custody_balance_inventory_purchase_reversal",
          "custody_void"                       => "custody_void"
        },
        "RemainingDepositBalance" => {
          "create"            => "remaining_deposit_balance_create",
          "adjustment"        => "remaining_deposit_balance_adjustment",
          "settle"            => "remaining_deposit_balance_settle",
          "write_off"         => "remaining_deposit_balance_write_off",
          "reassign"          => "remaining_deposit_balance_reassign",
          "dispute_reserved"  => "remaining_deposit_balance_dispute_reserved",
          "dispute_released"  => "remaining_deposit_balance_dispute_released"
        }
      }.freeze

      # Actions whose logged record reliably carries a plain amount — cross-
      # checked against each log_audit call site's actual metadata:/changes:
      # payload (see class comment). An action not listed here never shows
      # an amount, even if `metadata["amount"]` happens to be present, so a
      # future log_audit call can't accidentally leak an unrelated numeric
      # field into the label.
      AMOUNT_ACTIONS = {
        "TillDeposit" => %w[create void],
        "CustodyTransaction" => %w[balance_top_up balance_expense_deduction balance_transfer
                                    balance_adjustment balance_inventory_purchase balance_inventory_purchase_reversal],
        "RemainingDepositBalance" => %w[create adjustment settle write_off dispute_reserved dispute_released]
      }.freeze

      I18N_SCOPE = "finance.dashboard.recent_activity".freeze

      # currency_formatter: a ->(BigDecimal) { "5,000 ج.م" } callable — the
      # caller (the view) injects its own `format_currency` helper so this
      # class never has to duplicate business-currency/locale formatting
      # logic or need view context of its own.
      def initialize(audit_log, currency_formatter: ->(amount) { amount.to_s })
        @log = audit_log
        @currency_formatter = currency_formatter
      end

      def label
        key = LABEL_KEYS.dig(@log.auditable_type, @log.action)
        return fallback_label if key.nil?

        amt = amount
        if amt
          I18n.t("#{I18N_SCOPE}.#{key}_with_amount", amount: @currency_formatter.call(amt),
                 default: I18n.t("#{I18N_SCOPE}.#{key}"))
        else
          I18n.t("#{I18N_SCOPE}.#{key}")
        end
      end

      private

      def amount
        return nil unless AMOUNT_ACTIONS[@log.auditable_type]&.include?(@log.action)

        raw = metadata_amount || changes_amount
        return nil if raw.nil?

        BigDecimal(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def metadata_amount
        @log.metadata.is_a?(Hash) ? @log.metadata["amount"] : nil
      end

      # CustodyTransaction logs its amount inside changes_json (an
      # [old, new] diff), e.g. { amount: [nil, txn.amount] } — not metadata.
      def changes_amount
        @log.diff[:amount]&.last
      end

      # Never renders the raw class/action name — logs the gap for
      # developers (per requirement 8) and shows a safe generic sentence.
      def fallback_label
        Rails.logger.warn(
          "[Finance::Dashboard::ActivityPresenter] Unmapped audit activity: " \
          "#{@log.auditable_type}##{@log.action} (audit_log id=#{@log.id})"
        )
        I18n.t("#{I18N_SCOPE}.generic_fallback")
      end
    end
  end
end
