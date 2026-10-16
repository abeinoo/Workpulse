require "rails_helper"

# Browser coverage: a branch-scoped Branch Manager (approve_requests) sees and
# uses Approve / Reject on their branch's punch correction, and sees an
# explanation — not actions — on one they submitted on the employee's behalf.
RSpec.describe "Branch Manager punch correction review", type: :system do
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)   { create(:branch, business: business) }
  let(:riyadh)   { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.current - 1 }
  let(:employee) { create(:user, business: business, first_name: "Sara", last_name: "Nasser") }
  let(:manager) do
    role = create(:permission_role, business: business,
                  permissions: %w[view_requests approve_requests view_employees],
                  permission_scopes: { "view_requests" => "branch", "approve_requests" => "branch",
                                       "view_employees" => "branch" })
    create(:user, business: business, permission_role: role, first_name: "Mahmoud", last_name: "Hosny",
                  preferred_locale: "ar")
  end

  let!(:record) do
    shift = Time.use_zone(business.timezone) { create(:shift, :fixed_time, business: business) }
    assignment = create(:shift_assignment, business: business, user: employee, branch: branch, shift: shift,
                                           effective_from: work_date - 30)
    branch.update_column(:branch_manager_id, manager.id)
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                               date: work_date, work_date: work_date, status: "incomplete", check_out_at: nil,
                               check_in_at: riyadh.local(work_date.year, work_date.month, work_date.day, 9))
  end

  def correction(**attrs)
    create(:employee_request, :punch_correction, user: employee, requested_for_date: work_date,
                                                 proposed_date: work_date, proposed_time: "17:00", **attrs)
  end

  it "shows Approve and Reject on an own-branch punch correction, and approving applies it" do
    request = correction
    sign_in manager
    visit employee_request_path(request)

    approve = I18n.t("requests.approve", locale: :ar)
    reject  = I18n.t("requests.reject", locale: :ar)
    expect(page).to have_button(approve)
    expect(page).to have_button(reject)
    expect(page).to have_no_css("[data-testid='awaiting-other-reviewer']")

    click_button approve
    expect(page).to have_text(I18n.t("flash.request_approved", locale: :ar))
    expect(request.reload).to have_attributes(status: "approved", reviewed_by_id: manager.id)
    expect(record.reload.check_out_at).to be_present
  end

  it "rejects with a reason from the same page" do
    request = correction
    sign_in manager
    visit employee_request_path(request)

    click_button I18n.t("requests.reject", locale: :ar)
    within("form[action='#{reject_employee_request_path(request)}']") do
      fill_in "response_note", with: "لا يوجد إثبات"
      click_button I18n.t("requests.show.confirm_reject_btn", locale: :ar)
    end

    expect(page).to have_text(I18n.t("flash.request_rejected", locale: :ar))
    expect(request.reload).to have_attributes(status: "rejected", response_note: "لا يوجد إثبات")
  end

  it "explains instead of offering actions on a correction the manager submitted on the employee's behalf" do
    request = correction(submitted_by: manager)
    sign_in manager
    visit employee_request_path(request)

    expect(page).to have_css("[data-testid='awaiting-other-reviewer']",
                             text: I18n.t("requests.show.awaiting_other_reviewer", locale: :ar))
    expect(page).to have_no_button(I18n.t("requests.approve", locale: :ar))
    expect(page).to have_no_button(I18n.t("requests.reject", locale: :ar))
  end
end
