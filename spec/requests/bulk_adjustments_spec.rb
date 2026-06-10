require "rails_helper"

# Server-side scope enforcement for bulk payroll adjustments. The picker is never
# trusted: a hand-crafted POST carrying an out-of-scope user_id must be rejected.
RSpec.describe "Bulk adjustments scope enforcement", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  # Branch manager: manage_adjustments + a restricted (branch) scope by default.
  let(:manager)   { create(:user, :branch_manager, business: business) }
  let(:bm_branch) { Branch.find_by!(business: business, branch_manager_id: manager.id) }
  let(:shift)     { create(:shift, :fixed_time, business: business) }

  # In scope: an employee assigned to the manager's branch.
  let!(:in_emp) do
    create(:user, business: business).tap do |u|
      create(:shift_assignment, user: u, branch: bm_branch, shift: shift)
    end
  end
  # Out of scope: unrelated employee, not assigned to the manager's branch.
  let!(:out_emp) { create(:user, business: business) }

  let!(:period) do
    create(:payroll_period, business: business, status: "draft",
           period_month: 7, period_year: 2026)
  end

  before { sign_in manager }

  def post_row(user_id)
    post bulk_adjustments_path, params: {
      bulk_adjustment: {
        period_key: "2026-7",
        rows: { "0" => { user_id: user_id, adjustment_type: "cash_incentive",
                         amount: "100", reason: "Test" } }
      }
    }
  end

  it "creates an adjustment for an in-scope employee" do
    expect { post_row(in_emp.id) }.to change(PayrollAdjustment, :count).by(1)
    expect(response).to redirect_to(adjustments_path(period_month: 7, period_year: 2026))
  end

  it "rejects a hand-crafted POST for an out-of-scope employee and saves nothing" do
    expect { post_row(out_emp.id) }.not_to change(PayrollAdjustment, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include(I18n.t("bulk_adjustments.errors.out_of_scope"))
  end

  it "allows the same out-of-scope employee once the manager has business scope" do
    role = create(:permission_role, business: business,
                  permissions: %w[view_payroll manage_adjustments],
                  permission_scopes: { "manage_adjustments" => "business" })
    wide_mgr = create(:user, business: business, permission_role: role)
    sign_in wide_mgr

    expect { post_row(out_emp.id) }.to change(PayrollAdjustment, :count).by(1)
  end
end
