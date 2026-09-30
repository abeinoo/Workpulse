require "rails_helper"

# Regression coverage: every resource id a request supplies to shift
# assignment creation (web create, bulk_assign_preview, bulk_assign) must
# resolve inside the current user's business. The employee check for create
# lives in shift_assignment_create_business_scope_spec.rb.
RSpec.describe "Web security — shift assignment resource business scope", type: :request do
  let(:business_a) { create(:business) }
  let(:business_b) { create(:business) }

  let!(:owner_a)   { create(:user, :owner, business: business_a) }
  let(:manager_a)  { api_user_with(business_a, :view_shifts, :assign_shifts) }
  let(:employee_a) { create(:user, business: business_a) }
  let(:employee_b) { create(:user, business: business_b) }

  let(:shift_a)   { create(:shift, :fixed_time, business: business_a) }
  let(:branch_a)  { create(:branch, business: business_a) }
  let(:profile_a) { create(:shift_rule_profile, business: business_a) }

  let(:shift_b)   { create(:shift, :fixed_time, business: business_b, name: "SecretShiftB") }
  let(:branch_b)  { create(:branch, business: business_b, name: "SecretBranchB") }
  let(:profile_b) { create(:shift_rule_profile, business: business_b, name: "SecretProfileB") }

  def t_error(key) = I18n.t("activerecord.errors.models.shift_assignment.#{key}")

  # ── create ──────────────────────────────────────────────────────────────────
  describe "POST /shift_assignments" do
    def create_assignment(user: employee_a, shift: shift_a, branch: branch_a, profile: profile_a, extra: {}, top_level: {})
      post shift_assignments_path, params: top_level.merge(
        shift_assignment: {
          user_id: user&.id, shift_id: shift&.id, branch_id: branch&.id, shift_rule_profile_id: profile&.id,
          effective_from: Date.current.to_s
        }.merge(extra)
      )
    end

    def expect_rejected(*error_keys)
      expect(response).to have_http_status(:unprocessable_content)
      error_keys.each { |key| expect(response.body).to include(t_error(key)) }
      expect(response.body).not_to include("SecretShiftB", "SecretBranchB", "SecretProfileB")
    end

    before { sign_in owner_a }

    it "1. allows an all-same-business employee, shift, branch and rule profile" do
      expect { create_assignment }.to change(ShiftAssignment, :count).by(1)
      expect(response).to redirect_to(shift_assignments_path)
      expect(ShiftAssignment.order(:id).last).to have_attributes(
        user_id: employee_a.id, shift_id: shift_a.id, branch_id: branch_a.id,
        shift_rule_profile_id: profile_a.id, created_by_id: owner_a.id
      )
    end

    it "1b. allows the same for a manager holding assign_shifts" do
      sign_in manager_a
      expect { create_assignment }.to change(ShiftAssignment, :count).by(1)
      expect(response).to redirect_to(shift_assignments_path)
    end

    it "1c. still allows an assignment without a rule profile (optional)" do
      expect { create_assignment(profile: nil) }.to change(ShiftAssignment, :count).by(1)
    end

    it "2. rejects an employee from another business" do
      expect { create_assignment(user: employee_b) }.not_to change(ShiftAssignment, :count)
      expect_rejected(:employee_not_in_business)
    end

    it "3. rejects a shift from another business" do
      expect { create_assignment(shift: shift_b) }.not_to change(ShiftAssignment, :count)
      expect_rejected(:shift_not_in_business)
    end

    it "4. rejects a branch from another business" do
      expect { create_assignment(branch: branch_b) }.not_to change(ShiftAssignment, :count)
      expect_rejected(:branch_not_in_business)
    end

    it "5. rejects a shift rule profile from another business" do
      expect { create_assignment(profile: profile_b) }.not_to change(ShiftAssignment, :count)
      expect_rejected(:shift_rule_profile_not_in_business)
    end

    describe "6. mixed-business combinations" do
      it "own employee with foreign shift and branch" do
        expect { create_assignment(shift: shift_b, branch: branch_b) }.not_to change(ShiftAssignment, :count)
        expect_rejected(:shift_not_in_business, :branch_not_in_business)
      end

      it "own shift and branch with a foreign rule profile and employee" do
        expect { create_assignment(user: employee_b, profile: profile_b) }.not_to change(ShiftAssignment, :count)
        expect_rejected(:employee_not_in_business, :shift_rule_profile_not_in_business)
      end

      it "everything from the other business" do
        expect { create_assignment(user: employee_b, shift: shift_b, branch: branch_b, profile: profile_b) }
          .not_to change(ShiftAssignment, :count)
        expect_rejected(:employee_not_in_business, :shift_not_in_business, :branch_not_in_business,
                        :shift_rule_profile_not_in_business)
      end
    end

    describe "7. business_id manipulation" do
      it "cannot bypass the checks via shift_assignment[business_id]" do
        expect { create_assignment(shift: shift_b, branch: branch_b, profile: profile_b, extra: { business_id: business_b.id }) }
          .not_to change(ShiftAssignment, :count)
        expect_rejected(:shift_not_in_business)
      end

      it "cannot bypass the checks via a top-level business_id" do
        expect { create_assignment(shift: shift_b, top_level: { business_id: business_b.id }) }
          .not_to change(ShiftAssignment, :count)
        expect_rejected(:shift_not_in_business)
      end

      it "answers a foreign id exactly like a non-existent id (no existence oracle)" do
        create_assignment(shift: shift_b)
        foreign_body = response.body.scan(/<li>.*?<\/li>/)
        create_assignment(extra: { shift_id: 0 })
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body.scan(/<li>.*?<\/li>/)).to eq(foreign_body)
      end
    end

    it "8. keeps the existing permission check (no assign_shifts → Pundit redirect, nothing created)" do
      sign_in employee_a
      expect { create_assignment(shift: shift_b, branch: branch_b, profile: profile_b) }
        .not_to change(ShiftAssignment, :count)
      expect(response).to redirect_to(root_path)
    end

    describe "9. existing validation behaviour" do
      it "still rejects an overlapping same-business assignment via model validation only" do
        create(:shift_assignment, user: employee_a, shift: shift_a, branch: branch_a, effective_from: 1.month.ago.to_date)
        expect { create_assignment }.not_to change(ShiftAssignment, :count)
        expect(response).to have_http_status(:unprocessable_content)
        %i[shift_not_in_business branch_not_in_business shift_rule_profile_not_in_business].each do |key|
          expect(response.body).not_to include(t_error(key))
        end
      end

      it "still leaves a blank shift or branch to the model's own validation" do
        expect { create_assignment(shift: nil, branch: nil) }.not_to change(ShiftAssignment, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).not_to include(t_error(:shift_not_in_business), t_error(:branch_not_in_business))
      end
    end
  end

  # ── bulk_assign_preview ─────────────────────────────────────────────────────
  describe "GET /shift_assignments/bulk_assign_preview" do
    before { sign_in owner_a }

    def preview(shift_id:, extra: {})
      get bulk_assign_preview_shift_assignments_path,
          params: { employee_ids: [ employee_a.id ], shift_id: shift_id, effective_from: Date.current.to_s }.merge(extra),
          as: :json
    end

    # The preview builds assignments without a branch, so the model's branch
    # requirement currently lists every employee under "conflicting" — a
    # pre-existing quirk locked here as-is, not part of this fix.
    def previewed_ids = response.parsed_body.values_at("valid", "conflicting").flatten.map { |row| row["id"] }

    it "10. previews all-same-business resources (output format unchanged)" do
      preview(shift_id: shift_a.id)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys).to match_array(%w[valid conflicting total])
      expect(response.parsed_body["total"]).to eq(1)
      expect(previewed_ids).to eq([ employee_a.id ])
    end

    it "11. treats a foreign shift as not found" do
      preview(shift_id: shift_b.id)
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => "shift_not_found")
    end

    it "12/13. ignores foreign branch and rule profile ids (the preview never reads them)" do
      preview(shift_id: shift_a.id)
      baseline = response.parsed_body
      preview(shift_id: shift_a.id, extra: { branch_id: branch_b.id, shift_rule_profile_id: profile_b.id,
                                             shift_assignment: { branch_id: branch_b.id, shift_rule_profile_id: profile_b.id } })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(baseline)
      expect(ShiftAssignment.count).to eq(0)
    end

    it "14. a foreign shift id is indistinguishable from a non-existent one and leaks nothing" do
      create(:shift_assignment, user: employee_b, shift: shift_b, branch: branch_b) # foreign data that could conflict
      preview(shift_id: shift_b.id)
      foreign = [ response.status, response.body ]
      preview(shift_id: 0)
      expect([ response.status, response.body ]).to eq(foreign)
      expect(foreign.last).not_to include("SecretShiftB")
    end

    it "only previews employees within the caller's scope (unchanged)" do
      get bulk_assign_preview_shift_assignments_path,
          params: { employee_ids: [ employee_a.id, employee_b.id ], shift_id: shift_a.id, effective_from: Date.current.to_s },
          as: :json
      expect(previewed_ids).to eq([ employee_a.id ])
    end
  end

  # ── bulk_assign (the write path the preview feeds) ──────────────────────────
  describe "POST /shift_assignments/bulk_assign" do
    before { sign_in owner_a }

    def bulk_assign(shift_id:, branch_id: nil, employee_ids: [ employee_a.id ])
      post bulk_assign_shift_assignments_path, params: {
        employee_ids: employee_ids,
        shift_assignment: { shift_id: shift_id, branch_id: branch_id, effective_from: Date.current.to_s }
      }
    end

    it "assigns same-business employees to a same-business shift and branch" do
      expect { bulk_assign(shift_id: shift_a.id, branch_id: branch_a.id) }.to change(ShiftAssignment, :count).by(1)
      expect(response).to redirect_to(shift_assignments_path)
      expect(ShiftAssignment.last).to have_attributes(user_id: employee_a.id, shift_id: shift_a.id, branch_id: branch_a.id)
    end

    it "still leaves a blank branch to the model's own validation (nothing created, unchanged)" do
      expect { bulk_assign(shift_id: shift_a.id) }.not_to change(ShiftAssignment, :count)
      expect(response).to redirect_to(shift_assignments_path)
    end

    it "rejects a foreign shift (404, nothing created)" do
      expect { bulk_assign(shift_id: shift_b.id, branch_id: branch_a.id) }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "rejects a foreign branch (404, nothing created)" do
      expect { bulk_assign(shift_id: shift_a.id, branch_id: branch_b.id) }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "never assigns a foreign employee even with valid same-business resources (unchanged)" do
      expect { bulk_assign(shift_id: shift_a.id, branch_id: branch_a.id, employee_ids: [ employee_b.id ]) }
        .not_to change(ShiftAssignment, :count)
    end

    it "keeps the existing permission check" do
      sign_in employee_a
      expect { bulk_assign(shift_id: shift_b.id, branch_id: branch_b.id) }.not_to change(ShiftAssignment, :count)
      expect(response).to redirect_to(root_path)
    end
  end
end
