require "rails_helper"

# The DR index dashboard sections are each gated by their own permission —
# page access (view_daily_reconciliation) alone grants none of them:
#   Reconciliation Workflow → view_reconciliation_workflow
#   Operational Insights    → view_reconciliation_insights
#   Financial Summary       → view_deposit_verification + view_session_totals
RSpec.describe "Finance::DailyReconciliations index — dashboard section permissions", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let!(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 2.days.ago, closed_at: 2.days.ago + 12.hours, business_date: 2.days.ago.to_date
    ).tap do |d|
      TillSessionAmount.create!(daily_reconciliation: d, payment_method: cash_pm,
                                payment_method_name: cash_pm.name, collected_amount: 400, refund_amount: 0)
    end
  end

  def t_ws(key) = I18n.t("finance.daily_reconciliations.index.workspace.#{key}")

  def section_ids
    Nokogiri::HTML(response.body).css(".dashboard-section").map { |el| el["id"] }.compact
  end

  def visit_as(user)
    sign_in user
    get finance_daily_reconciliations_path
    expect(response).to have_http_status(:ok)
  end

  shared_examples "renders only" do |expected|
    it "renders exactly #{expected.inspect}" do
      visit_as(viewer)
      expect(section_ids).to match_array(expected)

      body = response.body
      expect(body.include?(t_ws("section_workflow_title"))).to eq(expected.include?("dr-section-workflow"))
      expect(body.include?(t_ws("section_operational_title"))).to eq(expected.include?("dr-section-insights"))
      expect(body.include?(t_ws("section_financial_title"))).to eq(expected.include?("dr-section-financial-summary"))
    end
  end

  context "A. page access only" do
    let(:viewer) { user_with("view_daily_reconciliation") }

    include_examples "renders only", []

    it "still lists the reconciliation itself and leaves no empty dashboard container" do
      visit_as(viewer)
      expect(response.body).to include("dr-card-list")
      expect(Nokogiri::HTML(response.body).css(".dashboard-section")).to be_empty
    end
  end

  context "B. page + view_session_totals" do
    let(:viewer) { user_with("view_daily_reconciliation", "view_session_totals", "view_deposit_verification") }

    include_examples "renders only", %w[dr-section-financial-summary]
  end

  context "view_session_totals without view_deposit_verification" do
    let(:viewer) { user_with("view_daily_reconciliation", "view_session_totals") }

    include_examples "renders only", []
  end

  context "view_deposit_verification without view_session_totals" do
    let(:viewer) { user_with("view_daily_reconciliation", "view_deposit_verification") }

    it "keeps the Exceptions section but hides the Financial Summary" do
      visit_as(viewer)
      expect(response.body).to include(t_ws("section_exceptions_title"))
      expect(section_ids).not_to include("dr-section-financial-summary")
      expect(response.body).not_to include(t_ws("summary_expected"))
    end

    it "skips computing the Financial Summary totals" do
      visit_as(viewer)
      expect(controller.instance_variable_get(:@summary_expected)).to be_nil
      expect(controller.instance_variable_get(:@summary_deposited)).to be_nil
    end
  end

  context "C. page + view_reconciliation_workflow" do
    let(:viewer) { user_with("view_daily_reconciliation", "view_reconciliation_workflow") }

    include_examples "renders only", %w[dr-section-workflow]
  end

  context "D. page + view_reconciliation_insights" do
    let(:viewer) { user_with("view_daily_reconciliation", "view_reconciliation_insights") }

    include_examples "renders only", %w[dr-section-insights]
  end

  context "Top Depositors data" do
    let(:depositor) { user_with("close_till_session") }

    before { TillSession.create!(daily_reconciliation: dr, depositor_id: depositor.id) }

    it "is not built for a viewer without view_reconciliation_insights" do
      visit_as(user_with("view_daily_reconciliation", "view_deposit_verification"))
      expect(controller.instance_variable_get(:@top_depositors)).to be_empty
      expect(response.body).not_to include(t_ws("top_depositors_title"))
    end

    it "is built for a viewer with view_reconciliation_insights" do
      visit_as(user_with("view_daily_reconciliation", "view_deposit_verification", "view_reconciliation_insights"))
      expect(controller.instance_variable_get(:@top_depositors).map(&:first)).to eq([ depositor ])
      expect(response.body).to include(t_ws("top_depositors_title"))
    end
  end

  context "E. all section permissions" do
    let(:viewer) do
      user_with("view_daily_reconciliation", "view_deposit_verification", "view_session_totals",
                "view_reconciliation_workflow", "view_reconciliation_insights")
    end

    include_examples "renders only", %w[dr-section-workflow dr-section-financial-summary dr-section-insights]
  end

  context "F. business owner" do
    let(:viewer) do
      create(:user, :owner, business: business)
    end

    include_examples "renders only", %w[dr-section-workflow dr-section-financial-summary dr-section-insights]
  end

  describe "toggling a permission on the role" do
    let(:viewer) { user_with("view_daily_reconciliation") }

    it "hides when unchecked and shows once checked" do
      visit_as(viewer)
      expect(section_ids).not_to include("dr-section-workflow", "dr-section-insights")

      viewer.permission_role.update!(permissions: %w[view_daily_reconciliation
                                                     view_reconciliation_workflow
                                                     view_reconciliation_insights])
      get finance_daily_reconciliations_path
      expect(section_ids).to include("dr-section-workflow", "dr-section-insights")

      viewer.permission_role.update!(permissions: %w[view_daily_reconciliation])
      get finance_daily_reconciliations_path
      expect(section_ids).not_to include("dr-section-workflow", "dr-section-insights")
    end
  end
end
