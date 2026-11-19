module OrganizationAccess
  # Switches ONE business between the legacy warehouse access rule (a non-owner
  # with no warehouse assignment reaches every warehouse) and fail-closed
  # resolution through OrganizationAccess::WarehouseAccessProvider — see
  # User#inventory_warehouse_ids and Business#warehouse_access_fail_closed?.
  #
  # The only writer of the setting. Owner-only (WarehouseAccessModePolicy). The
  # business row is locked, only the one settings key changes, and the audit
  # entry is fail-closed (log_audit!) in the same transaction: if it cannot be
  # written the mode stays as it was. No other business is touched.
  #
  # Operator use (console; review `bin/rails inventory:warehouse_access_report
  # BUSINESS_IDS=<id>` and settle every affected user first):
  #
  #   OrganizationAccess::WarehouseAccessMode.call(
  #     business: Business.find(<id>), actor: Business.find(<id>).owner,
  #     fail_closed: true, reason: "<why>")
  #
  # Rollback is the same call with fail_closed: false.
  class WarehouseAccessMode
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def self.call(business:, actor:, fail_closed:, reason: nil)
      new(business: business, actor: actor, fail_closed: fail_closed, reason: reason).call
    end

    def initialize(business:, actor:, fail_closed:, reason: nil)
      @business_id = business.respond_to?(:id) ? business.id : business
      @actor       = actor
      @fail_closed = fail_closed
      @reason      = reason.to_s.strip.presence
    end

    def call
      return failure(:invalid_mode) unless [ true, false ].include?(@fail_closed)
      return failure(:not_authorized) if @actor.nil?

      ActiveRecord::Base.transaction do
        business = Business.lock.find_by(id: @business_id)
        return failure(:not_authorized) unless business && WarehouseAccessModePolicy.new(@actor, business).update?

        previous = business.warehouse_access_fail_closed?
        return failure(:unchanged, business) if previous == @fail_closed

        business.assign_warehouse_access_mode(@fail_closed)
        business.save!
        log_audit!(actor: @actor, auditable: business, action: "warehouse_access_mode",
                   changes: { setting_key => [ previous, @fail_closed ] },
                   metadata: { previous_mode: mode_name(previous), new_mode: mode_name(@fail_closed),
                               reason: @reason }.compact)
        Result.new(ok: true, record: business)
      end
    rescue ActiveRecord::RecordInvalid, AuditLoggable::AuditWriteFailed => e
      failure(:failed, e.try(:record))
    end

    private

    def setting_key = Business::WAREHOUSE_ACCESS_FAIL_CLOSED_SETTING

    def mode_name(fail_closed) = fail_closed ? "fail_closed" : "legacy"

    def failure(error, record = nil) = Result.new(ok: false, record: record, error: error)
  end
end
