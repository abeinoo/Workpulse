require "rails_helper"
require "rake"

RSpec.describe "finance:backfill_session_amounts_corrections" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("finance:backfill_session_amounts_corrections") }

  let(:task) { Rake::Task["finance:backfill_session_amounts_corrections"] }

  before  { task.reenable }
  after   { %w[DRY_RUN BUSINESS_ID ACTOR_ID].each { |k| ENV.delete(k) } }

  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:cash_pm) do
    PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
  end
  let(:visa_pm) do
    PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
  end

  # Simulates a DR that already went through the pre-fix SessionAmountsEditor:
  # session_amounts holds the corrected value, the handover still holds stale.
  def build_affected_dr(cash_collected_on_handover: 370, cash_collected_on_snapshot: 470)
    dr = DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "closed",
      opened_at:     1.hour.ago,
      closed_at:     Time.current,
      business_date: Date.current
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id)

    handover = TillHandover.create!(
      daily_reconciliation:      dr,
      from_user:                 actor,
      self_deposit:              true,
      opening_float_declaration: false,
      fresha_date:               dr.business_date
    )
    TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm,
                                payment_method_name: cash_pm.name, collected_amount: cash_collected_on_handover,
                                refund_amount: 0, kind: "operational")
    TillHandoverAmount.create!(till_handover: handover, payment_method: visa_pm,
                                payment_method_name: visa_pm.name, collected_amount: 5_956,
                                refund_amount: 0, kind: "operational")

    dr.session_amounts.upsert_by_payment_method(cash_pm, collected_amount: cash_collected_on_snapshot, refund_amount: 0)
    dr.session_amounts.upsert_by_payment_method(visa_pm, collected_amount: 5_956, refund_amount: 0)

    AuditLog.create!(actor: actor, business: business, auditable: dr, action: "edit_session_totals",
                      changes_json: { "Cash" => { "collected" => [ cash_collected_on_handover.to_s, cash_collected_on_snapshot.to_s ] } },
                      metadata: { notes: "original correction" })

    [ dr, handover ]
  end

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end

  describe "identifying affected records" do
    it "only touches DRs with an edit_session_totals audit log" do
      _affected_dr, affected_handover = build_affected_dr

      other_branch = create(:branch, business: business)
      unaffected_dr = DailyReconciliation.create!(
        branch: other_branch, business: business, state: "closed",
        opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
      )
      TillSession.create!(daily_reconciliation: unaffected_dr, depositor_id: actor.id)
      unaffected_handover = TillHandover.create!(
        daily_reconciliation: unaffected_dr, from_user: actor, self_deposit: true,
        opening_float_declaration: false, fresha_date: unaffected_dr.business_date
      )
      TillHandoverAmount.create!(till_handover: unaffected_handover, payment_method: cash_pm,
                                  payment_method_name: cash_pm.name, collected_amount: 100,
                                  refund_amount: 0, kind: "operational")

      capture_stdout { task.invoke }

      expect(affected_handover.amounts.find_by(payment_method: cash_pm).reload.collected_amount).to eq(470)
      expect(unaffected_handover.amounts.find_by(payment_method: cash_pm).reload.collected_amount).to eq(100)
    end
  end

  describe "DRY_RUN" do
    it "reports the divergence without writing any changes" do
      _dr, handover = build_affected_dr

      ENV["DRY_RUN"] = "1"
      output = capture_stdout { task.invoke }

      expect(output).to include("WOULD UPDATE")
      expect(handover.amounts.find_by(payment_method: cash_pm).reload.collected_amount).to eq(370)
    end
  end

  describe "applying the fix" do
    it "resyncs the handover, session_amounts, and both live and persisted employee summaries" do
      dr, handover = build_affected_dr

      capture_stdout { task.invoke }

      expect(handover.amounts.find_by(payment_method: cash_pm).reload.collected_amount).to eq(470)
      expect(dr.session_amounts.find_by(payment_method: cash_pm).reload.collected_amount).to eq(470)

      live_summary = Finance::EmployeeReconciliationSummarizer.new(dr).summaries.first
      cash_row     = live_summary.amounts.find { |a| a.payment_method_id == cash_pm.id }
      expect(cash_row.collected_amount).to eq(470)

      persisted = dr.employee_reconciliation_summaries.find_by(user: actor)
      persisted_cash = persisted.amounts.find_by(payment_method: cash_pm)
      expect(persisted_cash.collected_amount).to eq(470)
    end

    it "writes an audit log for the correction" do
      dr, _handover = build_affected_dr

      capture_stdout { task.invoke }

      log = AuditLog.where(auditable: dr, action: "backfill_session_amounts_correction").sole
      expect(log.changes_json["Cash"]["collected"]).to eq(%w[370.0 470.0])
    end

    it "isolates a failure on one DR so the rest of the run still completes" do
      boom_dr, _boom_handover = build_affected_dr

      other_branch = create(:branch, business: business)
      ok_dr = DailyReconciliation.create!(
        branch: other_branch, business: business, state: "closed",
        opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
      )
      TillSession.create!(daily_reconciliation: ok_dr, depositor_id: actor.id)
      ok_handover = TillHandover.create!(
        daily_reconciliation: ok_dr, from_user: actor, self_deposit: true,
        opening_float_declaration: false, fresha_date: ok_dr.business_date
      )
      TillHandoverAmount.create!(till_handover: ok_handover, payment_method: cash_pm,
                                  payment_method_name: cash_pm.name, collected_amount: 370,
                                  refund_amount: 0, kind: "operational")
      ok_dr.session_amounts.upsert_by_payment_method(cash_pm, collected_amount: 470, refund_amount: 0)
      AuditLog.create!(actor: actor, business: business, auditable: ok_dr, action: "edit_session_totals",
                        changes_json: {}, metadata: {})

      allow(Finance::TillHandoverCreator).to receive(:sync_session_amounts!).and_wrap_original do |original, dr, ho|
        raise "boom" if dr.id == boom_dr.id

        original.call(dr, ho)
      end

      output = capture_stdout { task.invoke }

      expect(output).to include("DR ##{boom_dr.id}: FAILED — RuntimeError: boom")
      expect(output).to include("Failed: 1")

      # The failed DR's transaction rolled back — untouched, not falsely marked updated.
      expect(boom_dr.day_close_handover.amounts.find_by(payment_method: cash_pm).reload.collected_amount).to eq(370)
      expect(AuditLog.where(auditable: boom_dr, action: "backfill_session_amounts_correction")).to be_empty

      # The other DR still went through.
      expect(ok_handover.amounts.find_by(payment_method: cash_pm).reload.collected_amount).to eq(470)
    end

    it "is idempotent — a second run makes no further changes" do
      dr, handover = build_affected_dr

      capture_stdout { task.invoke }
      task.reenable

      expect {
        capture_stdout { task.invoke }
      }.not_to change(AuditLog.where(action: "backfill_session_amounts_correction"), :count)

      expect(handover.amounts.find_by(payment_method: cash_pm).reload.collected_amount).to eq(470)
    end

    it "leaves a DR untouched if the handover already matches session_amounts" do
      dr, handover = build_affected_dr(cash_collected_on_handover: 470, cash_collected_on_snapshot: 470)

      output = capture_stdout { task.invoke }

      expect(output).to include("already matches session_amounts")
      expect(handover.amounts.find_by(payment_method: cash_pm).reload.collected_amount).to eq(470)
      expect(AuditLog.where(auditable: dr, action: "backfill_session_amounts_correction")).to be_empty
    end

    it "skips a DR with no day-close handover" do
      dr, handover = build_affected_dr
      handover.destroy!

      output = capture_stdout { task.invoke }

      expect(output).to include("no day-close handover found")
    end
  end

  describe "manual review flag" do
    it "flags a DR whose Session Totals correction was later overwritten by a Day Close Amounts edit" do
      dr, handover = build_affected_dr(cash_collected_on_handover: 470, cash_collected_on_snapshot: 470)

      AuditLog.create!(actor: actor, business: business, auditable: handover, action: "edit_day_close_amounts",
                        changes_json: { "Cash" => { "collected" => %w[370 470] } },
                        metadata: { reason: "later day close edit" },
                        created_at: 1.minute.from_now)

      output = capture_stdout { task.invoke }

      expect(output).to include("MANUAL REVIEW NEEDED (1)")
      expect(output).to include("DR ##{dr.id}")
    end

    it "does not flag a DR with no later Day Close Amounts edit" do
      _dr, _handover = build_affected_dr

      output = capture_stdout { task.invoke }

      expect(output).not_to include("MANUAL REVIEW NEEDED")
    end
  end

  describe "BUSINESS_ID scoping" do
    it "restricts the backfill to the given business" do
      _dr, handover = build_affected_dr

      other_business = create(:business)
      ENV["BUSINESS_ID"] = other_business.id.to_s

      capture_stdout { task.invoke }

      expect(handover.amounts.find_by(payment_method: cash_pm).reload.collected_amount).to eq(370)
    end
  end
end
