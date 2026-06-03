require "rails_helper"

# Server-side scope enforcement for bulk payroll adjustments. The picker is never
# trusted: a hand-crafted POST carrying an out-of-scope user_id must be rejected.
RSpec.describe "Bulk adjustments scope enforcement", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  # Branch manager: manage_adjustments + a restricted (hierarchy) scope by default.
  let(:manager)  { create(:user, :branch_manager, business: business) }

  # In scope: a direct report of the manager.
  let!(:in_emp)  { create(:user, business: business, manager: manager) }
  # Out of scope: unrelated employee, not managed and not in the manager's branch.
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

  it "allows the same out-of-scope employee once the manager has business_wide scope" do
    role = create(:permission_role, business: business,
                  permissions: %w[view_payroll manage_adjustments],
                  permission_scopes: { "manage_adjustments" => "business_wide" })
    wide_mgr = create(:user, business: business, permission_role: role)
    sign_in wide_mgr

    expect { post_row(out_emp.id) }.to change(PayrollAdjustment, :count).by(1)
  end
end
