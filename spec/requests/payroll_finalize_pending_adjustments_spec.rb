require "rails_helper"

# Every finalize / mark-paid entry point (web + API) goes through
# Payroll::Approver.advance, which refuses while adjustments are pending review.
RSpec.describe "Finalize / mark paid with pending adjustments", type: :request do
  let(:business) { create(:business) }
  let(:admin)    { create(:user, :accountant, business: business) }
  let(:creator)  { create(:user, :accountant, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:period)   { create(:payroll_period, :branch_review_completed, business: business) }

  def pending_adjustment
    create(:payroll_adjustment, :cash_incentive, payroll_period: period, business: business,
           user: employee, created_by: creator)
  end

  def json = JSON.parse(response.body)

  before { sign_in admin }

  describe "web" do
    it "finalize redirects with the localized count and leaves the period unfinalized" do
      2.times { pending_adjustment }

      patch finalize_payroll_period_path(period)

      expect(response).to redirect_to(payroll_period_path(period))
      expect(flash[:alert]).to eq(I18n.t("payroll.errors.pending_adjustments_finalize", count: 2))
      expect(period.reload.status).to eq("branch_review_completed")
    end

    it "finalize works as before with nothing pending" do
      patch finalize_payroll_period_path(period)

      expect(flash[:notice]).to eq(I18n.t("flash.period_finalized"))
      expect(period.reload.status).to eq("finalized")
    end

    it "mark paid is refused with the payment message (legacy pending item in a finalized period)" do
      pending_adjustment
      period.update_column(:status, "finalized")

      patch mark_paid_payroll_period_path(period)

      expect(flash[:alert]).to eq(I18n.t("payroll.errors.pending_adjustments_pay", count: 1))
      expect(period.reload.status).to eq("finalized")
    end

    it "uses the Arabic message for an Arabic-locale user" do
      admin.update_column(:preferred_locale, "ar")
      pending_adjustment

      patch finalize_payroll_period_path(period)

      expect(flash[:alert]).to eq(I18n.t("payroll.errors.pending_adjustments_finalize", count: 1, locale: :ar))
    end
  end

  describe "API" do
    it "finalize returns 422 with the count" do
      pending_adjustment

      patch finalize_api_v1_payroll_period_path(period)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["message"]).to eq(I18n.t("payroll.errors.pending_adjustments_finalize", count: 1))
      expect(period.reload.status).to eq("branch_review_completed")
    end

    it "mark_paid returns 422 with the payment message" do
      pending_adjustment
      period.update_column(:status, "finalized")

      patch mark_paid_api_v1_payroll_period_path(period)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["message"]).to eq(I18n.t("payroll.errors.pending_adjustments_pay", count: 1))
      expect(period.reload.status).to eq("finalized")
    end

    it "finalize succeeds once nothing is pending" do
      patch finalize_api_v1_payroll_period_path(period)

      expect(response).to have_http_status(:ok)
      expect(period.reload.status).to eq("finalized")
    end
  end
end
