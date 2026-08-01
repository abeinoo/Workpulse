require "rails_helper"

RSpec.describe "Finance::PaymentMethods include_in_pos_verification", type: :request do
  let(:business) { create(:business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:manager) { user_with("manage_payment_methods") }

  it "renders the checkbox on the new form" do
    sign_in manager
    get new_finance_payment_method_path

    expect(response.body).to include(I18n.t("finance.payment_methods.include_in_pos_verification"))
  end

  it "persists include_in_pos_verification: true on create" do
    sign_in manager

    post finance_payment_methods_path, params: {
      payment_method: { name: "Card", settlement_type: "card", active: "1", include_in_pos_verification: "1" }
    }

    expect(PaymentMethod.last.include_in_pos_verification).to be true
  end

  it "defaults to false when the checkbox is left unchecked" do
    sign_in manager

    post finance_payment_methods_path, params: {
      payment_method: { name: "Cash", settlement_type: "cash", active: "1" }
    }

    expect(PaymentMethod.last.include_in_pos_verification).to be false
  end

  it "can be toggled on update" do
    sign_in manager
    pm = PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", include_in_pos_verification: false)

    patch finance_payment_method_path(pm), params: {
      payment_method: { include_in_pos_verification: "1" }
    }

    expect(pm.reload.include_in_pos_verification).to be true
  end
end
