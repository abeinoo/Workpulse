require "rails_helper"

# Characterization (Department + JobTitle pilot, M1 gap DJ3) — the CURRENT
# JobTitle catalogue contract consumed by the employee form and onboarding
# dropdown (JobTitle.options_for) and by User#job_title_from_catalog
# (JobTitle.selectable?, decision D-WF1). The User validation itself is
# characterized in spec/models/user_job_title_spec.rb; admin list/create/
# deactivate, duplicates, authorization and isolation in
# spec/requests/admin/job_titles_spec.rb — not repeated here.
RSpec.describe "Characterization: JobTitle catalogue", type: :model do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }

  describe "normalization and validation" do
    it "trims and collapses whitespace and is unique per business, case-insensitively" do
      expect(JobTitle.create!(business: business, name: "  Head   Stylist ").name).to eq("Head Stylist")
      duplicate = JobTitle.new(business: business, name: "HEAD STYLIST")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors.details[:name]).to include(a_hash_including(error: :taken))
      expect(JobTitle.new(business: other, name: "Head Stylist")).to be_valid
    end

    it "requires a name of at most 100 characters" do
      expect(JobTitle.new(business: business, name: " ")).not_to be_valid
      expect(JobTitle.new(business: business, name: "x" * 101)).not_to be_valid
    end
  end

  describe ".options_for (dropdown source)" do
    before do
      JobTitle.create!(business: business, name: "Stylist")
      JobTitle.create!(business: business, name: "Manager")
      JobTitle.create!(business: business, name: "Retired Role", active: false)
      JobTitle.create!(business: other, name: "Foreign Role")
    end

    it "lists only the business's active titles, ordered by name" do
      expect(JobTitle.options_for(business)).to eq(%w[Manager Stylist])
    end

    it "prepends the current value when it is no longer offered (so editing never drops it)" do
      expect(JobTitle.options_for(business, current: "Retired Role")).to eq([ "Retired Role", "Manager", "Stylist" ])
      expect(JobTitle.options_for(business, current: "Legacy Free Text")).to eq([ "Legacy Free Text", "Manager", "Stylist" ])
    end

    it "does not prepend a current value that matches an active title case-insensitively, or a blank one" do
      expect(JobTitle.options_for(business, current: "STYLIST")).to eq(%w[Manager Stylist])
      expect(JobTitle.options_for(business, current: "")).to eq(%w[Manager Stylist])
    end
  end

  describe ".selectable? (used by User#job_title_from_catalog, D-WF1)" do
    before do
      JobTitle.create!(business: business, name: "Stylist")
      JobTitle.create!(business: business, name: "Retired Role", active: false)
      JobTitle.create!(business: other, name: "Foreign Role")
    end

    it "is true for an active title of the business, case-insensitively" do
      expect(JobTitle.selectable?(business.id, "stylist")).to be(true)
    end

    it "is false for inactive, foreign, unknown and blank values" do
      expect(JobTitle.selectable?(business.id, "Retired Role")).to be(false)
      expect(JobTitle.selectable?(business.id, "Foreign Role")).to be(false)
      expect(JobTitle.selectable?(business.id, "Unknown")).to be(false)
      expect(JobTitle.selectable?(business.id, nil)).to be(false)
    end

    # Existing behaviour: the lookup does not trim, so a padded value does not match.
    it "does not match a value with surrounding whitespace (existing behaviour)" do
      expect(JobTitle.selectable?(business.id, " Stylist ")).to be(false)
    end
  end
end
