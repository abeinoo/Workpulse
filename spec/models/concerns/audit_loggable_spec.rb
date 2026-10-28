require "rails_helper"

# BUG-003: an audit write runs in its own savepoint. A database error on the
# audit insert rolls back only that insert (fail-open: the caller's
# transaction continues and commits), is logged and reported once, and never
# leaves PostgreSQL's transaction aborted — where a later COMMIT would roll the
# primary operation back while the caller reports success. A lost connection
# or an already-aborted caller transaction is re-raised, not reported as an
# audit failure.
#
# Every example runs inside the transactional fixture (the caller's
# transaction blocks below are savepoints), so nothing is committed.
RSpec.describe AuditLoggable do
  let(:host)      { Class.new { include AuditLoggable }.new }
  let(:business)  { create(:business) }
  let!(:actor)    { create(:user, business: business) }
  let!(:auditable) { create(:user, business: business, first_name: "Original", last_name: "Name") }

  # A real PostgreSQL failure, not a stub: a loaded user whose row does not
  # exist, so the audit INSERT violates audit_logs.actor_id's foreign key.
  let(:ghost_actor) { User.instantiate("id" => -1, "business_id" => business.id) }

  let(:reports) { [] }
  let(:subscriber) do
    collected = reports
    Class.new do
      define_method(:report) do |error, handled:, severity:, context:, source:|
        collected << { error: error, handled: handled, severity: severity, context: context, source: source }
      end
    end.new
  end

  around do |example|
    Rails.error.subscribe(subscriber)
    example.run
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  def audit(by: actor, record: auditable, metadata: { note: "SECRET-NOTE" })
    host.log_audit(actor: by, auditable: record, action: "test_action",
                   changes: { amount: [ "100.0", "250.0" ] }, metadata: metadata)
  end

  def audit!(by: actor, record: auditable)
    host.log_audit!(actor: by, auditable: record, action: "test_action", metadata: { note: "SECRET-NOTE" })
  end

  def audit_rows = AuditLog.where(auditable: auditable)

  describe "a successful write" do
    it "returns the persisted AuditLog, as before" do
      result = audit
      expect(result).to be_a(AuditLog).and be_persisted
      expect(result).to have_attributes(actor_id: actor.id, business_id: business.id, action: "test_action")
      expect(reports).to be_empty
    end

    it "log_audit! returns it too" do
      expect(audit!).to be_a(AuditLog).and be_persisted
    end
  end

  describe "an audit-only database failure (real foreign-key violation)" do
    it "inside a caller transaction: rolls back only the audit insert; later SQL in the same transaction succeeds" do
      result = :unset

      ActiveRecord::Base.transaction do
        auditable.update!(first_name: "Before")
        result = audit(by: ghost_actor)
        auditable.update!(last_name: "After")
        expect(ActiveRecord::Base.connection.select_value("SELECT 1")).to eq(1)
      end

      expect(result).to be_nil
      expect(auditable.reload).to have_attributes(first_name: "Before", last_name: "After")
      expect(audit_rows).to be_empty
    end

    it "as the final statement of the caller's transaction: the transaction still completes" do
      ActiveRecord::Base.transaction do
        auditable.update!(first_name: "Committed")
        audit(by: ghost_actor)
      end

      expect(auditable.reload.first_name).to eq("Committed")
      expect(audit_rows).to be_empty
    end

    it "outside a caller transaction: returns nil and the connection stays usable" do
      expect(audit(by: ghost_actor)).to be_nil
      expect(auditable.update!(first_name: "Later")).to be(true)
      expect(audit).to be_persisted
    end

    it "a later audit entry in the same transaction is still written" do
      ActiveRecord::Base.transaction do
        audit(by: ghost_actor)
        audit
      end

      expect(audit_rows.count).to eq(1)
    end

    it "is reported exactly once, with ids and keys but no values" do
      logged = []
      allow(Rails.logger).to receive(:error) { |message| logged << message }

      audit(by: ghost_actor)

      expect(reports.size).to eq(1)
      report = reports.first
      expect(report[:error]).to be_a(ActiveRecord::InvalidForeignKey)
      expect(report).to include(handled: true, severity: :error, source: "audit_log.work_pulse")
      expect(report[:context]).to include(
        action: "test_action", auditable_type: "User", auditable_id: auditable.id, actor_id: -1,
        business_id: business.id, change_keys: [ "amount" ], metadata_keys: [ "note" ],
        error_class: "ActiveRecord::InvalidForeignKey", sqlstate: "23503", table: "audit_logs"
      )
      expect(report[:context][:constraint]).to be_present

      audit_lines = logged.grep(/\[AuditLog\] Failed to write audit entry/)
      expect(audit_lines.size).to eq(1)
      expect(audit_lines.first).to include("\"action\":\"test_action\"", "\"auditable_id\":#{auditable.id}",
                                           "\"sqlstate\":\"23503\"")
      # Neither change/metadata values nor PostgreSQL's DETAIL line
      # ("Key (actor_id)=(-1) is not present …") reach the log or the context.
      [ logged.join, report[:context].to_s ].each do |text|
        expect(text).not_to include("SECRET-NOTE", "250.0", "Key (", "is not present")
      end
    end

    it "a validation failure before any SQL stays fail-open and is reported once, naming the invalid attributes" do
      expect(audit(record: nil)).to be_nil
      expect(reports.size).to eq(1)
      expect(reports.first[:error]).to be_a(ActiveRecord::RecordInvalid)
      expect(reports.first[:context][:invalid_attributes]).to include("auditable_type", "auditable_id")
    end

    it "a reporting failure does not conceal or replace the audit failure" do
      allow(Rails.error).to receive(:report).and_raise(RuntimeError, "reporter down")

      expect(audit(by: ghost_actor)).to be_nil
      expect { host.log_audit!(actor: ghost_actor, auditable: auditable, action: "test_action") }
        .to raise_error(AuditLoggable::AuditWriteFailed) { |e| expect(e.cause).to be_a(ActiveRecord::InvalidForeignKey) }
    end
  end

  describe "log_audit! (fail-closed variant)" do
    it "raises AuditWriteFailed with the original error as its cause, after a single report" do
      expect { audit!(by: ghost_actor) }.to raise_error(AuditLoggable::AuditWriteFailed) { |error|
        expect(error).to be_a(ActiveRecord::ActiveRecordError)
        expect(error.cause).to be_a(ActiveRecord::InvalidForeignKey)
      }
      expect(reports.size).to eq(1)
    end

    it "leaves the caller's transaction usable, so the caller decides whether to roll back" do
      ActiveRecord::Base.transaction do
        expect { audit!(by: ghost_actor) }.to raise_error(AuditLoggable::AuditWriteFailed)
        auditable.update!(first_name: "Still usable")
      end

      expect(auditable.reload.first_name).to eq("Still usable")
    end

    it "rolls the caller's transaction back when the error propagates" do
      expect {
        ActiveRecord::Base.transaction do
          auditable.update!(first_name: "Rolled back")
          audit!(by: ghost_actor)
        end
      }.to raise_error(AuditLoggable::AuditWriteFailed)

      expect(auditable.reload.first_name).to eq("Original")
    end
  end

  describe "failures that are not audit-only are re-raised, never reported as one" do
    [ ActiveRecord::ConnectionFailed, ActiveRecord::ConnectionNotEstablished, ActiveRecord::AdapterTimeout ].each do |error_class|
      it "a lost or unresponsive connection (#{error_class.name.demodulize})" do
        allow(AuditLog).to receive(:create!).and_raise(error_class, "connection lost")

        expect { audit }.to raise_error(error_class)
        expect { audit! }.to raise_error(error_class)
        expect(reports).to be_empty
      end
    end

    it "a caller transaction already aborted before the audit write (real PostgreSQL abort)" do
      ActiveRecord::Base.transaction do
        expect { ActiveRecord::Base.connection.execute("SELECT 1 / 0") }.to raise_error(ActiveRecord::StatementInvalid)

        expect { audit }.to raise_error(ActiveRecord::StatementInvalid) { |e|
          expect(e.cause).to be_a(PG::InFailedSqlTransaction)
        }
        expect { audit! }.to raise_error(ActiveRecord::StatementInvalid) { |e|
          expect(e).not_to be_a(AuditLoggable::AuditWriteFailed)
        }

        raise ActiveRecord::Rollback
      end

      expect(reports).to be_empty
      expect(ActiveRecord::Base.connection.select_value("SELECT 1")).to eq(1)
    end

    # Defence in depth: an error is audit-only only if the caller's
    # transaction is still usable afterwards. Simulated by taking the audit
    # write out of its savepoint, so the real foreign-key violation aborts the
    # caller's transaction as it did before BUG-003 was fixed.
    it "an audit failure that leaves the caller's transaction unusable" do
      allow(AuditLog).to receive(:transaction).and_yield

      ActiveRecord::Base.transaction do
        expect { audit(by: ghost_actor) }.to raise_error(ActiveRecord::InvalidForeignKey)
        expect { audit!(by: ghost_actor) }.to raise_error(ActiveRecord::StatementInvalid) { |e|
          expect(e).not_to be_a(AuditLoggable::AuditWriteFailed)
        }

        raise ActiveRecord::Rollback
      end

      expect(reports).to be_empty
      expect(ActiveRecord::Base.connection.select_value("SELECT 1")).to eq(1)
    end
  end
end
