# BUG-003: makes AuditLog inserts fail in PostgreSQL itself, not in a stub that
# raises before any SQL. The row is inserted with an actor_id that has no users
# row, so audit_logs.actor_id's foreign key rejects it — a real database error
# inside the audit savepoint, exactly what a production audit failure does to
# the caller's transaction.
#
#   fail_audit_writes!                       # every audit insert fails
#   fail_audit_writes!(:manual_unmatch, …)   # only entries with these actions
#   fail_audit_writes!(:x, skip: 1)          # the first matching entry is written
module AuditFailureHelpers
  def fail_audit_writes!(*actions, skip: 0)
    actions = actions.map(&:to_s)
    seen    = 0
    allow(AuditLog).to receive(:create!).and_wrap_original do |original, *args, **kwargs, &block|
      attrs = (args.first || kwargs).to_h.symbolize_keys
      matches = actions.empty? || actions.include?(attrs[:action].to_s)
      seen += 1 if matches
      if matches && seen > skip
        AuditLog.new(attrs.except(:actor).merge(actor_id: -1)).save!(validate: false)
      else
        original.call(*args, **kwargs, &block)
      end
    end
  end
end

RSpec.configure { |config| config.include AuditFailureHelpers }
