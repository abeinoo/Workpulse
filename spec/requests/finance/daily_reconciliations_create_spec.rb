require "rails_helper"

# Regression coverage for letting the "New Daily Reconciliation" form accept
# an explicit business_date instead of always forcing Date.current/today —
# motivated by an operational case where a previous day's reconciliation
# (Aug 18) was left open, blocking the creation of Aug 19's. The uniqueness
# rule enforced here is branch_id + business_date (any state), both at the
# model level (a friendly validation) and the DB level
# (idx_dr_unique_branch_business_date, replacing the old partial index that
# excluded open/waiting_for_opening).
RSpec.describe "Finance::DailyReconciliations#create — explicit business_date", type: :request do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business, name: "Nasr City") }
  let(:other_branch) { create(:branch, business: business, name: "Shoubra") }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: scopes
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:cashier) do
    user_with("view_daily_reconciliation", "create_till_session", "close_till_session",
              scopes: { "view_daily_reconciliation" => "branch" })
  end

  before do
    create(:shift_assignment, business: business, user: cashier, branch: branch,
           shift: create(:shift, :fixed_time, business: business),
           effective_from: Date.new(2026, 1, 1), effective_to: nil)
    sign_in cashier
  end

  describe "A — creating for today succeeds" do
    it "creates an open DR stamped with today's business date" do
      today = BusinessDay.current(context: business)

      post finance_daily_reconciliations_path,
           params: { branch_id: branch.id, business_date: today.iso8601 }

      dr = DailyReconciliation.order(:created_at).last
      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(dr.branch).to eq(branch)
      expect(dr.business_date).to eq(today)
      expect(dr.state).to eq("open")
    end
  end

  describe "B — creating for a previous date succeeds when no record exists" do
    it "creates a DR stamped with the explicitly selected past business date" do
      past_date = Date.new(2026, 8, 15)

      post finance_daily_reconciliations_path,
           params: { branch_id: branch.id, business_date: past_date.iso8601 }

      dr = DailyReconciliation.order(:created_at).last
      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(dr.business_date).to eq(past_date)
      expect(dr.state).to eq("open")
      expect(dr.closed_at).to be_nil
      expect(dr.till_session).to be_present
      expect(dr.till_handovers).to be_empty
    end
  end

  describe "C / F — same branch + same date is rejected and redirected to the existing record" do
    it "does not create a second record and redirects to the existing one" do
      target_date = Date.new(2026, 8, 18)
      existing = DailyReconciliation.create!(
        branch: branch, business: business, state: "closed",
        opened_at: target_date.to_time + 8.hours, business_date: target_date
      )

      expect {
        post finance_daily_reconciliations_path,
             params: { branch_id: branch.id, business_date: target_date.iso8601 }
      }.not_to change(DailyReconciliation, :count)

      expect(response).to redirect_to(finance_daily_reconciliation_path(existing))
      expect(flash[:notice]).to eq(I18n.t("finance.daily_reconciliations.errors.dr_exists_for_date"))
    end
  end

  describe "D — same date, different branch succeeds" do
    it "allows creating a DR for the same business_date at a different branch" do
      manager = user_with("view_daily_reconciliation", "create_till_session", "close_till_session",
                           scopes: { "view_daily_reconciliation" => "business" })
      sign_in manager
      target_date = Date.new(2026, 8, 18)
      DailyReconciliation.create!(
        branch: branch, business: business, state: "closed",
        opened_at: target_date.to_time + 8.hours, business_date: target_date
      )

      expect {
        post finance_daily_reconciliations_path,
             params: { branch_id: other_branch.id, business_date: target_date.iso8601 }
      }.to change(DailyReconciliation, :count).by(1)

      dr = DailyReconciliation.order(:created_at).last
      expect(dr.branch).to eq(other_branch)
      expect(dr.business_date).to eq(target_date)
      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
    end
  end

  describe "E — the DB unique constraint holds independently of app-level validation" do
    it "raises RecordNotUnique for a duplicate (branch_id, business_date) inserted around the model validation" do
      # Deliberately mixes states (closed + open) — the OLD partial index
      # (idx_dr_unique_closed_per_branch_per_date) excluded open/
      # waiting_for_opening entirely, so a "closed" row on this date could
      # previously coexist with a fresh "open" row for the SAME branch/date
      # without any DB-level objection. Only the new unconditional index
      # (idx_dr_unique_branch_business_date) closes that gap.
      target_date = Date.new(2026, 8, 18)
      DailyReconciliation.create!(
        branch: branch, business: business, state: "closed",
        opened_at: target_date.to_time + 8.hours, business_date: target_date
      )

      second = DailyReconciliation.new(
        branch: branch, business: business, state: "open",
        opened_at: Time.current, business_date: target_date
      )

      expect { second.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "G — historical ShiftAssignment authorization still governs access to the selected business_date" do
    it "the created historical-date DR is only accessible per the DailyReconciliationPolicy::Scope date correlation" do
      past_date = Date.new(2026, 8, 15)
      post finance_daily_reconciliations_path,
           params: { branch_id: branch.id, business_date: past_date.iso8601 }
      dr = DailyReconciliation.order(:created_at).last

      get finance_daily_reconciliation_path(dr)
      expect(response).to have_http_status(:ok)

      outsider = user_with("view_daily_reconciliation", scopes: { "view_daily_reconciliation" => "branch" })
      sign_in outsider
      get finance_daily_reconciliation_path(dr)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "H — Anton's temporary Nasr City assignment scenario remains unaffected" do
    it "still grants access to the pre-existing Aug 17/18 Nasr City reconciliations" do
      anton = user_with("view_daily_reconciliation", "close_till_session", "accept_till_handover",
                        scopes: { "view_daily_reconciliation" => "branch" })
      create(:shift_assignment, business: business, user: anton, branch: other_branch,
             shift: create(:shift, :fixed_time, business: business),
             effective_from: Date.new(2026, 1, 1), effective_to: nil)
      create(:shift_assignment, business: business, user: anton, branch: branch,
             shift: create(:shift, :fixed_time, business: business),
             assignment_kind: "temporary_coverage",
             effective_from: Date.new(2026, 8, 17), effective_to: Date.new(2026, 8, 18),
             reason: "Two-day coverage")
      nasr_aug18 = DailyReconciliation.create!(
        branch: branch, business: business, state: "closed",
        opened_at: Time.new(2026, 8, 18, 8), business_date: Date.new(2026, 8, 18)
      )

      sign_in anton
      travel_to Date.new(2026, 8, 20) do
        get finance_daily_reconciliation_path(nasr_aug18)
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "I — creating a NEW session today still uses today's branch assignment, never an expired temporary one" do
    it "an actor whose only Nasr City assignment is an expired temporary one cannot create a new Nasr City session today" do
      anton = user_with("view_daily_reconciliation", "create_till_session", "close_till_session",
                        scopes: { "view_daily_reconciliation" => "branch" })
      create(:shift_assignment, business: business, user: anton, branch: other_branch,
             shift: create(:shift, :fixed_time, business: business),
             effective_from: Date.new(2026, 1, 1), effective_to: nil)
      create(:shift_assignment, business: business, user: anton, branch: branch,
             shift: create(:shift, :fixed_time, business: business),
             assignment_kind: "temporary_coverage",
             effective_from: Date.new(2026, 8, 17), effective_to: Date.new(2026, 8, 18),
             reason: "Two-day coverage")

      sign_in anton
      travel_to Date.new(2026, 8, 20) do
        expect {
          post finance_daily_reconciliations_path,
               params: { branch_id: branch.id, business_date: Date.current.iso8601 }
        }.not_to change(DailyReconciliation, :count)

        expect(response).to redirect_to(new_finance_daily_reconciliation_path)
      end
    end
  end

  # ── A past business date starts OPEN, so it obeys one-open-per-branch ──
  # Every new DR starts "open" whatever its business_date (a past date used
  # to be created "closed" directly). Being open, a past date is subject to
  # the same idx_dr_one_open_per_branch / idx_dr_one_waiting_per_branch rule
  # as today: while another DR at the branch is open (or waiting), creation
  # is refused with a message naming both dates. The (branch, selected date)
  # existence check still runs first, so an existing record for the SAME
  # date is never confused with "another day is open".
  describe "a past business date while another DR at the branch is open" do
    let(:manager) do
      user_with("view_daily_reconciliation", "create_till_session", "close_till_session",
                scopes: { "view_daily_reconciliation" => "business" })
    end

    let!(:today_open_dr) do
      today = BusinessDay.current(context: business)
      dr = DailyReconciliation.create!(branch: branch, business: business, state: "open",
                                        opened_at: Time.current, business_date: today)
      TillSession.create!(daily_reconciliation: dr)
      dr
    end

    before { sign_in manager }

    it "is refused and redirects to the open DR, naming both dates" do
      yesterday = BusinessDay.current(context: business) - 1.day

      expect {
        post finance_daily_reconciliations_path,
             params: { branch_id: branch.id, business_date: yesterday.iso8601 }
      }.not_to change(DailyReconciliation, :count)

      expect(response).to redirect_to(finance_daily_reconciliation_path(today_open_dr))
      expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.previous_day_still_open",
                                         open_date:      I18n.l(today_open_dr.business_date, format: :long),
                                         requested_date: I18n.l(yesterday, format: :long)))
    end

    it "leaves today's open DR completely unchanged" do
      yesterday = BusinessDay.current(context: business) - 1.day

      post finance_daily_reconciliations_path,
           params: { branch_id: branch.id, business_date: yesterday.iso8601 }

      today_open_dr.reload
      expect(today_open_dr.state).to eq("open")
      expect(today_open_dr.till_session.current_holder_id).to be_nil
    end

    it "creates the past date as open once today's DR is closed, without reopening today's" do
      today_open_dr.update!(state: "closed", closed_at: Time.current)
      yesterday = BusinessDay.current(context: business) - 1.day

      expect {
        post finance_daily_reconciliations_path,
             params: { branch_id: branch.id, business_date: yesterday.iso8601 }
      }.to change(DailyReconciliation, :count).by(1)

      dr = DailyReconciliation.order(:created_at).last
      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(dr.business_date).to eq(yesterday)
      expect(dr.state).to eq("open")
      expect(dr.till_session.current_holder_id).to be_nil
      expect(today_open_dr.reload.state).to eq("closed")
    end

    it "is refused while a waiting_for_opening DR exists at the branch" do
      today_open_dr.update!(state: "closed", closed_at: Time.current)
      waiting = DailyReconciliation.create!(branch: branch, business: business, state: "waiting_for_opening",
                                            opened_at: Time.current,
                                            business_date: BusinessDay.current(context: business) + 1.day)
      TillSession.create!(daily_reconciliation: waiting)

      expect {
        post finance_daily_reconciliations_path,
             params: { branch_id: branch.id, business_date: (BusinessDay.current(context: business) - 1.day).iso8601 }
      }.not_to change(DailyReconciliation, :count)

      expect(response).to redirect_to(finance_daily_reconciliation_path(waiting))
      expect(flash[:notice]).to eq(I18n.t("finance.daily_reconciliations.errors.already_waiting"))
    end

    it "returns an existing past-date DR (left closed) instead of creating a duplicate" do
      yesterday = BusinessDay.current(context: business) - 1.day
      closed_dr = DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                              opened_at: 1.day.ago, closed_at: 1.day.ago,
                                              business_date: yesterday)

      expect {
        post finance_daily_reconciliations_path,
             params: { branch_id: branch.id, business_date: yesterday.iso8601 }
      }.not_to change(DailyReconciliation, :count)

      expect(response).to redirect_to(finance_daily_reconciliation_path(closed_dr))
      expect(flash[:notice]).to eq(I18n.t("finance.daily_reconciliations.errors.dr_exists_for_date"))
      expect(closed_dr.reload.state).to eq("closed")
    end

    it "redirects to today's DR when today's date is requested again" do
      post finance_daily_reconciliations_path,
           params: { branch_id: branch.id, business_date: BusinessDay.current(context: business).iso8601 }

      # The (branch, business_date) existence check catches this before the
      # open_recon guard is ever reached.
      expect(response).to redirect_to(finance_daily_reconciliation_path(today_open_dr))
      expect(flash[:notice]).to eq(I18n.t("finance.daily_reconciliations.errors.dr_exists_for_date"))
    end

    it "allows the past date on a different branch with no open DR, created open" do
      yesterday = BusinessDay.current(context: business) - 1.day

      expect {
        post finance_daily_reconciliations_path,
             params: { branch_id: other_branch.id, business_date: yesterday.iso8601 }
      }.to change(DailyReconciliation, :count).by(1)

      dr = DailyReconciliation.order(:created_at).last
      expect(dr.branch).to eq(other_branch)
      expect(dr.state).to eq("open")
      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
    end

    it "the past-date open DR's show page renders" do
      dr = Finance::HistoricalDailyReconciliationCreator.new(
        branch: other_branch, business_date: BusinessDay.current(context: business) - 1.day, actor: manager
      ).call.reconciliation

      get finance_daily_reconciliation_path(dr)
      expect(response).to have_http_status(:ok)
    end

    it "still redirects to a STALE open DR whose business_date lags behind today, naming both dates" do
      # today_open_dr already covers "today" — simulate the ORIGINAL
      # motivating case instead: an open DR stuck on an older business_date
      # (never properly closed) with nothing recorded for today at all.
      today_open_dr.destroy!
      stale_date = BusinessDay.current(context: business) - 3.days
      stale_dr = DailyReconciliation.create!(branch: branch, business: business, state: "open",
                                              opened_at: stale_date.to_time, business_date: stale_date)
      TillSession.create!(daily_reconciliation: stale_dr)

      post finance_daily_reconciliations_path,
           params: { branch_id: branch.id, business_date: BusinessDay.current(context: business).iso8601 }

      expect(response).to redirect_to(finance_daily_reconciliation_path(stale_dr))
      expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.previous_day_still_open",
                                         open_date:      I18n.l(stale_date, format: :long),
                                         requested_date: I18n.l(BusinessDay.current(context: business), format: :long)))
    end

    it "rejects a future business_date" do
      tomorrow = BusinessDay.current(context: business) + 1.day

      expect {
        post finance_daily_reconciliations_path,
             params: { branch_id: branch.id, business_date: tomorrow.iso8601 }
      }.not_to change(DailyReconciliation, :count)

      expect(response).to redirect_to(new_finance_daily_reconciliation_path)
      expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.future_date_not_allowed"))
    end
  end
end
