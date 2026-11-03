require "rails_helper"

# "Recalculate Payroll" (Payroll::PeriodRecalculator) through the UI: the
# action, the preview page (EN + AR), confirmation with a reason, server-side
# authorization and business isolation, the re-review banner and badge, and
# Mark All Reviewed staying within the viewer's scope.
RSpec.describe "Payroll period recalculation", type: :request do
  around { |ex| travel_to(Time.zone.local(2026, 11, 10, 12, 0, 0)) { ex.run } }

  let(:business)   { create(:business, working_days_per_month: 26, timezone: "UTC", currency: "EGP") }
  let(:north)      { create(:branch, business: business, name: "North") }
  let(:south)      { create(:branch, business: business, name: "South") }
  let!(:accountant) { create(:user, :accountant, business: business) }
  let(:ahmed)      { create(:user, business: business, first_name: "Ahmed", last_name: "Abdallah") }
  let(:sara)       { create(:user, business: business, first_name: "Sara", last_name: "Hassan") }
  let(:shift)      { create(:shift, :fixed_time, business: business) }
  let(:period)     { create(:payroll_period, business: business, period_year: 2026, period_month: 10, working_days: 26) }

  def oct(day) = Date.new(2026, 10, day)

  before do
    { ahmed => north, sara => south }.each do |user, branch|
      assignment = create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
      [ 1, 4, 6, 7, 8, 11, 14, 15, 18, 20, 21, 25, 28, 29 ].each do |d|
        create(:attendance_record, user: user, branch: branch, shift_assignment: assignment, date: oct(d), work_date: oct(d),
               check_in_at: Time.zone.local(2026, 10, d, 9), check_out_at: Time.zone.local(2026, 10, d, 17),
               worked_minutes: 480, late_minutes: 0, early_leave_minutes: 0, status: "present")
      end
    end
    create(:salary_profile, :daily, user: ahmed, base_amount: 461.54, effective_from: Date.new(2026, 3, 1))
    create(:salary_profile, :daily, user: sara, base_amount: 400, effective_from: Date.new(2026, 1, 1))
    [ ahmed, sara ].each { |u| Payroll::EntryCalculator.call(period: period, user: u, business: business) }
    period.payroll_entries.update_all(needs_review: false)
    period.update!(status: "under_review")
    create(:salary_profile, :daily, user: ahmed, base_amount: 500, effective_from: oct(15))
  end

  def entry_of(user) = period.payroll_entries.find_by!(user: user)
  def digest_from_page = Nokogiri::HTML(response.body).at_css("input[name='preview_digest']")["value"]

  def role_user(permissions, branch: nil)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions)
    create(:user, business: business).tap do |u|
      u.update_column(:permission_role_id, role.id)
      branch&.update_column(:branch_manager_id, u.id)
    end
  end

  describe "the action" do
    %w[under_review branch_review_completed].each do |status|
      it "is offered on a #{status} period, separate from the draft-only Regenerate" do
        period.update_column(:status, status)
        sign_in accountant
        get payroll_period_path(period)

        page = Nokogiri::HTML(response.body)
        expect(page.at_css("[data-testid='recalc-action']")["href"]).to eq(recalculate_preview_payroll_period_path(period))
        expect(response.body).not_to include(regenerate_payroll_period_path(period))
      end
    end

    %w[draft finalized paid].each do |status|
      it "is not offered on a #{status} period" do
        period.update_column(:status, status)
        sign_in accountant
        get payroll_period_path(period)

        expect(response.body).not_to include(recalculate_preview_payroll_period_path(period))
      end
    end
  end

  describe "preview and confirm" do
    it "previews in English without writing, then applies with a reason" do
      sign_in accountant
      before = entry_of(ahmed).attributes

      get recalculate_preview_payroll_period_path(period)
      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.at_css("[data-testid='recalc-changed']").text.strip).to eq("1")
      expect(page.at_css("[data-testid='recalc-unchanged']").text.strip).to eq("1")
      expect(page.at_css("[data-testid='recalc-row-#{ahmed.id}']").text).to include("6,461.56", "6,730.78")
      expect(page.at_css("[data-testid='recalc-total-base_salary']").text).to include("269.22")
      expect(page.at_css("[data-testid='recalc-branches']").text).to include("North")
      expect(page.at_css("textarea[name='reason'][required]")).to be_present
      expect(page.at_css("input[name='acknowledge'][required]")).to be_present
      expect(entry_of(ahmed).attributes).to eq(before)

      patch recalculate_payroll_period_path(period), params: { preview_digest: digest_from_page, reason: "salary fix" }
      expect(response).to redirect_to(payroll_period_path(period))
      expect(flash[:notice]).to eq(I18n.t("payroll.period_recalculation.flash.applied", count: 1))
      expect(entry_of(ahmed).base_salary).to eq(BigDecimal("6730.78"))
      expect(PayrollAuditLog.where(action_type: "recalculated", actor: accountant).count).to eq(1)

      follow_redirect!
      page = Nokogiri::HTML(response.body)
      expect(page.at_css("[data-testid='recalc-review-banner']").text)
        .to include(I18n.t("payroll.period_recalculation.review_banner", count: 1))
      expect(response.body).to include(I18n.t("payroll.period_recalculation.re_review_badge"))
      expect(response.body).to include(I18n.t("payroll.audit_log_action_types.recalculated"), "salary fix")
    end

    it "renders the preview in Arabic" do
      accountant.update!(preferred_locale: "ar")
      sign_in accountant
      get recalculate_preview_payroll_period_path(period)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("إعادة احتساب الرواتب", "الفروع المتأثرة", "سبب إعادة الاحتساب")
      expect(response.body).not_to include("translation missing")
    end

    it "refuses a submission without a reason and changes nothing" do
      sign_in accountant
      get recalculate_preview_payroll_period_path(period)
      before = entry_of(ahmed).attributes

      patch recalculate_payroll_period_path(period), params: { preview_digest: digest_from_page, reason: " " }
      expect(response).to redirect_to(recalculate_preview_payroll_period_path(period))
      expect(flash[:alert]).to eq(I18n.t("payroll.period_recalculation.errors.reason_required"))
      expect(entry_of(ahmed).attributes).to eq(before)
    end

    it "refuses a stale preview and asks for a fresh one" do
      sign_in accountant
      get recalculate_preview_payroll_period_path(period)
      digest = digest_from_page
      create(:payroll_adjustment, payroll_period: period, user: sara, adjustment_type: :cash_incentive,
                                  amount: 50, review_status: :approved)

      patch recalculate_payroll_period_path(period), params: { preview_digest: digest, reason: "salary fix" }
      expect(response).to redirect_to(recalculate_preview_payroll_period_path(period))
      expect(flash[:alert]).to eq(I18n.t("payroll.period_recalculation.errors.preview_changed"))
      expect(PayrollAuditLog.where(action_type: "recalculated")).to be_empty
    end
  end

  describe "authorization" do
    it "refuses a user without regenerate_payroll, server side (preview and direct PATCH)" do
      viewer = role_user(%w[view_payroll view_draft_payroll submit_payroll_review complete_branch_review])
      digest = Payroll::PeriodRecalculator.new(period_id: period.id, actor: accountant).preview.preview.digest
      sign_in viewer
      before = entry_of(ahmed).attributes

      get recalculate_preview_payroll_period_path(period)
      expect(response).to redirect_to(root_path)
      patch recalculate_payroll_period_path(period), params: { preview_digest: digest, reason: "x" }
      expect(entry_of(ahmed).attributes).to eq(before)
      get payroll_period_path(period)
      expect(response.body).not_to include(recalculate_preview_payroll_period_path(period))
    end

    it "never reaches another business's period" do
      outsider = create(:user, :accountant, business: create(:business))
      sign_in outsider
      before = entry_of(ahmed).attributes

      get recalculate_preview_payroll_period_path(period)
      expect(response).not_to have_http_status(:ok)
      patch recalculate_payroll_period_path(period), params: { preview_digest: "x", reason: "x" }
      expect(entry_of(ahmed).attributes).to eq(before)
    end

    %w[draft finalized paid].each do |status|
      it "rejects a direct PATCH on a #{status} period" do
        digest = Payroll::PeriodRecalculator.new(period_id: period.id, actor: accountant).preview.preview.digest
        period.update_column(:status, status)
        sign_in accountant
        before = entry_of(ahmed).attributes

        patch recalculate_payroll_period_path(period), params: { preview_digest: digest, reason: "x" }
        expect(entry_of(ahmed).attributes).to eq(before)
        expect(PayrollAuditLog.where(action_type: "recalculated")).to be_empty
      end
    end
  end

  describe "who can clear recalculation review flags" do
    let(:north_manager) { role_user(%w[view_payroll view_draft_payroll complete_branch_review], branch: north) }
    let(:south_manager) { role_user(%w[view_payroll view_draft_payroll complete_branch_review], branch: south) }

    before do
      # Both employees change: Ahmed (North) by the raise, Sara (South) by one of her own.
      create(:salary_profile, :daily, user: sara, base_amount: 450, effective_from: oct(15))
      recalculator = Payroll::PeriodRecalculator.new(period_id: period.id, actor: accountant)
      recalculator.apply!(expected_digest: recalculator.preview.preview.digest, reason: "fix")
      expect(period.payroll_entries.where(recalculation_review_required: true).count).to eq(2)
    end

    def flagged?(user) = entry_of(user).recalculation_review_required

    it "lets a branch manager clear their own branch's entry, never another branch's" do
      sign_in south_manager

      patch mark_reviewed_payroll_period_payroll_entry_path(period, entry_of(ahmed))
      expect(response).to have_http_status(:not_found) # outside the manager's policy scope
      expect(flagged?(ahmed)).to be(true)

      sign_in south_manager # the 404 response does not carry the test session forward
      patch mark_reviewed_payroll_period_payroll_entry_path(period, entry_of(sara))
      expect(flash[:notice]).to eq(I18n.t("payroll.needs_review.flash.cleared"))
      expect(flagged?(sara)).to be(false)
    end

    it "limits a branch manager's Mark All Reviewed to their branch, even with another branch's ids" do
      sign_in north_manager

      patch mark_all_reviewed_payroll_period_path(period), params: { entry_ids: [ entry_of(sara).id ] }
      expect(flagged?(sara)).to be(true)

      patch mark_all_reviewed_payroll_period_path(period)
      expect(flagged?(ahmed)).to be(false)
      expect(flagged?(sara)).to be(true)
    end

    it "clears only the completing branch's entries when a branch review is completed" do
      create(:payroll_period_branch_review, payroll_period: period, branch: south, reviewer: south_manager, status: "pending")

      expect(Payroll::BranchReviewCompleter.call(period: period, branch: south, reviewer: south_manager)).to be_success
      expect(flagged?(sara)).to be(false)
      expect(flagged?(ahmed)).to be(true)
    end

    it "lets a business-wide reviewer clear every affected entry, after which Finalize succeeds" do
      period.update_column(:status, "branch_review_completed")
      sign_in accountant

      patch mark_all_reviewed_payroll_period_path(period)
      expect(flagged?(ahmed)).to be(false)
      expect(flagged?(sara)).to be(false)

      patch finalize_payroll_period_path(period)
      expect(period.reload.status).to eq("finalized")
    end
  end

  describe "re-review" do
    before do
      digest = Payroll::PeriodRecalculator.new(period_id: period.id, actor: accountant).preview.preview.digest
      Payroll::PeriodRecalculator.new(period_id: period.id, actor: accountant).apply!(expected_digest: digest, reason: "fix")
      # Sara's figures did not change; give her a plain flag to clear too.
      entry_of(sara).update_column(:needs_review, true)
    end

    it "Mark All Reviewed clears only entries the viewer can see" do
      south_manager = role_user(%w[view_payroll view_draft_payroll complete_branch_review], branch: south)
      sign_in south_manager

      patch mark_all_reviewed_payroll_period_path(period)
      expect(entry_of(sara).needs_review).to be(false)
      expect(entry_of(ahmed).recalculation_review_required).to be(true) # North's entry is out of scope
    end

    it "Mark Reviewed on the entry clears the requirement, then finalization succeeds" do
      period.update_column(:status, "branch_review_completed")
      sign_in accountant

      patch finalize_payroll_period_path(period)
      expect(flash[:alert]).to eq(I18n.t("payroll.errors.recalculation_review_required_finalize", count: 1))
      expect(period.reload.status).to eq("branch_review_completed")

      patch mark_reviewed_payroll_period_payroll_entry_path(period, entry_of(ahmed))
      expect(entry_of(ahmed).recalculation_review_required).to be(false)
      entry_of(sara).update_column(:needs_review, false)

      patch finalize_payroll_period_path(period)
      expect(period.reload.status).to eq("finalized")
    end
  end
end
