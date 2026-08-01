require "rails_helper"

RSpec.describe PosTerminal do
  it "is valid with a terminal_id and a branch in the same business" do
    expect(build(:pos_terminal)).to be_valid
  end

  it "requires a terminal_id" do
    terminal = build(:pos_terminal, terminal_id: nil)
    expect(terminal).not_to be_valid
  end

  it "enforces terminal_id uniqueness scoped to business" do
    business = create(:business)
    create(:pos_terminal, business: business, terminal_id: "TERM-DUP")

    dup = build(:pos_terminal, business: business, terminal_id: "TERM-DUP")
    expect(dup).not_to be_valid
    expect(dup.errors[:terminal_id]).to be_present
  end

  it "allows the same terminal_id across different businesses" do
    create(:pos_terminal, terminal_id: "TERM-SHARED")

    other_business_terminal = build(:pos_terminal, terminal_id: "TERM-SHARED")
    expect(other_business_terminal).to be_valid
  end

  it "rejects a branch belonging to a different business" do
    business       = create(:business)
    other_business = create(:business)
    branch         = create(:branch, business: other_business)

    terminal = build(:pos_terminal, business: business, branch: branch)
    expect(terminal).not_to be_valid
    expect(terminal.errors[:branch]).to be_present
  end

  describe ".active" do
    it "returns only active terminals" do
      active_terminal   = create(:pos_terminal, active: true)
      inactive_terminal = create(:pos_terminal, active: false)

      expect(described_class.active).to include(active_terminal)
      expect(described_class.active).not_to include(inactive_terminal)
    end
  end
end
