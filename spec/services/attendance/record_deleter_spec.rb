require "rails_helper"

RSpec.describe Attendance::RecordDeleter do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:manager)  { create(:user, :branch_manager, business: business) }
  let!(:record) do
    create(:attendance_record, :checked_out,
           user:         employee,
           branch:       branch,
           work_date:    Date.new(2026, 7, 10),
           check_in_at:  Time.zone.local(2026, 7, 10, 9, 30),
           check_out_at: Time.zone.local(2026, 7, 10, 17, 0))
  end

  def call(reason: "Duplicate entry")
    described_class.call(record: record, deleted_by: manager, reason: reason)
  end

  describe "when no PayrollPeriod exists for the record's month" do
    it "soft-deletes the record" do
      call
      expect(record.reload).to be_deleted
    end

    it "returns success" do
      expect(call).to be_success
    end

    it "stores deleted_by and deletion_notes" do
      call(reason: "Wrong employee punched in")
      record.reload
      expect(record.deleted_by).to eq(manager)
      expect(record.deletion_notes).to eq("Wrong employee punched in")
    end

    it "writes an audit log entry" do
      expect { call }.to change(AuditLog, :count).by(1)
      log = AuditLog.last
      expect(log.actor).to eq(manager)
      expect(log.auditable).to eq(record)
      expect(log.action).to eq("delete_attendance")
    end

    it "does not call EntryRecalculator" do
      expect(Payroll::EntryRecalculator).not_to receive(:call)
      call
    end
  end

  describe "when a draft PayrollPeriod exists for the record's month" do
    let!(:period) do
      create(:payroll_period, business: business, period_year: 2026, period_month: 7)
    end

    it "soft-deletes the record" do
      call
      expect(record.reload).to be_deleted
    end

    it "calls EntryRecalculator with the correct user, period, and actor" do
      expect(Payroll::EntryRecalculator).to receive(:call).with(
        user: employee, period: period, triggered_by: manager
      )
      call
    end

    it "still succeeds even if EntryRecalculator raises" do
      allow(Payroll::EntryRecalculator).to receive(:call).and_raise("Unexpected DB error")
      expect(call).to be_success
    end

    it "persists the soft delete regardless of recalculation outcome" do
      allow(Payroll::EntryRecalculator).to receive(:call).and_raise("Payroll error")
      call
      expect(record.reload).to be_deleted
    end
  end

  %i[under_review branch_review_completed].each do |state|
    describe "when the period is #{state} (still editable)" do
      let!(:period) do
        create(:payroll_period, state, business: business, period_year: 2026, period_month: 7)
      end

      it "allows deletion and triggers recalculation" do
        expect(Payroll::EntryRecalculator).to receive(:call).with(
          user: employee, period: period, triggered_by: manager
        )
        result = call
        expect(result).to be_success
        expect(record.reload).to be_deleted
      end
    end
  end

  %i[finalized paid].each do |state|
    describe "when the period is #{state} (locked)" do
      let!(:period) do
        create(:payroll_period, state, business: business, period_year: 2026, period_month: 7)
      end

      it "does not delete the record" do
        call
        expect(record.reload).not_to be_deleted
      end

      it "returns failure with a clear message" do
        result = call
        expect(result).not_to be_success
        expect(result.error).to be_present
      end

      it "does not call EntryRecalculator" do
        expect(Payroll::EntryRecalculator).not_to receive(:call)
        call
      end

      it "does not write an audit log entry" do
        expect { call }.not_to change(AuditLog, :count)
      end
    end
  end

  describe "when the record is already deleted" do
    before { call }

    it "returns failure without re-deleting or re-logging" do
      expect { call }.not_to change(AuditLog, :count)
      expect(call).not_to be_success
    end
  end
end
