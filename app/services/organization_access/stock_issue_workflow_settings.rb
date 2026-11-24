module OrganizationAccess
  # The only writer of the Stock Issue workflow settings of ONE business
  # (Business#stock_issue_self_approval, Business#quick_issue_enabled?) —
  # independent per workflow:
  #
  #   self_approval        Standard Stock Issue: "forbidden" | "allowed"
  #   quick_issue_enabled  Quick Issue for employees: true | false
  #
  # Owner-only (no delegation has been approved). The business row is locked,
  # only these keys change, and the audit entry is fail-closed (log_audit!)
  # in the same transaction, with the values before and after: if it cannot
  # be written, nothing changes. Stock-integrity rules (approval before
  # posting, locks, availability, audit) are not settings and cannot be
  # changed here.
  class StockIssueWorkflowSettings
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def self.call(business:, actor:, self_approval:, quick_issue_enabled:)
      new(business: business, actor: actor, self_approval: self_approval, quick_issue_enabled: quick_issue_enabled).call
    end

    def self.permitted?(actor, business) = actor.present? && business.present? && actor.owner? && actor.business_id == business.id

    def initialize(business:, actor:, self_approval:, quick_issue_enabled:)
      @business_id         = business.respond_to?(:id) ? business.id : business
      @actor               = actor
      @self_approval       = self_approval.to_s
      # Only an explicit true / false (or the form's "1" / "0") — never a
      # truthy guess for an unknown value.
      @quick_issue_enabled = { true => true, false => false, "1" => true, "0" => false,
                               "true" => true, "false" => false }.fetch(quick_issue_enabled, nil)
    end

    def call
      return failure(:invalid) unless Business::STOCK_ISSUE_SELF_APPROVAL_VALUES.include?(@self_approval)
      return failure(:invalid) unless [ true, false ].include?(@quick_issue_enabled)
      return failure(:not_authorized) if @actor.nil?

      ActiveRecord::Base.transaction do
        business = Business.lock.find_by(id: @business_id)
        return failure(:not_authorized) unless self.class.permitted?(@actor, business)

        before = snapshot(business)
        after  = { "self_approval" => @self_approval, "quick_issue_enabled" => @quick_issue_enabled }
        return failure(:unchanged, business) if before == after

        business.assign_stock_issue_workflow_settings(self_approval: @self_approval,
                                                      quick_issue_enabled: @quick_issue_enabled)
        business.save!
        log_audit!(actor: @actor, auditable: business, action: "stock_issue_workflow_settings",
                   changes: after.each_with_object({}) { |(key, value), h| h[key] = [ before[key], value ] if before[key] != value },
                   metadata: { workflows: { standard_stock_issue: { self_approval: @self_approval },
                                            quick_issue: { enabled: @quick_issue_enabled } } })
        Result.new(ok: true, record: business)
      end
    rescue ActiveRecord::RecordInvalid, AuditLoggable::AuditWriteFailed => e
      failure(:failed, e.try(:record))
    end

    private

    def snapshot(business)
      { "self_approval" => business.stock_issue_self_approval, "quick_issue_enabled" => business.quick_issue_enabled? }
    end

    def failure(error, record = nil) = Result.new(ok: false, record: record, error: error)
  end
end
