require "rails_helper"

# The payroll period page and its review actions with a central review slot:
# business-level reviewers see it labelled and complete it with their branch
# slots; a branch manager's approval never reaches it.
RSpec.describe "Payroll periods — central review", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:period)   { create(:payroll_period, business: business, status: :under_review) }

  def user_with(permissions, scopes = {})
    create(:user, business: business,
                  permission_role: create(:permission_role, business: business, permissions: permissions,
                                                            permission_scopes: scopes))
  end

  let(:central_reviewer) do
    user_with(%w[view_payroll finalize_payroll complete_branch_review], "complete_branch_review" => "business")
  end
  let(:branch_manager) { user_with(%w[view_payroll complete_branch_review]).tap { |u| branch_a.update!(branch_manager: u) } }

  let!(:branch_slot)  { create(:payroll_period_branch_review, payroll_period: period, branch: branch_a, reviewer: branch_manager) }
  let!(:central_slot) { create(:payroll_period_branch_review, :central, payroll_period: period) }

  it "shows the central slot to a business-level reviewer, in English and Arabic" do
    sign_in central_reviewer

    get payroll_period_path(period)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("payroll.central_review.label", locale: :en))

    central_reviewer.update!(preferred_locale: "ar")
    get payroll_period_path(period)
    expect(response.body).to include(I18n.t("payroll.central_review.label", locale: :ar))
  end

  it "lets a business-level reviewer complete the central slot with the branch slots" do
    sign_in central_reviewer

    patch complete_branch_review_payroll_period_path(period)

    expect(central_slot.reload).to have_attributes(status: "completed", reviewer_id: central_reviewer.id)
    expect(branch_slot.reload).to be_completed
    expect(period.reload).to be_branch_review_completed
  end

  it "completes only a branch manager's own slot, never the central one" do
    sign_in branch_manager

    get payroll_period_path(period)
    expect(response.body).not_to include(I18n.t("payroll.central_review.label"))

    patch complete_branch_review_payroll_period_path(period)

    expect(branch_slot.reload).to be_completed
    expect(central_slot.reload).to have_attributes(status: "pending", reviewer_id: nil)
    expect(period.reload).to be_under_review
  end

  it "keeps a branch manager's change request on their own slot" do
    sign_in branch_manager

    patch request_changes_payroll_period_path(period), params: { comment: "Wrong overtime" }

    expect(branch_slot.reload).to be_changes_requested
    expect(central_slot.reload).to be_pending
  end

  it "serves the central slot over the JSON API without a branch" do
    sign_in central_reviewer

    get "/api/v1/payroll_periods/#{period.id}", as: :json

    expect(response).to have_http_status(:ok)
    reviews = response.parsed_body.dig("data", "branch_reviews")
    expect(reviews).to include(a_hash_including("branch_id" => nil, "branch_name" => nil, "status" => "pending"))
  end

  describe "reviewer display and timeline" do
    let(:requester) do
      user_with(%w[view_payroll complete_branch_review], "complete_branch_review" => "business").tap do |u|
        u.update!(first_name: "Rania", last_name: "Requester")
      end
    end
    let(:accountant) { user_with(%w[view_payroll submit_payroll_review]) }

    before do
      central_reviewer.update!(first_name: "Cora", last_name: "Completer")
      sign_in central_reviewer
    end

    def central_reviewer_cell
      get payroll_period_path(period)
      Nokogiri::HTML(response.body).css("tr").find { |tr| tr.text.include?(I18n.t("payroll.central_review.label")) }
              .at_css("td[data-label='#{I18n.t('payroll.show.reviewer')}']").text.squish
    end

    it "shows who it is assigned to while pending, who asked while changes are requested, and who approved once completed" do
      expect(central_reviewer_cell).to eq(I18n.t("payroll.central_review.business_level_reviewer"))

      Payroll::ChangesRequester.call(period: period, branch: nil, reviewer: requester, comment: "Check overtime")
      expect(central_reviewer_cell).to eq(I18n.t("payroll.show.changes_requested_by", name: "Rania Requester"))

      Payroll::SubmitForReview.call(period: period.reload, by: accountant)
      expect(central_reviewer_cell).to eq(I18n.t("payroll.central_review.business_level_reviewer")) # never the requester

      Payroll::BranchReviewCompleter.call(period: period.reload, branch: nil, reviewer: central_reviewer)
      expect(central_reviewer_cell).to eq("Cora Completer")
    end

    it "keeps the requester, the comment and the completer in the timeline" do
      Payroll::ChangesRequester.call(period: period, branch: nil, reviewer: requester, comment: "Check overtime")
      Payroll::SubmitForReview.call(period: period.reload, by: accountant)
      Payroll::BranchReviewCompleter.call(period: period.reload, branch: nil, reviewer: central_reviewer)

      sign_in create(:user, business: business).tap { |u| business.update!(owner: u) } # the audit log needs its own permission
      get payroll_period_path(period)
      timeline = Nokogiri::HTML(response.body).at_css(".payroll-timeline").text.squish
      expect(timeline).to include(I18n.t("payroll.audit_log_action_types.branch_changes_requested"), "Rania Requester", "Check overtime",
                                  I18n.t("payroll.audit_log_action_types.resubmitted_for_review"),
                                  I18n.t("payroll.audit_log_action_types.review_slot_completed"), "Cora Completer")
    end

    it "warns that a central review is required when floating employees appeared after submission" do
      central_slot.destroy!
      shift = create(:shift, :hour_based, business: business)
      floater = create(:user, business: business)
      create(:shift_assignment, :floating, user: floater, shift: shift, effective_from: period.period_start)
      create(:payroll_entry, payroll_period: period, user: floater)

      get payroll_period_path(period)

      expect(Nokogiri::HTML(response.body).at_css("[data-testid='central-review-attention']").text.squish)
        .to eq(I18n.t("payroll.central_review.attention_required"))
    end
  end
end
