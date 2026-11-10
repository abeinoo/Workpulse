require "rails_helper"

# R3.1 durable audit record (plan §8, §18.2 G10, §19.13).
RSpec.describe PendingAuditEvent do
  let(:event) { create(:pending_audit_event) }
  let(:now)   { Time.zone.local(2026, 11, 8, 12, 0, 0) }

  def audit_log_for(event)
    AuditLog.create!(actor_id: event.actor_id, business_id: event.business_id, auditable_type: event.auditable_type,
                     auditable_id: event.auditable_id, action: event.action)
  end

  describe "retry schedule" do
    it "waits 1, 5 and 15 minutes before the first three retries, then an hour" do
      expect((1..5).map { |n| described_class.retry_delay(n) })
        .to eq([ 1.minute, 5.minutes, 15.minutes, 1.hour, 1.hour ])
    end
  end

  describe "#record_failure!" do
    it "counts the failure, keeps the error class and schema details, and schedules the next retry" do
      event.record_failure!(error_class: "ActiveRecord::InvalidForeignKey",
                            error_details: { "sqlstate" => "23503" }, at: now)

      expect(event.reload).to have_attributes(
        attempts: 1, consecutive_failures: 1, last_error: "ActiveRecord::InvalidForeignKey",
        last_error_details: { "sqlstate" => "23503" }, last_attempt_at: now, next_attempt_at: now + 5.minutes,
        escalated_at: nil, resolved_at: nil
      )
    end

    it "claims the event for the job enqueued for its next retry (T-R31-13)" do
      event.record_failure!(error_class: "E", error_details: {}, at: now)

      expect(event.reload.dispatch_claimed_until).to eq(now + 5.minutes + PendingAuditEvent::DISPATCH_GRACE)
    end

    it "escalates exactly at the third consecutive failure, once, and keeps retrying hourly" do
      times = [ now, now + 5.minutes, now + 20.minutes, now + 80.minutes ]
      escalations = times.map do |at|
        event.record_failure!(error_class: "E", error_details: {}, at: at)
        event.reload.escalated_at
      end

      expect(escalations).to eq([ nil, nil, times[2], times[2] ])
      expect(event).to have_attributes(attempts: 4, consecutive_failures: 4, next_attempt_at: times[3] + 1.hour)
    end
  end

  describe "#mark_delivered!" do
    it "resolves with the AuditLog, clears the schedule and resets the failure streak" do
      event.record_failure!(error_class: "E", error_details: {}, at: now)
      log = audit_log_for(event)
      event.mark_delivered!(log, at: now + 5.minutes)

      expect(event.reload).to have_attributes(resolved_at: now + 5.minutes, audit_log_id: log.id, next_attempt_at: nil,
                                              dispatch_claimed_until: nil, attempts: 2, consecutive_failures: 0,
                                              status: :resolved)
    end

    it "writes the entry's receipt with the AuditLog (T-R31-11)" do
      log = audit_log_for(event)
      event.mark_delivered!(log, at: now)

      expect(DurableAuditReceipt.sole).to have_attributes(entry_key: event.entry_key, audit_log_id: log.id)
    end
  end

  describe "#adopt_receipt!" do
    it "resolves to the AuditLog already receipted under its entry key, writing nothing" do
      log     = audit_log_for(event)
      receipt = DurableAuditReceipt.create!(entry_key: event.entry_key, audit_log: log)

      expect { event.adopt_receipt!(receipt, at: now) }.not_to change(AuditLog, :count)
      expect(event.reload).to have_attributes(resolved_at: now, audit_log_id: log.id, attempts: 1)
      expect(DurableAuditReceipt.count).to eq(1)
    end

    it "refuses any later change to a resolved event" do
      event.mark_delivered!(audit_log_for(event), at: now)

      expect { event.update!(last_error: "X") }.to raise_error(ActiveRecord::RecordInvalid, /resolved audit event/)
    end
  end

  describe "immutability and retention" do
    it "never changes its identity, payload or attempt time" do
      expect { event.update(payload: {}) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { event.update(attempted_at: now) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { event.update(business_id: create(:business).id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    end

    it "is never deleted" do
      event
      expect { event.destroy }.to raise_error(PendingAuditEvent::DeletionNotAllowedError)
      expect { event.destroy! }.to raise_error(PendingAuditEvent::DeletionNotAllowedError)
      expect { event.delete }.to raise_error(PendingAuditEvent::DeletionNotAllowedError)
      expect(described_class.exists?(event.id)).to be(true)
    end
  end

  describe "database constraints" do
    it "sets resolved_at and audit_log_id together" do
      expect { event.update_columns(resolved_at: now) }.to raise_error(ActiveRecord::StatementInvalid, /resolution_complete/)
    end

    it "keeps every unresolved event scheduled" do
      expect { event.update_columns(next_attempt_at: nil) }.to raise_error(ActiveRecord::StatementInvalid, /unresolved_scheduled/)
    end

    it "requires a real business and actor" do
      expect { create(:pending_audit_event, business_id: -1) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "scopes" do
    it "selects due, escalated and resolved events" do
      due        = create(:pending_audit_event, next_attempt_at: now - 1.minute)
      later      = create(:pending_audit_event, next_attempt_at: now + 1.minute)
      escalated  = create(:pending_audit_event, next_attempt_at: now + 1.hour, escalated_at: now)
      resolved   = create(:pending_audit_event)
      resolved.mark_delivered!(audit_log_for(resolved), at: now)

      expect(described_class.due(now)).to contain_exactly(due)
      expect(described_class.escalated_unresolved).to contain_exactly(escalated)
      expect(described_class.resolved).to contain_exactly(resolved)
      expect(described_class.unresolved).to contain_exactly(due, later, escalated)
    end

    it "offers the sweeper only due events whose dispatch claim has lapsed" do
      unclaimed = create(:pending_audit_event, next_attempt_at: now - 1.minute)
      lapsed    = create(:pending_audit_event, next_attempt_at: now - 1.minute, dispatch_claimed_until: now - 1.second)
      _claimed  = create(:pending_audit_event, next_attempt_at: now - 1.minute, dispatch_claimed_until: now + 1.minute)
      _not_due  = create(:pending_audit_event, next_attempt_at: now + 1.minute)

      expect(described_class.dispatchable(now)).to contain_exactly(unclaimed, lapsed)
    end

    it "loads operational columns only, never the payload" do
      event
      loaded = described_class.operational.find(event.id)
      expect(loaded.has_attribute?(:payload)).to be(false)
      expect(loaded.attributes.keys).to match_array(PendingAuditEvent::OPERATIONAL_COLUMNS)
    end
  end
end
