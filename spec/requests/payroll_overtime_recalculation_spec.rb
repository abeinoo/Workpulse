require "rails_helper"

RSpec.describe "Payroll overtime recalculation", type: :request do
  around { |ex| travel_to(Time.zone.local(2026, 10, 2, 12, 0, 0)) { ex.run } }

  let(:business)   { create(:business, working_days_per_month: 22, timezone: "UTC", overtime_grace_minutes: 30) }
  let(:branch)     { create(:branch, business: business) }
  let(:employee)   { create(:user, business: business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"),
           end_time: Time.zone.parse("17:00"), overtime_rate_multiplier: 1.5)
  end
  let!(:assignment) { create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1)) }
  let!(:profile)    { create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1)) }
  let(:period)      { create(:payroll_period, business: business, period_year: 2026, period_month: 9, working_days: 22) }

  before do
    [ [ 1, 45 ], [ 2, 90 ] ].each do |day, ot|
      date = Date.new(2026, 9, day)
      create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment, date: date, work_date: date,
             check_in_at: Time.zone.local(2026, 9, day, 9, 0), check_out_at: Time.zone.local(2026, 9, day, 17, 0) + ot.minutes,
             worked_minutes: 480 + ot, late_minutes: 0, early_leave_minutes: 0, status: "present")
    end
    Payroll::EntryCalculator.call(period: period, user: employee, business: business)
    period.update!(status: "under_review")
    business.update!(overtime_grace_minutes: 60)
  end

  def entry = period.payroll_entries.find_by!(user: employee)

  def viewer
    role = business.permission_roles.create!(name: "Payroll viewer",
                                              permissions: %w[view_payroll view_draft_payroll submit_payroll_review])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  it "shows the action on the under-review period and an Arabic preview that changes nothing" do
    accountant.update!(preferred_locale: "ar")
    sign_in accountant

    get payroll_period_path(period)
    expect(response.body).to include(recalculate_overtime_preview_payroll_period_path(period), "إعادة احتساب الوقت الإضافي")

    before = entry.attributes
    get recalculate_overtime_preview_payroll_period_path(period)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("سيتم إعادة احتساب الوقت الإضافي للفترة باستخدام إعداد الوقت الإضافي الحالي: 60 دقيقة.")
    html = Nokogiri::HTML(response.body)
    expect(html.at_css("[data-testid='ot-affected']").text.strip).to eq("1")
    expect(html.at_css("input[name='preview_digest']")).to be_present
    expect(entry.attributes).to eq(before)
  end

  it "applies after confirmation with the preview digest" do
    sign_in accountant
    get recalculate_overtime_preview_payroll_period_path(period)
    digest = Nokogiri::HTML(response.body).at_css("input[name='preview_digest']")["value"]

    patch recalculate_overtime_payroll_period_path(period), params: { preview_digest: digest }

    expect(response).to redirect_to(payroll_period_path(period))
    expect(entry.calculated_overtime_minutes).to eq(90)
    expect(PayrollAuditLog.where(action_type: "overtime_recalculated", actor: accountant).count).to eq(1)
  end

  it "refuses a user without regenerate_payroll, server side (preview and direct PATCH)" do
    sign_in viewer
    before = entry.attributes

    get recalculate_overtime_preview_payroll_period_path(period)
    expect(response).to redirect_to(root_path)

    digest = Payroll::OvertimeRecalculator.new(period_id: period.id, actor: accountant).preview.preview.digest
    patch recalculate_overtime_payroll_period_path(period), params: { preview_digest: digest }
    expect(entry.attributes).to eq(before)

    get payroll_period_path(period)
    expect(response.body).not_to include(recalculate_overtime_preview_payroll_period_path(period))
  end

  %w[finalized paid draft].each do |status|
    it "rejects a direct PATCH on a #{status} period" do
      digest = Payroll::OvertimeRecalculator.new(period_id: period.id, actor: accountant).preview.preview.digest
      period.update_column(:status, status)
      sign_in accountant
      before = entry.attributes

      patch recalculate_overtime_payroll_period_path(period), params: { preview_digest: digest }

      expect(entry.attributes).to eq(before)
      expect(PayrollAuditLog.where(action_type: "overtime_recalculated")).to be_empty
    end
  end
end
