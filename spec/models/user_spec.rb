require "rails_helper"

RSpec.describe User, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:employee).optional }
  end

  describe ".find_for_database_authentication" do
    let!(:employee) { create(:employee, phone_number: "+966050000001", email: "ahmed@example.com") }
    let!(:user)     { create(:user, employee: employee) }

    it "finds the user by phone number" do
      result = User.find_for_database_authentication(login: "+966050000001")
      expect(result).to eq(user)
    end

    it "finds the user by email" do
      result = User.find_for_database_authentication(login: "ahmed@example.com")
      expect(result).to eq(user)
    end

    it "finds the user by email case-insensitively" do
      result = User.find_for_database_authentication(login: "AHMED@EXAMPLE.COM")
      expect(result).to eq(user)
    end

    it "strips leading and trailing whitespace" do
      result = User.find_for_database_authentication(login: "  +966050000001  ")
      expect(result).to eq(user)
    end

    it "returns nil for an unknown login" do
      result = User.find_for_database_authentication(login: "unknown")
      expect(result).to be_nil
    end

    it "returns nil for a blank login" do
      result = User.find_for_database_authentication(login: "")
      expect(result).to be_nil
    end
  end

  describe "#login" do
    let(:employee) { create(:employee, phone_number: "+966050000002") }
    let(:user)     { create(:user, employee: employee) }

    it "defaults to the employee phone number" do
      expect(user.login).to eq("+966050000002")
    end

    it "returns the assigned value when set explicitly" do
      user.login = "custom_input"
      expect(user.login).to eq("custom_input")
    end
  end
end
