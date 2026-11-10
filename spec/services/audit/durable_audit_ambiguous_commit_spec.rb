require "rails_helper"

# R3.1 exactly-once across a commit whose confirmation is lost (T-R31-11,
# T-R31-12). PostgreSQL commits, then the connection fails before the
# application hears back: Rails raises ActiveRecord::ConnectionFailed although
# the data is durable. Simulated by letting the real COMMIT run and raising
# afterwards — so these examples need real commits (non-transactional).
RSpec.describe "Durable audit across a lost commit confirmation" do
  include ActiveJob::TestHelper
  include_context "non-transactional database"

  let(:business)     { create(:business) }
  let(:actor)        { create(:user, business: business) }
  let(:auditable)    { create(:user, business: business) }
  let(:attempted_at) { Time.zone.local(2026, 11, 8, 9, 0, 0) }

  # The next COMMIT on this thread's connection succeeds in PostgreSQL, then
  # raises as if the connection had dropped before the reply.
  def lose_next_commit_confirmation
    connection = ActiveRecord::Base.lease_connection
    armed = true
    allow(connection).to receive(:commit_db_transaction).and_wrap_original do |original, *args|
      original.call(*args)
      if armed
        armed = false
        raise ActiveRecord::ConnectionFailed, "server closed the connection unexpectedly"
      end
    end
  end

  def record_entry
    travel_to(attempted_at) do
      Audit::DurableEntry.record(actor: actor, auditable: auditable, action: :daily_paid_attendance_rejected,
                                 metadata: { "reason" => "conflict" })
    end
  end

  describe "the first write" do
    it "keeps the entry pending under its key, and delivery adopts the committed AuditLog: one AuditLog in total" do
      [ actor, auditable ].each(&:reload)
      lose_next_commit_confirmation

      result = record_entry

      expect(result).to be_pending
      first_write = AuditLog.sole
      expect(DurableAuditReceipt.sole).to have_attributes(entry_key: result.record.entry_key, audit_log_id: first_write.id)

      delivery = travel_to(attempted_at + 1.minute) { Audit::PendingEventDelivery.call(event_id: result.record.id) }

      expect(delivery.outcome).to eq(:delivered)
      expect(AuditLog.count).to eq(1)
      expect(result.record.reload).to have_attributes(status: :resolved, audit_log_id: first_write.id)
      expect(result.record.attempt_records.pluck(:result)).to eq(%w[delivered])
    end

    it "when the commit really failed, delivery writes the entry once" do
      [ actor, auditable ].each(&:reload)
      connection = ActiveRecord::Base.lease_connection
      armed = true
      allow(connection).to receive(:commit_db_transaction).and_wrap_original do |original, *args|
        if armed
          armed = false
          connection.rollback_db_transaction
          raise ActiveRecord::ConnectionFailed, "server closed the connection unexpectedly"
        end
        original.call(*args)
      end

      result = record_entry
      expect(result).to be_pending
      expect(AuditLog.count).to eq(0)

      travel_to(attempted_at + 1.minute) { Audit::PendingEventDelivery.call(event_id: result.record.id) }

      expect(AuditLog.sole.created_at).to eq(attempted_at)
      expect(DurableAuditReceipt.sole.audit_log_id).to eq(AuditLog.sole.id)
    end
  end

  describe "a delivery" do
    let!(:event) do
      create(:pending_audit_event, actor: actor, auditable_id: auditable.id, attempted_at: attempted_at)
    end

    def deliver(at: attempted_at + 1.minute)
      travel_to(at) { Audit::PendingEventDelivery.call(event_id: event.id) }
    end

    it "that committed is reported as delivered, not failed, with one attempt row and no counted failure" do
      lose_next_commit_confirmation

      result = deliver

      expect(result.outcome).to eq(:delivered)
      expect(result.audit_log).to eq(AuditLog.sole)
      expect(event.reload).to have_attributes(status: :resolved, attempts: 1, consecutive_failures: 0)
      expect(event.attempt_records.pluck(:result)).to eq(%w[delivered])
      expect(deliver(at: attempted_at + 2.hours).outcome).to eq(:already_resolved)
      expect(AuditLog.count).to eq(1)
    end

    it "whose failure committed is counted once, not twice" do
      fail_audit_writes!
      lose_next_commit_confirmation

      result = deliver

      expect(result.outcome).to eq(:failed)
      expect(event.reload).to have_attributes(attempts: 1, consecutive_failures: 1,
                                              next_attempt_at: attempted_at + 6.minutes)
      expect(event.attempt_records.pluck(:result)).to eq(%w[failed])
    end
  end
end
