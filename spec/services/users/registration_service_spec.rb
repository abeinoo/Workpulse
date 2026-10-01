require "rails_helper"

# Account activation ("claim") of a pre-created, passwordless account.
# Since OA-S6 a claim requires the administrator-issued invitation token AND
# the account's phone/email; every failure returns one generic message.
RSpec.describe Users::RegistrationService do
  subject(:result) do
    described_class.call(login: login, password: password,
                         password_confirmation: password_confirmation,
                         invitation_token: token)
  end

  let(:password)              { "password123" }
  let(:password_confirmation) { "password123" }
  let(:generic_error)         { I18n.t("auth.register.invalid_invitation") }

  def invitation_for(user) = user.generate_token_for(:account_claim)

  describe "with a valid invitation" do
    context "phone login" do
      let!(:user) { create(:user, :phone_only, :unregistered, phone_number: "+966501234567") }
      let(:login) { "+966501234567" }
      let(:token) { invitation_for(user) }

      it { is_expected.to be_success }
      it { expect(result.error).to be_nil }

      it "sets the password on the existing user" do
        expect { result }.not_to change(User, :count)
        expect(user.reload.encrypted_password).to be_present
      end

      it "accepts the phone number in another format that normalizes to the same value" do
        expect(described_class.call(login: "+966 50 123 4567", password: password,
                                    password_confirmation: password, invitation_token: token)).to be_success
      end
    end

    context "email login" do
      let!(:user) { create(:user, :unregistered, email: "sara@workpulse.com") }
      let(:login) { "sara@workpulse.com" }
      let(:token) { invitation_for(user) }

      it { is_expected.to be_success }
    end

    context "email login in uppercase" do
      let!(:user) { create(:user, :unregistered, email: "ahmed@workpulse.com") }
      let(:login) { "AHMED@WORKPULSE.COM" }
      let(:token) { invitation_for(user) }

      it { is_expected.to be_success }
    end

    context "when password confirmation does not match" do
      let!(:user)                 { create(:user, :phone_only, :unregistered, phone_number: "+966502222222") }
      let(:login)                 { "+966502222222" }
      let(:token)                 { invitation_for(user) }
      let(:password_confirmation) { "different_password" }

      it { is_expected.not_to be_success }
      it { expect { result }.not_to change { user.reload.encrypted_password } }
    end

    context "when password is too short" do
      let!(:user)    { create(:user, :phone_only, :unregistered, phone_number: "+966503333333") }
      let(:login)    { "+966503333333" }
      let(:token)    { invitation_for(user) }
      let(:password) { "short" }
      let(:password_confirmation) { "short" }

      it { is_expected.not_to be_success }
    end
  end

  describe "OA-S6: knowing the phone/email is not enough" do
    let!(:user) { create(:user, :phone_only, :unregistered, phone_number: "+966504444444") }
    let(:login) { "+966504444444" }

    shared_examples "a refused claim" do
      it "fails with the generic message and leaves the account unclaimed" do
        expect(result).not_to be_success
        expect(result.error).to eq(generic_error)
        expect(user.reload.encrypted_password).to be_blank
      end
    end

    context "without an invitation token" do
      let(:token) { nil }
      it_behaves_like "a refused claim"
    end

    context "with a forged token" do
      let(:token) { "not-a-real-token" }
      it_behaves_like "a refused claim"
    end

    context "with another employee's invitation" do
      let(:token) { invitation_for(create(:user, :phone_only, :unregistered)) }
      it_behaves_like "a refused claim"
    end

    context "with a valid token but a different phone number" do
      let(:token) { invitation_for(user) }
      let(:login) { "+966509999999" }
      it_behaves_like "a refused claim"
    end

    context "with an expired invitation" do
      let(:token) { invitation_for(user) }

      it "is refused after 7 days" do
        token
        travel 8.days do
          expect(result).not_to be_success
          expect(result.error).to eq(generic_error)
        end
      end
    end

    context "for a deactivated account" do
      let(:token) { invitation_for(user) }
      before { token && user.update!(active: false) }
      it_behaves_like "a refused claim"
    end

    it "cannot be reused once the account is claimed" do
      token = invitation_for(user)
      expect(described_class.call(login: login, password: password, password_confirmation: password,
                                  invitation_token: token)).to be_success
      second = described_class.call(login: login, password: "another123", password_confirmation: "another123",
                                    invitation_token: token)
      expect(second).not_to be_success
      expect(user.reload.valid_password?(password)).to be(true)
    end
  end

  describe "OA-S6: no account enumeration" do
    let(:token) { nil }

    it "answers an unknown login, an unclaimed account and a registered account identically" do
      create(:user, :phone_only, :unregistered, phone_number: "+966505555555")
      create(:user, :phone_only, phone_number: "+966506666666")

      errors = [ "+966500000000", "+966505555555", "+966506666666" ].map do |login|
        described_class.call(login: login, password: password, password_confirmation: password,
                             invitation_token: nil).error
      end
      expect(errors.uniq).to eq([ generic_error ])
    end
  end

  describe "invitation token contents" do
    it "does not embed the password digest (checked on a registered account)" do
      user = create(:user)
      expect(user.encrypted_password).to start_with("$2a$")
      message = user.generate_token_for(:account_claim).split("--").first
      payload = Base64.urlsafe_decode64(message + "=" * (-message.length % 4))
      expect(payload).not_to include(user.encrypted_password)
      expect(payload).not_to include("$2a$")
    end
  end
end
