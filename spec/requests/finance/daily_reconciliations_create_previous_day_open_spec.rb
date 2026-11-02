require "rails_helper"

# Production report: on Nov 2 a cashier tried to start the day while Nov 1's
# DR was still open, and was redirected to Nov 1 with "a reconciliation
# already exists ... on the CURRENT business day" — untrue, since Nov 2 had
# no record. The block itself is the intended rule (idx_dr_one_open_per_branch:
# at most one open DR per branch at any time); the message must instead name
# the open day and the requested day so the user knows to close Nov 1 first.
RSpec.describe "Finance::DailyReconciliations#create — previous business day still open", type: :request do
  let(:business) { create(:business, timezone: "Africa/Cairo", business_day_start_hour: 0) }
  let(:branch)   { create(:branch, business: business) }
  let(:cairo)    { Time.find_zone("Africa/Cairo") }
  let(:nov1)     { Date.new(2026, 11, 1) }
  let(:nov2)     { Date.new(2026, 11, 2) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:employee) { user_with("view_daily_reconciliation", "create_till_session", "close_till_session") }
  let(:owner)    { create(:user, :owner, business: business) }

  before do
    create(:shift_assignment, business: business, user: employee, branch: branch,
           shift: create(:shift, :fixed_time, business: business),
           effective_from: Date.new(2026, 1, 1), effective_to: nil)
  end

  def create_dr
    post finance_daily_reconciliations_path, params: { branch_id: branch.id }
  end

  def expected_alert(open_date, requested_date)
    I18n.t("finance.daily_reconciliations.errors.previous_day_still_open",
           open_date: I18n.l(open_date, format: :long), requested_date: I18n.l(requested_date, format: :long))
  end

  # Nov 1 created at 23:50 Cairo and left open.
  def open_nov1_as(user)
    sign_in user
    travel_to(cairo.local(2026, 11, 1, 23, 50)) { create_dr }
    DailyReconciliation.find_by!(branch: branch, business_date: nov1)
  end

  { employee: :employee, owner: :owner }.each do |label, user_method|
    context "as #{label}" do
      it "after midnight Cairo, blocks Nov 2 and redirects to the open Nov 1 DR naming both dates" do
        nov1_dr = open_nov1_as(send(user_method))
        expect(nov1_dr).to be_open

        travel_to(cairo.local(2026, 11, 2, 0, 10)) do
          # UTC calendar is still Nov 1 — the business day must come from the business timezone.
          expect(BusinessDay.current(context: business)).to eq(nov2)
          expect { create_dr }.not_to change(DailyReconciliation, :count)
        end

        expect(response).to redirect_to(finance_daily_reconciliation_path(nov1_dr))
        expect(flash[:alert]).to eq(expected_alert(nov1, nov2))
        expect(DailyReconciliation.where(branch: branch, business_date: nov2)).not_to exist
      end

      it "leaves the Nov 1 DR and its till session unchanged and open" do
        nov1_dr = open_nov1_as(send(user_method))
        before_attrs   = nov1_dr.reload.attributes
        before_session = nov1_dr.till_session.reload.attributes

        travel_to(cairo.local(2026, 11, 2, 0, 10)) { create_dr }

        nov1_dr.reload
        expect(nov1_dr.attributes).to eq(before_attrs)
        expect(nov1_dr.till_session.reload.attributes).to eq(before_session)
        expect(nov1_dr).to be_open
        expect(nov1_dr.closed_at).to be_nil
      end
    end
  end

  it "renders the message in Arabic for an Arabic-locale user" do
    employee.update_column(:preferred_locale, "ar")
    open_nov1_as(employee)

    travel_to(cairo.local(2026, 11, 2, 0, 10)) { create_dr }

    expected = I18n.with_locale(:ar) { expected_alert(nov1, nov2) }
    expect(flash[:alert]).to eq(expected)
    expect(flash[:alert]).to include("نوفمبر")
  end

  it "before the business-day rollover, treats the request as the same day (no new DR, existing-date message)" do
    business.update!(business_day_start_hour: 4)
    nov1_dr = open_nov1_as(employee)

    travel_to(cairo.local(2026, 11, 2, 0, 10)) do
      expect(BusinessDay.current(context: business)).to eq(nov1)
      expect { create_dr }.not_to change(DailyReconciliation, :count)
    end

    expect(response).to redirect_to(finance_daily_reconciliation_path(nov1_dr))
    expect(flash[:notice]).to eq(I18n.t("finance.daily_reconciliations.errors.dr_exists_for_date"))
  end

  it "once Nov 1 is closed, creates Nov 2 and still rejects a duplicate Nov 2" do
    nov1_dr = open_nov1_as(employee)
    nov1_dr.update!(state: "closed", closed_at: cairo.local(2026, 11, 2, 0, 5))

    travel_to(cairo.local(2026, 11, 2, 0, 10)) do
      expect { create_dr }.to change(DailyReconciliation, :count).by(1)
      nov2_dr = DailyReconciliation.find_by!(branch: branch, business_date: nov2)
      expect(nov2_dr).to be_open
      expect(response).to redirect_to(finance_daily_reconciliation_path(nov2_dr))

      expect { create_dr }.not_to change(DailyReconciliation, :count)
      expect(response).to redirect_to(finance_daily_reconciliation_path(nov2_dr))
      expect(flash[:notice]).to eq(I18n.t("finance.daily_reconciliations.errors.dr_exists_for_date"))
    end

    expect(nov1_dr.reload).to be_closed
  end

  it "an open DR on another branch does not block this branch" do
    other_branch = create(:branch, business: business)
    other_dr = DailyReconciliation.create!(branch: other_branch, business: business, state: "open",
                                           opened_at: cairo.local(2026, 11, 1, 9), business_date: nov1)
    sign_in owner

    travel_to(cairo.local(2026, 11, 2, 0, 10)) do
      expect { create_dr }.to change(DailyReconciliation, :count).by(1)
    end

    expect(DailyReconciliation.find_by(branch: branch, business_date: nov2)).to be_open
    expect(other_dr.reload).to be_open
  end

  describe "concurrent creation" do
    it "the DB forbids a second open DR on the branch even when app-level checks are bypassed" do
      open_nov1_as(employee)

      expect {
        DailyReconciliation.create!(branch: branch, business: business, state: "open",
                                    opened_at: Time.current, business_date: nov2)
      }.to raise_error(ActiveRecord::RecordNotUnique, /idx_dr_one_open_per_branch/)
    end

    it "a request that loses the race to the open-DR index redirects to the open DR without creating a duplicate" do
      nov1_dr = open_nov1_as(employee)
      # Simulate the guard reading before a concurrent request's open DR committed.
      allow(DailyReconciliation).to receive(:open_for).and_call_original
      allow(DailyReconciliation).to receive(:open_for).with(branch).and_return(nil, nov1_dr)

      travel_to(cairo.local(2026, 11, 2, 0, 10)) do
        expect { create_dr }.not_to change(DailyReconciliation, :count)
      end

      expect(response).to redirect_to(finance_daily_reconciliation_path(nov1_dr))
      expect(nov1_dr.reload).to be_open
    end
  end
end
