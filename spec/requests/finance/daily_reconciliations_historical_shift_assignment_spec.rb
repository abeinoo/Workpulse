require "rails_helper"

# Regression coverage for: an employee with a permanent/home ShiftAssignment
# PLUS a temporary/date-bounded one (e.g. a two-day coverage assignment at a
# different branch, Aug 17-18) disappeared from that other branch's Daily
# Reconciliation history — both the index listing and direct show access —
# the moment the temporary assignment's effective_to passed.
# DailyReconciliationPolicy::Scope#resolve (and its controller-side mirror,
# now removed in favor of delegating straight to policy_scope) resolved
# branch access via ShiftAssignment.current (today only): once the temporary
# assignment expired, .current fell back to ONLY the permanent/home branch,
# silently excluding the other branch's entire history — even though the
# employee genuinely worked there on record. (Note: this only bites once the
# employee has ANY other .current assignment — if shift_assignments.current
# is empty entirely, the old code's "branch_ids.empty? -> return base"
# fallback happened to grant unrestricted access, which masked the bug unless
# a permanent assignment was also present — hence every fixture below
# includes one.)
#
# Fix: for a non-manager falling back to their own ShiftAssignment history,
# Scope#resolve now resolves access PER RECORD — an EXISTS correlated to each
# DR's own (branch_id, business_date) against ShiftAssignment#active_on's
# exact bounds (effective_from <= business_date AND (effective_to IS NULL OR
# effective_to >= business_date)) — instead of a static "every branch ever
# assigned" list. This grants access to exactly the dates/branches the
# assignment actually covered, nothing more and nothing less: a DR on a date
# OUTSIDE the temporary assignment's window is correctly NOT granted access
# through it (see Test D).
RSpec.describe "Daily Reconciliations — historical access via a temporary ShiftAssignment", type: :request do
  let(:business)   { create(:business) }
  let(:nasr_city)  { create(:branch, business: business, name: "Nasr City") }
  let(:shoubra)    { create(:branch, business: business, name: "Shoubra") }
  let(:home_shift) { create(:shift, :fixed_time, business: business) }
  let(:cover_shift) { create(:shift, :fixed_time, business: business) }

  # A non-manager, branch-scoped viewer — matches the real production shape
  # that triggers the ShiftAssignment fallback in Scope#resolve (BranchScope
  # returns no managed/area branches for a plain employee).
  let(:employee) do
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: %w[view_daily_reconciliation],
      permission_scopes: { "view_daily_reconciliation" => "branch" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # The employee's normal, open-ended "home" assignment — present in every
  # scenario below so shift_assignments.current is never empty once the
  # temporary coverage assignment expires (see header comment).
  def give_home_assignment!
    create(:shift_assignment, user: employee, branch: shoubra, shift: home_shift,
           effective_from: Date.new(2026, 1, 1), effective_to: nil)
  end

  def give_temporary_nasr_assignment!(effective_from: Date.new(2026, 8, 17), effective_to: Date.new(2026, 8, 18))
    create(:shift_assignment, user: employee, branch: nasr_city, shift: cover_shift,
           assignment_kind: "temporary_coverage",
           effective_from: effective_from, effective_to: effective_to, reason: "Two-day coverage")
  end

  def make_dr(branch:, business_date:, state: "verified")
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: state,
      opened_at: business_date.to_time + 8.hours, closed_at: business_date.to_time + 20.hours,
      business_date: business_date
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: employee.id)
    dr
  end

  before { sign_in employee }

  describe "Test 1 — a temporary shift assignment valid on the reconciliation date grants access" do
    it "shows the employee's Nasr City DR for that date in the index and show page" do
      give_home_assignment!
      give_temporary_nasr_assignment!
      dr = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 18))

      travel_to Date.new(2026, 8, 18) do
        # branch_id: "" selects "All Branches", bypassing the sticky/default
        # branch filter (which otherwise defaults to today's own branch) so
        # this exercises the underlying authorization scope directly.
        get finance_daily_reconciliations_path, params: { branch_id: "" }
        expect(response.body).to include(nasr_city.name)

        get finance_daily_reconciliation_path(dr)
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "Test 2 — access survives the temporary assignment expiring" do
    it "still shows the 2026-08-18 Nasr City DR after the assignment's effective_to has passed" do
      give_home_assignment!
      give_temporary_nasr_assignment!
      dr = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 18))

      travel_to Date.new(2026, 8, 20) do
        # Precondition: the temporary assignment is genuinely no longer "current".
        expect(employee.shift_assignments.current.pluck(:branch_id)).not_to include(nasr_city.id)

        # branch_id: "" selects "All Branches", bypassing the sticky/default
        # branch filter (which otherwise defaults to today's own branch) so
        # this exercises the underlying authorization scope directly.
        get finance_daily_reconciliations_path, params: { branch_id: "" }
        expect(response.body).to include(nasr_city.name)

        get finance_daily_reconciliation_path(dr)
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "Test 3 — the day after, the employee's normal assignment applies again" do
    it "resolves to Shoubra (not Nasr City) once the temporary assignment has ended" do
      give_home_assignment!
      give_temporary_nasr_assignment!

      expect(employee.effective_branch_on(Date.new(2026, 8, 19))).to eq(shoubra)
    end
  end

  describe "Test 4 — the temporary assignment overrides the normal assignment for its own date" do
    it "resolves to Nasr City on 2026-08-18 despite a concurrent permanent Shoubra assignment" do
      give_home_assignment!
      give_temporary_nasr_assignment!

      expect(employee.effective_branch_on(Date.new(2026, 8, 18))).to eq(nasr_city)
    end
  end

  describe "Test 5 — the historical reconciliation stays reachable end-to-end after expiry" do
    it "the show page for the historical DR is directly reachable, and appears in the index, once the assignment has expired" do
      give_home_assignment!
      give_temporary_nasr_assignment!
      dr = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 18))

      travel_to Date.new(2026, 8, 25) do
        get finance_daily_reconciliation_path(dr)
        expect(response).to have_http_status(:ok)

        get finance_daily_reconciliations_path, params: { branch_id: "" }
        expect(response.body).to include(dr.branch.name)
      end
    end
  end

  describe "Test 6 — current-day behaviour is unchanged" do
    it "an employee with only a current shift assignment still sees today's own branch DR" do
      give_home_assignment!
      dr = make_dr(branch: shoubra, business_date: Date.current, state: "open")

      get finance_daily_reconciliations_path
      expect(response.body).to include(shoubra.name)

      get finance_daily_reconciliation_path(dr)
      expect(response).to have_http_status(:ok)
    end

    it "does not grant access to an unrelated branch the employee was never assigned to" do
      give_home_assignment!
      other_branch = create(:branch, business: business, name: "October City")
      dr = make_dr(branch: other_branch, business_date: Date.current, state: "open")

      get finance_daily_reconciliation_path(dr)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "Test A — permanent + expired temporary assignment: access is preserved, not lost" do
    it "can access the reconciliation on the historical temporary-assignment date after expiry" do
      give_home_assignment!
      give_temporary_nasr_assignment! # Aug 17 - Aug 18
      dr = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 18))

      travel_to Date.new(2026, 8, 20) do
        expect(employee.shift_assignments.current.pluck(:branch_id)).not_to include(nasr_city.id)

        get finance_daily_reconciliation_path(dr)
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "Test B — August 17 Nasr City reconciliation is visible" do
    it "is directly reachable and listed in the index after the temporary assignment has expired" do
      give_home_assignment!
      give_temporary_nasr_assignment! # Aug 17 - Aug 18
      dr17 = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 17))

      travel_to Date.new(2026, 8, 20) do
        get finance_daily_reconciliation_path(dr17)
        expect(response).to have_http_status(:ok)

        get finance_daily_reconciliations_path, params: { branch_id: "" }
        expect(response.body).to include(nasr_city.name)
      end
    end
  end

  describe "Test C — August 18 Nasr City reconciliation is visible" do
    it "is directly reachable and listed in the index after the temporary assignment has expired" do
      give_home_assignment!
      give_temporary_nasr_assignment! # Aug 17 - Aug 18
      dr18 = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 18))

      travel_to Date.new(2026, 8, 20) do
        get finance_daily_reconciliation_path(dr18)
        expect(response).to have_http_status(:ok)

        get finance_daily_reconciliations_path, params: { branch_id: "" }
        expect(response.body).to include(nasr_city.name)
      end
    end
  end

  describe "Test D — a date outside the temporary assignment's window resolves via whatever assignment actually covers it" do
    it "denies access to a Nasr City DR on a date the temporary assignment never covered" do
      give_home_assignment!
      give_temporary_nasr_assignment! # Aug 17 - Aug 18 only
      outside_dr = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 25))

      travel_to Date.new(2026, 8, 26) do
        # Sanity: no ShiftAssignment (temporary or otherwise) covers Aug 25 at Nasr City.
        expect(ShiftAssignment.active_on(Date.new(2026, 8, 25)).where(user: employee, branch: nasr_city)).to be_empty

        get finance_daily_reconciliation_path(outside_dr)
        expect(response).to have_http_status(:not_found)
      end
    end

    it "still grants access to a DIFFERENT Nasr City DR whose date the assignment does cover" do
      give_home_assignment!
      give_temporary_nasr_assignment! # Aug 17 - Aug 18
      outside_dr = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 25))
      covered_dr = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 18))

      travel_to Date.new(2026, 8, 26) do
        get finance_daily_reconciliation_path(covered_dr)
        expect(response).to have_http_status(:ok)

        get finance_daily_reconciliation_path(outside_dr)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "Test E — expiring the temporary assignment does not break historical access" do
    it "keeps Aug 17/18 access indefinitely afterwards, without ever reactivating or extending the assignment" do
      give_home_assignment!
      assignment = give_temporary_nasr_assignment!
      dr17 = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 17))
      dr18 = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 18))
      original_effective_to = assignment.effective_to

      # Access must survive purely because the assignment's own historical
      # record (effective_from/effective_to) is left untouched — reactivating
      # or extending it would defeat the point of this regression test.
      travel_to Date.new(2027, 1, 1) do
        get finance_daily_reconciliation_path(dr17)
        expect(response).to have_http_status(:ok)

        get finance_daily_reconciliation_path(dr18)
        expect(response).to have_http_status(:ok)
      end

      expect(assignment.reload.effective_to).to eq(original_effective_to)
    end
  end

  describe "Test F — the current assignment is unchanged and unused for historical resolution" do
    it "effective_branch_on(Date.current) still resolves to the permanent branch, untouched by the historical fix" do
      give_home_assignment!
      give_temporary_nasr_assignment! # Aug 17 - Aug 18, long expired by "today"

      travel_to Date.new(2026, 8, 20) do
        expect(employee.effective_branch_on(Date.current)).to eq(shoubra)
        expect(employee.shift_assignments.current.pluck(:branch_id)).to eq([ shoubra.id ])
      end
    end
  end

  describe "Test G — existing authorization for other employees/branches is unchanged" do
    it "a colleague with no ShiftAssignment at Nasr City still cannot access its reconciliations" do
      give_home_assignment!
      give_temporary_nasr_assignment!
      dr = make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 18))

      colleague_role = business.permission_roles.create!(
        name: "R-#{SecureRandom.hex(3)}",
        permissions: %w[view_daily_reconciliation],
        permission_scopes: { "view_daily_reconciliation" => "branch" }
      )
      colleague = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, colleague_role.id) }
      create(:shift_assignment, user: colleague, branch: shoubra, shift: create(:shift, :fixed_time, business: business),
             effective_from: Date.new(2026, 1, 1), effective_to: nil)

      sign_in colleague
      get finance_daily_reconciliation_path(dr)
      expect(response).to have_http_status(:not_found)
    end

    it "a branch manager still sees the whole branch's history regardless of any employee's ShiftAssignment dates" do
      manager_role = business.permission_roles.create!(
        name: "R-#{SecureRandom.hex(3)}",
        permissions: %w[view_daily_reconciliation],
        permission_scopes: { "view_daily_reconciliation" => "branch" }
      )
      manager = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, manager_role.id) }
      nasr_city.update!(branch_manager_id: manager.id)
      dr = make_dr(branch: nasr_city, business_date: Date.new(2020, 1, 1)) # long before any assignment ever existed

      sign_in manager
      get finance_daily_reconciliation_path(dr)
      expect(response).to have_http_status(:ok)
    end
  end

  # ── The exact reported case ──────────────────────────────────────────────
  # Anton Khaled Ramsis Fahmy: permanent Shoubra assignment + a temporary
  # coverage assignment at Nasr City (Aug 17-18, expired by "today" Aug 20).
  #
  # This block reproduces why the PREVIOUS fix (DailyReconciliationPolicy::
  # Scope#resolve resolving per-record via ShiftAssignment#active_on) did not
  # make Nasr City Aug 17/18 appear in the real UI, even though it fixed
  # direct/authorized access (proven by Tests A-G above, all still green
  # under the previous fix alone). The index action has a SEPARATE branch
  # picker/filter layer — accessible_branches_for_dr (used for the branch
  # dropdown AND for #new/#create's "start a session here" branch choice) —
  # that resolved "this employee's branch" via
  # current_user.effective_branch_on(Date.current), i.e. TODAY, completely
  # independent of Scope#resolve. For a non-manager with no BranchScope-based
  # branches, that method returned Anton's single current-day branch
  # (Shoubra) as the ENTIRE picker list. The index's sticky/default branch
  # filter then defaulted to (and could only ever offer) Shoubra:
  # Nasr City was never a selectable option, and apply_dr_filters'
  # `query.where(branch_id: @filter_branch.to_i)` filtered every visible row
  # down to Shoubra only — hiding Aug 17/18 even though the underlying
  # policy_scope already permitted them.
  #
  # Fix: the index now derives its branch picker/filter list
  # (#index_filter_branches) from the branches actually present in the
  # already-correct, date-correlated policy_scope query — not from
  # effective_branch_on(Date.current). #accessible_branches_for_dr itself is
  # untouched and still governs #new/#create/#resolve_branch, so opening a
  # BRAND NEW session today is still restricted to Anton's current branch —
  # this fix only widens what he can find/select among EXISTING records.
  describe "the reported case — Anton Khaled Ramsis Fahmy" do
    let(:anton) { employee }

    before do
      give_home_assignment!                                             # permanent Shoubra
      give_temporary_nasr_assignment!                                   # temporary_coverage, Aug 17 - Aug 18
    end

    let!(:nasr_aug17) { make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 17)) }
    let!(:nasr_aug18) { make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 18)) }
    let!(:nasr_aug19) { make_dr(branch: nasr_city, business_date: Date.new(2026, 8, 19)) } # NOT covered by the temporary assignment
    let!(:shoubra_dr) { make_dr(branch: shoubra,   business_date: Date.new(2026, 8, 19)) }

    it "offers Nasr City as a selectable branch in the index picker once expired (not just Shoubra)" do
      travel_to Date.new(2026, 8, 20) do
        get finance_daily_reconciliations_path
        expect(response.body).to include(shoubra.name)
        expect(response.body).to include(nasr_city.name)
      end
    end

    it "shows Nasr City Aug 17 and Aug 18 when Anton selects Nasr City (or All Branches), but never Aug 19" do
      travel_to Date.new(2026, 8, 20) do
        get finance_daily_reconciliations_path, params: { branch_id: nasr_city.id }
        expect(response.body).to include(I18n.l(Date.new(2026, 8, 17), format: :short))
        expect(response.body).to include(I18n.l(Date.new(2026, 8, 18), format: :short))
        expect(response.body).not_to include(I18n.l(Date.new(2026, 8, 19), format: :short))
      end
    end

    it "still shows Anton's valid Shoubra history alongside Nasr City under All Branches" do
      travel_to Date.new(2026, 8, 20) do
        get finance_daily_reconciliations_path, params: { branch_id: "" }
        expect(response.body).to include(shoubra.name)
        expect(response.body).to include(nasr_city.name)
      end
    end

    it "grants direct access to Nasr City Aug 17 and Aug 18" do
      travel_to Date.new(2026, 8, 20) do
        get finance_daily_reconciliation_path(nasr_aug17)
        expect(response).to have_http_status(:ok)

        get finance_daily_reconciliation_path(nasr_aug18)
        expect(response).to have_http_status(:ok)
      end
    end

    it "denies direct access to Nasr City Aug 19 — the expired temporary assignment never covered it" do
      travel_to Date.new(2026, 8, 20) do
        get finance_daily_reconciliation_path(nasr_aug19)
        expect(response).to have_http_status(:not_found)
      end
    end

    it "grants direct access to the Shoubra record via the permanent assignment" do
      travel_to Date.new(2026, 8, 20) do
        get finance_daily_reconciliation_path(shoubra_dr)
        expect(response).to have_http_status(:ok)
      end
    end

    it "does not let #new/#create offer Nasr City as a place to open a BRAND NEW session today" do
      travel_to Date.new(2026, 8, 20) do
        get new_finance_daily_reconciliation_path
        expect(response.body).not_to include(nasr_city.name)
      end
    end
  end
end
