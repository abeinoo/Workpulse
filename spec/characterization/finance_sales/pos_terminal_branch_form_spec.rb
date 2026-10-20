require "rails_helper"

# Characterization (Pilot 12 — POS terminals write boundary, M1) — CURRENT
# writes of Finance & Sales PosTerminal rows through the Organization & Access
# branch form (module-boundaries.md §14.2 #8): Branch's nested
# pos_terminals_attributes (reject_if: blank terminal_id, allow_destroy) saved by
# Admin::BranchesController#create / #update. Gaps G1–G3, G5, G7 and G8 of
# next-pilot-selection.md §27.8; G4 (markup) is in
# pos_terminal_branch_form_markup_spec.rb, G6 (branch destroy) in
# spec/characterization/organization_access/branches_and_settings_spec.rb.
#
# Requests that end in a rescued 404 are kept one per example.
RSpec.describe "Characterization: POS terminals through the branch form", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:manager)  { api_user_with(business, :manage_branches) }

  let!(:branch)           { create(:branch, business: business, name: "Main") }
  let!(:terminal)         { create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-A", label: "Front") }
  let!(:sibling_branch)   { create(:branch, business: business, name: "Sibling") }
  let!(:sibling_terminal) { create(:pos_terminal, business: business, branch: sibling_branch, terminal_id: "TERM-S") }
  let!(:foreign_terminal) { create(:pos_terminal, business: other, terminal_id: "TERM-F") }

  # rows and attributes are positional hashes: a brace-less `"0" => { … }` call
  # must reach `rows`, not be taken as keywords.
  def update_branch(rows, attributes = {})
    patch admin_branch_path(branch), params: { branch: { name: "Main" }.merge(attributes).merge(pos_terminals_attributes: rows) }
  end

  def create_branch(rows, attributes = {})
    post admin_branches_path, params: { branch: { name: "New", branch_type: "sales" }.merge(attributes).merge(pos_terminals_attributes: rows) }
  end

  def resolve(terminal_id)
    row = Finance::PosImports::Mapper::MappedRow.new(
      row_number: 1, attributes: { transaction_id: "TXN-1", amount: "10.00", terminal_id: terminal_id }
    )
    Finance::PosImports::BranchResolver.call([ row ], business: business)
  end

  def terminal_rows = PosTerminal.order(:id).pluck(:business_id, :branch_id, :terminal_id, :label, :active)

  describe "G1 — authorization (BranchPolicy, manage_branches)" do
    # view_employees passes Admin::BaseController's admin gate; BranchPolicy then refuses.
    let(:viewer) { api_user_with(business, :view_employees) }

    before { sign_in viewer }

    it "refuses an update carrying terminal rows: redirect to root, nothing written" do
      expect {
        update_branch({ "0" => { id: terminal.id, terminal_id: "TERM-X", label: "Changed" },
                        "1" => { terminal_id: "TERM-NEW" },
                        "2" => { id: sibling_terminal.id, _destroy: "1" } }, name: "Renamed")
      }.not_to(change { terminal_rows })

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
      expect(branch.reload.name).to eq("Main")
    end

    it "refuses a create carrying terminal rows: redirect to root, no branch and no terminal" do
      expect { create_branch("0" => { terminal_id: "TERM-NEW" }) }
        .not_to(change { [ Branch.count, terminal_rows ] })

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
    end
  end

  describe "with manage_branches" do
    before { sign_in manager }

    describe "G2 — nested ids resolve only inside the branch" do
      it "returns 404 for a sibling branch's terminal id (edit) and changes nothing" do
        expect { update_branch({ "0" => { id: sibling_terminal.id, terminal_id: "HIJACK" } }, name: "Renamed") }
          .not_to(change { terminal_rows })

        expect(response).to have_http_status(:not_found)
        expect(branch.reload.name).to eq("Main")
      end

      it "returns 404 for a sibling branch's terminal id (_destroy) and keeps it" do
        update_branch("0" => { id: sibling_terminal.id, _destroy: "1" })

        expect(response).to have_http_status(:not_found)
        expect(PosTerminal).to exist(sibling_terminal.id)
      end

      it "returns 404 for another business's terminal id and changes nothing" do
        expect { update_branch("0" => { id: foreign_terminal.id, terminal_id: "HIJACK", label: "X" }) }
          .not_to(change { terminal_rows })

        expect(response).to have_http_status(:not_found)
      end
    end

    describe "G3 — one save: branch and terminals succeed or fail together" do
      it "adds, edits and removes terminals with a branch change in a single update" do
        extra = create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-B")

        update_branch({ "0" => { id: terminal.id, terminal_id: "TERM-A", label: "Desk" },
                        "1" => { terminal_id: "TERM-C", label: "New", active: "1" },
                        "2" => { id: extra.id, _destroy: "1" } }, name: "Renamed")

        expect(response).to redirect_to(admin_branch_path(branch))
        expect(flash[:notice]).to eq(I18n.t("flash.branch_updated"))
        expect(branch.reload.name).to eq("Renamed")
        expect(PosTerminal).not_to exist(extra.id)
        expect(branch.pos_terminals.order(:terminal_id).pluck(:business_id, :terminal_id, :label, :active))
          .to eq([ [ business.id, "TERM-A", "Desk", true ], [ business.id, "TERM-C", "New", true ] ])
      end

      it "saves neither the branch change nor any terminal when one terminal is invalid (422)" do
        expect {
          update_branch({ "0" => { id: terminal.id, terminal_id: "TERM-A", label: "Desk" },
                          "1" => { terminal_id: "TERM-OK" },
                          "2" => { terminal_id: "TERM-S" } }, name: "Renamed")
        }.not_to(change { terminal_rows })

        expect(response).to have_http_status(:unprocessable_entity)
        expect(branch.reload.name).to eq("Main")
        expect(response.body).to include("<li>Pos terminals terminal has already been taken</li>")
      end

      it "saves no terminal when the branch itself is invalid (422)" do
        expect {
          update_branch({ "0" => { id: terminal.id, terminal_id: "TERM-A", label: "Desk" }, "1" => { terminal_id: "TERM-OK" } }, name: "")
        }.not_to(change { terminal_rows })

        expect(response).to have_http_status(:unprocessable_entity)
        expect(branch.reload.name).to eq("Main")
      end

      it "saves nothing when branch_type is unsupported (re-render, 422)" do
        expect {
          update_branch({ "0" => { id: terminal.id, terminal_id: "TERM-A", label: "Desk" }, "1" => { terminal_id: "TERM-OK" } },
                        branch_type: "nonsense")
        }.not_to(change { terminal_rows })

        expect(response).to have_http_status(:unprocessable_entity)
        expect(branch.reload.branch_type).to eq("sales")
      end

      it "creates a branch with its terminals, business taken from the branch" do
        expect { create_branch("0" => { terminal_id: "TERM-N1", label: "One" }, "1" => { terminal_id: "TERM-N2" }) }
          .to change(Branch, :count).by(1)

        created = Branch.find_by!(name: "New")
        expect(response).to redirect_to(admin_branch_path(created))
        expect(created.pos_terminals.order(:terminal_id).pluck(:business_id, :terminal_id, :label, :active))
          .to eq([ [ business.id, "TERM-N1", "One", true ], [ business.id, "TERM-N2", nil, true ] ])
      end

      it "creates neither the branch nor any terminal when a terminal is invalid (422)" do
        expect { create_branch("0" => { terminal_id: "TERM-N1" }, "1" => { terminal_id: "TERM-A" }) }
          .not_to(change { [ Branch.count, terminal_rows ] })

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    describe "G5 — row rejection (reject_if: blank terminal_id), active flag, resolution" do
      it "ignores a new row whose terminal_id is blank, even with a label" do
        expect { update_branch("0" => { terminal_id: "", label: "Only a label", active: "1" }) }
          .not_to(change { terminal_rows })

        expect(response).to redirect_to(admin_branch_path(branch))
      end

      it "ignores an all-blank new row (the form's unused added row)" do
        expect { update_branch("0" => { terminal_id: "", label: "", active: "0" }) }
          .not_to(change { terminal_rows })

        expect(response).to redirect_to(admin_branch_path(branch))
      end

      # D-P12-5: reject_if also applies to an existing row without _destroy — the
      # whole row is silently ignored (its label change included), not an error.
      it "ignores an existing row submitted with a blank terminal_id (label change dropped, no error)" do
        expect { update_branch("0" => { id: terminal.id, terminal_id: "", label: "Changed", active: "0" }) }
          .not_to(change { terminal_rows })

        expect(response).to redirect_to(admin_branch_path(branch))
      end

      # Same rule when the key is missing: attrs["terminal_id"].blank? is true, so a
      # row with only an id and a label is dropped. (The form always submits
      # terminal_id, so this matters only to hand-built requests.)
      it "ignores an existing row that omits terminal_id (label-only change dropped, no error)" do
        expect { update_branch("0" => { id: terminal.id, label: "Changed", active: "0" }) }
          .not_to(change { terminal_rows })

        expect(response).to redirect_to(admin_branch_path(branch))
      end

      it "still destroys an existing row submitted with a blank terminal_id and _destroy" do
        update_branch("0" => { id: terminal.id, terminal_id: "", _destroy: "1" })

        expect(response).to redirect_to(admin_branch_path(branch))
        expect(PosTerminal).not_to exist(terminal.id)
      end

      it "keeps a row whose _destroy is \"0\"" do
        update_branch("0" => { id: terminal.id, terminal_id: "TERM-A", label: "Kept", _destroy: "0" })

        expect(terminal.reload.label).to eq("Kept")
      end

      it "persists the active checkbox both ways" do
        update_branch("0" => { id: terminal.id, terminal_id: "TERM-A", active: "0" })
        expect(terminal.reload.active).to be(false)

        update_branch("0" => { id: terminal.id, terminal_id: "TERM-A", active: "1" })
        expect(terminal.reload.active).to be(true)
      end
    end

    describe "G7 — terminal changes are NOT audited (existing behaviour)" do
      it "writes no AuditLog row for adding, editing or removing terminals" do
        extra = create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-B")

        expect {
          update_branch("0" => { id: terminal.id, terminal_id: "TERM-A", label: "Desk" },
                        "1" => { terminal_id: "TERM-C" },
                        "2" => { id: extra.id, _destroy: "1" })
        }.not_to change(AuditLog, :count)
        expect(response).to redirect_to(admin_branch_path(branch))
      end

      it "writes no AuditLog row for a branch created with terminals" do
        expect { create_branch("0" => { terminal_id: "TERM-N1" }) }.not_to change(AuditLog, :count)
        expect(response).to have_http_status(:redirect)
      end
    end

    describe "G8 — a form change is what the POS import resolves next" do
      it "resolves a terminal added through the form to that branch" do
        expect(resolve("TERM-NEW").unknown_terminals.size).to eq(1)

        update_branch("0" => { terminal_id: "TERM-NEW" })

        expect(resolve("TERM-NEW").resolved_rows.map { |r| r.attributes[:branch_id] }).to eq([ branch.id ])
      end

      it "stops resolving a terminal renamed, deactivated or removed through the form" do
        expect(resolve("TERM-A").resolved_rows.size).to eq(1)

        update_branch("0" => { id: terminal.id, terminal_id: "TERM-A2" })
        expect(resolve("TERM-A").unknown_terminals.size).to eq(1)
        expect(resolve("TERM-A2").resolved_rows.map { |r| r.attributes[:branch_id] }).to eq([ branch.id ])

        update_branch("0" => { id: terminal.id, terminal_id: "TERM-A2", active: "0" })
        expect(resolve("TERM-A2").unknown_terminals.size).to eq(1)

        update_branch("0" => { id: terminal.id, _destroy: "1" })
        expect(PosTerminal).not_to exist(terminal.id)
        expect(resolve("TERM-A2").unknown_terminals.size).to eq(1)
      end
    end
  end
end
