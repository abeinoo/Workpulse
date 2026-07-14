require "rails_helper"

RSpec.describe "Laundry towel transfer — status-gated visibility and lifecycle", type: :request do
  let(:business) { create(:business) }
  let(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms,
                                              permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:staff) do
    user_with("view_towel_balances", "create_towel_transfers", "confirm_towel_receipt",
              scopes: { "view_towel_balances" => "business", "create_towel_transfers" => "business",
                       "confirm_towel_receipt" => "business" })
  end

  # A user with laundry permissions but scoped to a branch that is neither the
  # source nor the destination of the transfers under test.
  let(:outside_branch) { create(:branch, business: business, branch_type: "sales") }
  let(:outside_user) do
    u = user_with("view_towel_balances", "create_towel_transfers", "confirm_towel_receipt")
    outside_branch.update!(branch_manager_id: u.id)
    u
  end

  let(:no_access_user) { create(:user, business: business) }

  def build_transfer(quantity: 100)
    business.towel_transfers.create!(towel_type: towel_type, source_branch: sales_branch,
                                     destination_branch: laundry_branch, towel_status: "dirty",
                                     declared_quantity: quantity)
  end

  def balances
    Laundry::TowelBalances.new(towel_type)
  end

  def fund(branch, status, quantity)
    Laundry::TowelAdjuster.new(actor: staff).call(
      towel_type: towel_type, branch: branch, status: status, adjustment_quantity: quantity, reason: "test setup"
    )
  end

  describe "draft status" do
    let(:transfer) { build_transfer }

    it "shows Dispatch and Cancel, but not the Confirm Receipt form" do
      sign_in staff
      get laundry_towel_transfer_path(transfer)

      expect(response.body).to include(I18n.t("laundry.towel_transfers.actions.dispatch"))
      expect(response.body).to include(I18n.t("laundry.towel_transfers.actions.cancel"))
      expect(response.body).not_to include(I18n.t("laundry.towel_transfers.receive_hint"))
    end

    it "rejects a direct receive attempt on a draft transfer (server-side, not just hidden in the UI)" do
      sign_in staff
      patch receive_laundry_towel_transfer_path(transfer), params: { confirmed_quantity: 100 }

      expect(transfer.reload).to be_draft
      expect(transfer.confirmed_quantity).to be_nil
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(0)
    end
  end

  describe "dispatched status" do
    let(:transfer) { build_transfer }

    before do
      fund(sales_branch, "clean", 100)
      Laundry::TowelTransferCreator.new(transfer).dispatch(actor: staff)
    end

    it "hides Dispatch, shows the In Transit state, and shows Confirm Receipt with source/destination/declared quantity" do
      sign_in staff
      get laundry_towel_transfer_path(transfer.reload)

      expect(response.body).not_to include(mark_dispatched_laundry_towel_transfer_path(transfer))
      expect(response.body).to include(I18n.t("laundry.towel_transfers.statuses.dispatched")) # "In Transit"
      expect(response.body).to include(I18n.t("laundry.towel_transfers.receive_hint"))
      expect(response.body).to include(sales_branch.name)
      expect(response.body).to include(laundry_branch.name)
      expect(response.body).to include("100") # declared quantity
    end

    it "does not expose the Confirm Receipt form to a user outside the destination branch's scope" do
      sign_in outside_user
      get laundry_towel_transfer_path(transfer.reload)

      expect(response.body).not_to include(I18n.t("laundry.towel_transfers.receive_hint"))
    end

    it "rejects a second dispatch attempt (cannot dispatch twice), server-side" do
      sign_in staff
      patch mark_dispatched_laundry_towel_transfer_path(transfer.reload)

      expect(transfer.reload).to be_dispatched
      expect(TowelLedgerEntry.where(source: transfer, reason: "towel_transfer_dispatch").count).to eq(1)
    end

    it "denies dispatch/receive to a user without the laundry permissions entirely" do
      sign_in no_access_user
      get laundry_root_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "receiving with a discrepancy" do
    let(:transfer) { build_transfer(quantity: 100) }

    before do
      fund(sales_branch, "clean", 100)
      Laundry::TowelTransferCreator.new(transfer).dispatch(actor: staff)
    end

    it "adds only the confirmed quantity to the destination balance, preserves the declared quantity, and surfaces the discrepancy" do
      sign_in staff
      patch receive_laundry_towel_transfer_path(transfer.reload), params: { confirmed_quantity: 98 }

      transfer.reload
      expect(transfer).to be_received
      expect(transfer.declared_quantity).to eq(100) # never silently modified
      expect(transfer.confirmed_quantity).to eq(98)
      expect(transfer.discrepancy).to eq(2)
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(98) # only the confirmed amount entered the ledger

      get laundry_towel_transfer_path(transfer)
      expect(response.body).to include(I18n.t("laundry.towel_transfers.discrepancy"))
    end

    it "rejects a direct over-receipt request even with a valid, authorized session — the HTML max attribute is not the enforcement" do
      sign_in staff

      patch receive_laundry_towel_transfer_path(transfer.reload), params: { confirmed_quantity: 105 }

      transfer.reload
      expect(transfer).to be_dispatched # not received — request was rejected
      expect(transfer.confirmed_quantity).to be_nil
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(0)
      expect(TowelLedgerEntry.where(source: transfer, reason: "towel_transfer_receipt")).to be_empty

      follow_redirect!
      expect(response.body).to include(I18n.t("laundry.towel_transfers.errors.confirmed_exceeds_declared", declared: 100))
    end
  end

  describe "received status" do
    let(:transfer) { build_transfer }

    before do
      fund(sales_branch, "clean", 100)
      Laundry::TowelTransferCreator.new(transfer).dispatch(actor: staff)
      Laundry::TowelTransferCreator.new(transfer.reload).receive(actor: staff, confirmed_quantity: 100)
    end

    it "hides Dispatch, Cancel, and Confirm Receipt, showing only the completed summary" do
      sign_in staff
      get laundry_towel_transfer_path(transfer.reload)

      expect(response.body).not_to include(mark_dispatched_laundry_towel_transfer_path(transfer))
      expect(response.body).not_to include(cancel_laundry_towel_transfer_path(transfer))
      expect(response.body).not_to include(I18n.t("laundry.towel_transfers.receive_hint"))
      expect(response.body).to include(I18n.t("laundry.towel_transfers.statuses.received"))
    end

    it "rejects receiving an already-received transfer a second time (server-side)" do
      sign_in staff
      patch receive_laundry_towel_transfer_path(transfer.reload), params: { confirmed_quantity: 100 }

      # Balance must not be double-counted.
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(100)
      expect(TowelLedgerEntry.where(source: transfer, reason: "towel_transfer_receipt").count).to eq(1)
    end

    it "rejects a cancel attempt on an already-received transfer (server-side)" do
      sign_in staff
      patch cancel_laundry_towel_transfer_path(transfer.reload), params: { cancellation_reason: "too late" }

      expect(transfer.reload).to be_received
    end
  end

  describe "unauthorized access to a specific transfer" do
    let(:transfer) { build_transfer }

    # This transfer's branches fall entirely outside outside_user's managed
    # scope, so TowelTransferPolicy::Scope excludes it before authorize even
    # runs — the record 404s rather than surfacing a Pundit redirect. Either
    # way the action never executes.
    it "cannot dispatch a transfer outside their branch scope" do
      sign_in outside_user
      patch mark_dispatched_laundry_towel_transfer_path(transfer)

      expect(response).to have_http_status(:not_found)
      expect(transfer.reload).to be_draft
    end

    it "cannot receive a transfer outside their branch scope" do
      fund(sales_branch, "clean", 100)
      Laundry::TowelTransferCreator.new(transfer).dispatch(actor: staff)

      sign_in outside_user
      patch receive_laundry_towel_transfer_path(transfer.reload), params: { confirmed_quantity: 100 }

      expect(response).to have_http_status(:not_found)
      expect(transfer.reload).to be_dispatched
    end
  end
end
