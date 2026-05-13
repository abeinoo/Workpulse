require "rails_helper"

RSpec.describe Users::RegistrationService do
  subject(:result) do
    described_class.call(login: login, password: password,
                         password_confirmation: password_confirmation)
  end

  let(:password)              { "password123" }
  let(:password_confirmation) { "password123" }

  describe ".call" do
    context "when no user matches the login" do
      let(:login) { "+966500000000" }

      it { is_expected.not_to be_success }
      it { expect(result.error).to eq("No account found for that phone number or email.") }
      it { expect { result }.not_to change(User, :count) }
    end

    context "when a user exists with no password (pre-created by admin) — phone login" do
      let!(:user) { create(:user, :phone_only, :unregistered, phone_number: "+966501234567") }
      let(:login) { "+966501234567" }

      it { is_expected.to be_success }
      it { expect(result.error).to be_nil }

      it "sets the password on the existing user" do
        expect { result }.not_to change(User, :count)
        expect(user.reload.encrypted_password).to be_present
      end
    end

    context "when a user exists with no password — email login" do
      let!(:user) { create(:user, :unregistered, email: "sara@workpulse.com") }
      let(:login) { "sara@workpulse.com" }

      it { is_expected.to be_success }
    end

    context "when email login is provided in uppercase" do
      let!(:user) { create(:user, :unregistered, email: "ahmed@workpulse.com") }
      let(:login) { "AHMED@WORKPULSE.COM" }

      it { is_expected.to be_success }
    end

    context "when the user already has a password (already registered)" do
      let!(:user) { create(:user, :phone_only, phone_number: "+966501111111") }
      let(:login) { "+966501111111" }

      it { is_expected.not_to be_success }
      it { expect(result.error).to eq("This account has already been registered.") }
      it { expect { result }.not_to change(User, :count) }
    end

    context "when password confirmation does not match" do
      let!(:user)                 { create(:user, :phone_only, :unregistered, phone_number: "+966502222222") }
      let(:login)                 { "+966502222222" }
      let(:password_confirmation) { "different_password" }

      it { is_expected.not_to be_success }
      it { expect { result }.not_to change(User, :count) }
    end

    context "when password is too short" do
      let!(:user)    { create(:user, :phone_only, :unregistered, phone_number: "+966503333333") }
      let(:login)    { "+966503333333" }
      let(:password) { "short" }
      let(:password_confirmation) { "short" }

      it { is_expected.not_to be_success }
    end
  end
end
