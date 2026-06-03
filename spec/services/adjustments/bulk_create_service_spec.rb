require "rails_helper"

RSpec.describe Adjustments::BulkCreateService, type: :model do
  let(:business)  { create(:business) }
  let(:creator)   { create(:user, business: business) }
  let(:employee)  { create(:user, business: business) }
  let!(:period)   { create(:payroll_period, business: business, status: "draft", period_month: 6, period_year: 2026) }

  def row(overrides = {})
    {
      user_id:         employee.id,
      adjustment_type: "cash_incentive",
      amount:          "500",
      reason:          "Q2 bonus",
      period_month:    6,
      period_year:     2026
    }.merge(overrides)
  end

  # Default allowed scope for the happy-path tests: just the target employee.
  def service(rows:, allowed: [ employee.id ])
    described_class.new(rows: rows, business: business, created_by: creator,
                        allowed_user_ids: allowed)
  end

  describe "#call" do
    it "creates adjustments as pending_review — never auto-approved" do
      result = service(rows: [ row ]).call

      expect(result).to be_success
      adj = PayrollAdjustment.last
      expect(adj.review_status).to eq("pending_review")
      expect(adj.approved_by).to be_nil
      expect(adj.approved_at).to be_nil
    end

    it "does not auto-approve even when the creator can approve_adjustments" do
      allow(creator).to receive(:can?).and_call_original
      allow(creator).to receive(:can?).with(:manage_adjustments).and_return(true)
      allow(creator).to receive(:can?).with(:approve_adjustments).and_return(true)

      service(rows: [ row ]).call

      expect(PayrollAdjustment.last.review_status).to eq("pending_review")
      expect(PayrollAdjustment.last.approved_by).to be_nil
    end

    it "blocks the whole batch when the target period is already paid" do
      period.update_column(:status, "paid")

      result = service(rows: [ row ]).call

      expect(result).to be_failed
      expect(PayrollAdjustment.count).to eq(0)
      expect(result.row_errors.flat_map(&:messages).join)
        .to include(I18n.t("adjustments.errors.period_processed"))
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Server-side scope validation (never trust the picker / CSV preview)
  # ──────────────────────────────────────────────────────────────
  describe "scope validation" do
    let(:other_employee) { create(:user, business: business) }

    it "business_wide manager: every employee is allowed" do
      # business-wide allowed set = all employees → both rows save
      rows = [ row, row(user_id: other_employee.id) ]
      result = service(rows: rows, allowed: [ employee.id, other_employee.id ]).call

      expect(result).to be_success
      expect(result.count).to eq(2)
    end

    it "managed_employees_only manager: an out-of-scope row rejects the whole batch" do
      # allowed set excludes other_employee (simulating a restricted scope)
      rows = [ row, row(user_id: other_employee.id) ]
      result = service(rows: rows, allowed: [ employee.id ]).call

      expect(result).to be_failed
      expect(PayrollAdjustment.count).to eq(0) # all-or-nothing
      expect(result.row_errors.flat_map(&:messages).join)
        .to include(I18n.t("bulk_adjustments.errors.out_of_scope"))
    end

    it "rejects a manually-submitted out-of-scope user_id (hand-crafted POST)" do
      # The single submitted user_id is not in the creator's allowed set.
      result = service(rows: [ row(user_id: other_employee.id) ], allowed: [ employee.id ]).call

      expect(result).to be_failed
      expect(PayrollAdjustment.count).to eq(0)
      scope_error = result.row_errors.first
      expect(scope_error.index).to eq(0)
      expect(scope_error.messages).to include(I18n.t("bulk_adjustments.errors.out_of_scope"))
    end

    it "rejects a row whose user_id belongs to no allowed employee at all" do
      result = service(rows: [ row(user_id: 999_999) ], allowed: [ employee.id ]).call

      expect(result).to be_failed
      expect(PayrollAdjustment.count).to eq(0)
    end
  end
end
