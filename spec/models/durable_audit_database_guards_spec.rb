require "rails_helper"

# R3.1 database-level protection of the durable audit record (T-R31-14). Every
# example bypasses the models — update_all / update_columns / delete_all, or
# raw inserts — so only PostgreSQL's triggers and constraints are tested. Each
# refused statement runs in its own savepoint, so the test transaction stays
# usable.
RSpec.describe "Durable audit database guards" do
  let(:now)   { Time.zone.local(2026, 11, 8, 12, 0, 0) }
  let(:event) { create(:pending_audit_event) }

  def refused(pattern = /restrict|append-only|never|violates/)
    expect { ActiveRecord::Base.transaction(requires_new: true) { yield } }
      .to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def deliver(event)
    log = AuditLog.create!(actor_id: event.actor_id, business_id: event.business_id, auditable_type: event.auditable_type,
                           auditable_id: event.auditable_id, action: event.action)
    event.mark_delivered!(log, at: now)
    log
  end

  def events = PendingAuditEvent.where(id: event.id)

  describe "pending_audit_events" do
    it "never changes identity or payload, even through update_all" do
      other    = create(:user, business: create(:business))
      original = event.reload.attributes

      refused(/identity and payload never change/) { events.update_all(payload: {}) }
      refused(/identity and payload never change/) { events.update_all(actor_id: other.id) }
      refused(/identity and payload never change/) { events.update_all(business_id: other.business_id) }
      refused(/identity and payload never change/) { events.update_all(action: "other") }
      refused(/identity and payload never change/) { events.update_all(attempted_at: now) }
      refused(/identity and payload never change/) { events.update_all(entry_key: SecureRandom.uuid) }
      expect(event.reload.attributes).to eq(original)
    end

    it "is never deleted, even through delete_all" do
      event
      refused(/never deleted/) { events.delete_all }
      refused(/never deleted/) { ActiveRecord::Base.connection.execute("DELETE FROM pending_audit_events") }
      expect(PendingAuditEvent.exists?(event.id)).to be(true)
    end

    it "never changes once resolved, not even its schedule" do
      deliver(event)

      refused(/resolved pending audit event never changes/) { event.update_columns(escalated_at: now) }
      refused(/resolved pending audit event never changes/) { events.update_all(next_attempt_at: now) }
      refused(/never deleted/) { events.delete_all }
      expect(event.reload).to be_resolved
    end

    it "sets escalation once and never lowers the attempt count" do
      event.update_columns(attempts: 3, consecutive_failures: 3, escalated_at: now)

      refused(/escalation is set once/) { events.update_all(escalated_at: nil) }
      refused(/escalation is set once/) { events.update_all(escalated_at: now + 1.hour) }
      refused(/attempts never decrease/) { events.update_all(attempts: 2, consecutive_failures: 0) }
    end

    it "resolves only to the AuditLog receipted under its own entry key" do
      event
      foreign_log = AuditLog.create!(actor_id: event.actor_id, business_id: event.business_id,
                                     auditable_type: "User", auditable_id: event.auditable_id, action: "other_entry")
      DurableAuditReceipt.create!(entry_key: SecureRandom.uuid, audit_log: foreign_log)

      refused(/fk_pending_audit_events_resolved_by_own_receipt/) do
        events.update_all(resolved_at: now, audit_log_id: foreign_log.id, next_attempt_at: nil)
      end
    end

    it "still allows every legitimate update: failures, escalation, dispatch claims and resolution" do
      3.times { |n| event.record_failure!(error_class: "E", error_details: {}, at: now + n.minutes) }
      events.update_all(dispatch_claimed_until: now + 1.hour)
      deliver(event)

      expect(event.reload).to have_attributes(attempts: 4, escalated_at: now + 2.minutes, status: :resolved)
    end
  end

  describe "pending_audit_event_attempts" do
    def attempt_for(event, business_id: event.business_id)
      PendingAuditEventAttempt.new(pending_audit_event_id: event.id, business_id: business_id, kind: "automatic",
                                   started_at: now, finished_at: now, result: "failed")
    end

    it "is append-only, even through update_all and delete_all" do
      attempt_for(event).save!

      refused(/append-only/) { PendingAuditEventAttempt.update_all(result: "delivered") }
      refused(/append-only/) { PendingAuditEventAttempt.delete_all }
      expect(PendingAuditEventAttempt.sole.result).to eq("failed")
    end

    it "belongs to its event's business" do
      foreign_business = create(:business)

      refused(/fk_pending_audit_event_attempts_same_business|violates foreign key/) do
        attempt_for(event, business_id: foreign_business.id).save!(validate: false)
      end
    end
  end

  describe "durable_audit_receipts" do
    it "is append-only and keeps one receipt per entry key and per AuditLog" do
      log = deliver(event)
      receipt = DurableAuditReceipt.sole

      refused(/append-only/) { DurableAuditReceipt.update_all(entry_key: SecureRandom.uuid) }
      refused(/append-only/) { DurableAuditReceipt.delete_all }
      expect { ActiveRecord::Base.transaction(requires_new: true) { DurableAuditReceipt.create!(entry_key: receipt.entry_key, audit_log: create_log_like(log)) } }
        .to raise_error(ActiveRecord::RecordNotUnique)
      expect { ActiveRecord::Base.transaction(requires_new: true) { DurableAuditReceipt.create!(entry_key: SecureRandom.uuid, audit_log: log) } }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    def create_log_like(log)
      AuditLog.create!(log.attributes.slice("actor_id", "business_id", "auditable_type", "auditable_id", "action"))
    end

    it "is protected in the model too" do
      deliver(event)
      receipt = DurableAuditReceipt.sole

      expect { receipt.update!(entry_key: SecureRandom.uuid) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { receipt.destroy }.to raise_error(DurableAuditReceipt::DeletionNotAllowedError)
    end
  end

  it "keeps the guard functions and triggers in db/schema.rb, so a schema load recreates them" do
    schema = Rails.root.join("db/schema.rb").read

    %w[durable_audit_receipts_append_only pending_audit_event_attempts_append_only pending_audit_events_guard
       FUNCTION\ public.audit_append_only_guard FUNCTION\ public.pending_audit_events_guard].each do |name|
      expect(schema).to include(name)
    end
    expect(ActiveRecord::Base.connection.select_values("SELECT tgname FROM pg_trigger WHERE NOT tgisinternal"))
      .to contain_exactly("durable_audit_receipts_append_only", "pending_audit_event_attempts_append_only",
                          "pending_audit_events_guard")
  end
end
