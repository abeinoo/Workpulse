module Scheduling
  # The single write path of the business's Holiday Calendar (R6; attendance
  # plan revision 19, A10, D3). Every create, update and delete is audited with
  # the date and kind. Updates overwrite the row and deletes remove it, so their
  # audit entry is the only record of the old values: they use log_audit!
  # (fail-closed) and roll back when the entry cannot be written.
  #
  # The calendar is business-wide (D3). It changes no payroll by itself: a
  # finalized or paid period is never recalculated because a holiday changed.
  class HolidayCalendar
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    FIELDS = %i[date name kind].freeze

    def initialize(actor:)
      @actor = actor
    end

    def create(attributes)
      holiday = Holiday.new(attributes.to_h.symbolize_keys.slice(*FIELDS))
      holiday.business   = @actor.business
      holiday.created_by = @actor
      Holiday.transaction do
        holiday.save!
        log_audit(actor: @actor, auditable: holiday, action: "holiday.created", metadata: snapshot(holiday))
      end
      Result.new(ok: true, record: holiday)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Result.new(ok: false, record: holiday, error: :invalid)
    end

    def update(holiday_id, attributes)
      holiday = find(holiday_id)
      Holiday.transaction do
        holiday.lock!
        before = snapshot(holiday)
        holiday.assign_attributes(attributes.to_h.symbolize_keys.slice(*FIELDS))
        changes = holiday.changes.slice(*FIELDS.map(&:to_s))
        holiday.save!
        if changes.any?
          log_audit!(actor: @actor, auditable: holiday, action: "holiday.updated", changes: changes, metadata: before)
        end
      end
      Result.new(ok: true, record: holiday)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Result.new(ok: false, record: holiday, error: :invalid)
    rescue AuditLoggable::AuditWriteFailed
      Result.new(ok: false, record: holiday.reload, error: :audit_failed)
    end

    def destroy(holiday_id)
      holiday = find(holiday_id)
      Holiday.transaction do
        holiday.lock!
        log_audit!(actor: @actor, auditable: holiday, action: "holiday.deleted", metadata: snapshot(holiday))
        holiday.destroy!
      end
      Result.new(ok: true, record: holiday)
    rescue AuditLoggable::AuditWriteFailed
      Result.new(ok: false, record: holiday, error: :audit_failed)
    end

    private

    def find(holiday_id) = Holiday.where(business_id: @actor.business_id).find(holiday_id)

    def snapshot(holiday) = { date: holiday.date&.iso8601, name: holiday.name, kind: holiday.kind }
  end
end
