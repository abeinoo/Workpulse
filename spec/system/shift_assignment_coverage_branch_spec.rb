require "rails_helper"

# Browser coverage for the Assign Shift form's kind switch: Temporary Coverage
# swaps in the coverage-branch field (and its employee list); switching back
# to Regular hides it and clears its value so it is never submitted.
RSpec.describe "Shift assignment coverage branch", type: :system do
  let(:business)       { create(:business, timezone: "Africa/Cairo") }
  let(:manager)        { create(:user, :branch_manager, business: business, preferred_locale: "en") }
  let(:manager_branch) { Branch.find_by!(branch_manager_id: manager.id) }
  let!(:shubra)        { create(:branch, business: business, name: "Shubra") }
  let!(:employee) do
    create(:user, business: business, first_name: "Ahmed", last_name: "Mohamed").tap do |u|
      create(:shift_assignment, user: u, branch: manager_branch,
                                shift: create(:shift, :fixed_time, business: business),
                                effective_from: Date.current - 30)
    end
  end

  let(:coverage_branch) { find("#shift_assignment_branch_id_coverage", visible: :all) }
  let(:regular_branch)  { find("#shift_assignment_branch_id", visible: :all) }

  before do
    manager_branch.update!(name: "Nasr City")
    sign_in manager
    visit new_shift_assignment_path
  end

  it "shows the coverage branch only for Temporary Coverage and clears it on switching back" do
    expect(page).to have_no_field("Coverage Branch")
    expect(page).to have_field("shift_assignment_branch_id")

    select "Temporary Coverage", from: "shift_assignment_assignment_kind"
    expect(page).to have_select("Coverage Branch", options: [ "Select branch —", "Shubra" ])
    expect(page).to have_no_field("shift_assignment_branch_id")

    select "Shubra", from: "Coverage Branch"
    select "Ahmed Mohamed — Current branch: Nasr City", from: "shift_assignment_user_id_coverage"
    expect(page).to have_text("Nasr City → Shubra")

    select "Regular", from: "shift_assignment_assignment_kind"
    expect(page).to have_no_field("Coverage Branch")
    expect(page).to have_no_text("Nasr City → Shubra")
    expect(coverage_branch.value).to eq("")
    expect(coverage_branch).to be_disabled
    expect(regular_branch).not_to be_disabled
  end

  it "does not submit the coverage branch with a regular assignment" do
    select "Temporary Coverage", from: "shift_assignment_assignment_kind"
    select "Shubra", from: "Coverage Branch"
    select "Regular", from: "shift_assignment_assignment_kind"

    submitted = page.evaluate_script(<<~JS)
      new FormData(document.querySelector("form.form-card")).getAll("shift_assignment[branch_id]")
    JS
    expect(submitted).to eq([ "" ])
  end
end
