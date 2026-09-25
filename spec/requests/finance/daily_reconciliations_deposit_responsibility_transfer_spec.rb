require "rails_helper"

# "Transfer Deposit Responsibility" on the DR page — a manager REQUESTS a
# transfer (a pending DepositResponsibilityTransfer, the same record Day Close
# creates); the recipient must accept (or may reject) before TillSession's
# depositor changes.
RSpec.describe "Finance::DailyReconciliations — Transfer Deposit Responsibility", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business, name: "Nasr City") }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms, **attrs)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business, **attrs).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # Plain cashiers: no view_daily_reconciliation — they reach the DR page only
  # through their own session (holder/depositor/pending recipient).
  def cashier(**attrs) = user_with("close_till_session", "create_till_deposit", **attrs)

  let(:manager)  { user_with("view_daily_reconciliation", "verify_daily_reconciliation", first_name: "Sara", last_name: "Manager") }
  let(:viewer)   { user_with("view_daily_reconciliation") }
  let!(:ahmed)   { cashier(first_name: "Ahmed",   last_name: "Bahaa") }
  let!(:mohamed) { cashier(first_name: "Mohamed", last_name: "Ahmed") }
  let!(:mahmoud) { cashier(first_name: "Mahmoud", last_name: "Saeed") }
  let!(:inactive_cashier) { cashier(first_name: "Inactive", last_name: "Cashier", active: false) }
  let!(:no_deposit_perm)  { user_with("close_till_session", first_name: "NoDeposit", last_name: "Perm") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 2.hours.ago, closed_at: 1.hour.ago, business_date: Date.current
    )
  end
  let!(:session) { TillSession.create!(daily_reconciliation: dr, depositor: ahmed, closed_by: ahmed) }
  let!(:amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 1_000, refund_amount: 0)
  end

  let(:t_scope)    { "finance.daily_reconciliations.transfer_deposit" }
  let(:dr_path)    { finance_daily_reconciliation_path(dr) }
  let(:modal_path) { transfer_deposit_responsibility_finance_daily_reconciliation_path(dr) }

  def doc = Nokogiri::HTML(response.body)

  def request_transfer!(to:, expected: ahmed, as: manager, notes: nil)
    sign_in as
    post deposit_responsibility_transfers_path,
         params: { daily_reconciliation_id: dr.id, to_user_id: to.id, expected_depositor_id: expected.id, notes: notes }
  end

  def pending_transfer = dr.deposit_responsibility_transfers.pending.sole

  def timeline(key, **opts) = I18n.t("finance.daily_reconciliations.show.timeline.#{key}", **opts)

  describe "manager initiates" do
    it "shows the current depositor and the transfer action to an authorized manager" do
      sign_in manager
      get dr_path

      card = doc.at_css("#deposit-responsibility-card")
      expect(card.at_css("#deposit-responsibility-name").text).to include("Ahmed Bahaa")
      expect(card.at_css("#transfer-deposit-responsibility-button")["href"]).to eq(modal_path)
      expect(card.at_css("#deposit-responsibility-pending")).to be_nil
    end

    it "hides the action from users without verify_daily_reconciliation, including the depositor" do
      [ viewer, ahmed ].each do |user|
        sign_in user
        get dr_path
        expect(doc.at_css("#deposit-responsibility-name").text).to include("Ahmed Bahaa")
        expect(doc.at_css("#transfer-deposit-responsibility-button")).to be_nil
      end
    end

    it "lists only active deposit-capable employees, never the current depositor or the manager" do
      manager.permission_role.update!(permissions: manager.permission_role.permissions + %w[close_till_session create_till_deposit])
      sign_in manager
      get modal_path

      names = doc.css("select#deposit-transfer-depositor option").map { |o| o.text.strip }
      expect(names).to include("Mohamed Ahmed", "Mahmoud Saeed")
      expect(names).not_to include("Ahmed Bahaa", "Sara Manager", "Inactive Cashier", "NoDeposit Perm")
      form = doc.at_css("form#deposit-transfer-form")
      expect(form["action"]).to eq(deposit_responsibility_transfers_path)
      expect(form.at_css("input[name='daily_reconciliation_id']")["value"]).to eq(dr.id.to_s)
      expect(form.at_css("#deposit-transfer-submit")["disabled"]).to be_present
    end

    it "creates a pending transfer and does NOT change the depositor" do
      request_transfer!(to: mohamed, notes: "Ahmed on leave")

      expect(response).to redirect_to(dr_path)
      expect(flash[:notice]).to eq(I18n.t("deposit_responsibility_transfers.requested", name: "Mohamed Ahmed"))
      expect(session.reload.depositor).to eq(ahmed)
      expect(pending_transfer).to have_attributes(from_user: ahmed, to_user: mohamed, initiated_by: manager,
                                                  notes: "Ahmed on leave")
    end

    it "shows the pending state on the card and in the timeline, with the old depositor still current" do
      request_transfer!(to: mohamed)
      get dr_path

      card = doc.at_css("#deposit-responsibility-card")
      expect(card.at_css("#deposit-responsibility-name").text).to include("Ahmed Bahaa")
      pending = card.at_css("#deposit-responsibility-pending")
      expect(pending.text).to include(I18n.t("#{t_scope}.pending_badge"))
      expect(pending.text).to include("Mohamed Ahmed")
      expect(card.at_css("#transfer-deposit-responsibility-button")).to be_nil
      expect(response.body).to include(timeline(:deposit_transfer_requested,
                                                from: "Ahmed Bahaa", to: "Mohamed Ahmed", actor: "Sara Manager"))
    end

    it "refuses a second request while one is pending" do
      request_transfer!(to: mohamed)
      request_transfer!(to: mahmoud)

      expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.deposit_transfer_already_pending"))
      expect(dr.deposit_responsibility_transfers.count).to eq(1)

      get modal_path
      expect(doc.at_css("form#deposit-transfer-form")).to be_nil
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.errors.deposit_transfer_already_pending"))
    end

    it "refuses unauthorized requesters, including the current depositor" do
      [ viewer, ahmed ].each do |user|
        request_transfer!(to: mohamed, as: user)
        expect(response).to redirect_to(root_path)
      end
      expect(dr.deposit_responsibility_transfers).to be_empty
    end

    it "refuses a verified day" do
      dr.update!(state: "verified", verified_at: Time.current, verified_by_id: manager.id)
      request_transfer!(to: mohamed)
      expect(response).to redirect_to(root_path)
      expect(dr.deposit_responsibility_transfers).to be_empty
    end
  end

  describe "current depositor while pending" do
    it "still sees themself as responsible, keeps Record Deposit, and sees who must accept" do
      request_transfer!(to: mohamed)
      sign_in ahmed
      get dr_path

      expect(doc.at_css("#deposit-responsibility-name").text).to include(I18n.t("#{t_scope}.you_badge"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.deposit_transfer_waiting_title",
                                              name: "Mohamed Ahmed"))
      expect(response.body).to include(new_till_deposit_path(daily_reconciliation_id: dr.id))
    end
  end

  describe "recipient" do
    before { request_transfer!(to: mohamed) }

    it "can open the DR (without view_daily_reconciliation) and sees the request card with both actions" do
      sign_in mohamed
      get dr_path

      expect(response).to have_http_status(:ok)
      card = doc.at_css("#deposit-transfer-request-card")
      expect(card.text).to include(I18n.t("finance.daily_reconciliations.show.deposit_request.title"))
      expect(card.text).to include("Ahmed Bahaa", "Sara Manager", "Nasr City")
      expect(card.at_css("#deposit-request-accept")["href"]).to eq(deposit_responsibility_transfer_path(pending_transfer))
      expect(card.at_css("#deposit-request-reject")["href"]).to eq(reject_form_deposit_responsibility_transfer_path(pending_transfer))
      # Opening the page accepts nothing.
      expect(session.reload.depositor).to eq(ahmed)
      expect(response.body).not_to include(new_till_deposit_path(daily_reconciliation_id: dr.id))
    end

    it "is taken there by My Shift" do
      sign_in mohamed
      get my_shift_path
      expect(response).to redirect_to(dr_path)
    end

    it "sees the accept confirmation step before anything changes" do
      sign_in mohamed
      get deposit_responsibility_transfer_path(pending_transfer)

      expect(doc.text).to include(I18n.t("deposit_responsibility_transfers.show.confirm_accept"))
      expect(doc.at_css("#deposit-accept-submit")["value"]).to eq(I18n.t("deposit_responsibility_transfers.show.accept_submit"))
      expect(session.reload.depositor).to eq(ahmed)
    end

    it "becomes the depositor only after accepting; the old depositor sees it moved" do
      transfer = pending_transfer
      sign_in mohamed
      patch accept_deposit_responsibility_transfer_path(transfer)

      expect(flash[:notice]).to eq(I18n.t("deposit_responsibility_transfers.accepted"))
      expect(session.reload.depositor).to eq(mohamed)
      expect(transfer.reload.accepted_by).to eq(mohamed)

      get dr_path
      expect(doc.at_css("#deposit-responsibility-name").text).to include("Mohamed Ahmed")
      expect(response.body).to include(new_till_deposit_path(daily_reconciliation_id: dr.id))
      expect(response.body).to include(timeline(:deposit_accepted, name: "Mohamed Ahmed"))

      sign_in ahmed
      get dr_path
      expect(doc.at_css("#deposit-responsibility-name").text).to include("Mohamed Ahmed")
      expect(doc.at_css("#deposit-responsibility-moved").text).to include("Mohamed Ahmed")
      expect(response.body).not_to include(new_till_deposit_path(daily_reconciliation_id: dr.id))
    end

    it "can reject with a reason; the old depositor stays and a new request becomes possible" do
      transfer = pending_transfer
      sign_in mohamed
      get reject_form_deposit_responsibility_transfer_path(transfer)
      expect(response.body).to include(I18n.t("deposit_responsibility_transfers.reject.confirm"))

      patch reject_deposit_responsibility_transfer_path(transfer), params: { rejection_reason: "I'm off tomorrow" }
      expect(flash[:notice]).to eq(I18n.t("deposit_responsibility_transfers.rejected"))
      expect(session.reload.depositor).to eq(ahmed)
      expect(transfer.reload).to have_attributes(rejected_by: mohamed, rejection_reason: "I'm off tomorrow")

      sign_in manager
      get dr_path
      expect(response.body).to include(timeline(:deposit_rejected, name: "Mohamed Ahmed"))
      expect(response.body).to include("I&#39;m off tomorrow")
      expect(doc.at_css("#transfer-deposit-responsibility-button")).to be_present

      request_transfer!(to: mahmoud)
      expect(pending_transfer.to_user).to eq(mahmoud)
    end

    it "requires a rejection reason" do
      sign_in mohamed
      patch reject_deposit_responsibility_transfer_path(pending_transfer), params: { rejection_reason: "" }
      expect(flash[:alert]).to eq(I18n.t("deposit_responsibility_transfers.errors.rejection_reason_blank"))
      expect(pending_transfer).to be_pending
    end

    it "gets a clear error when acting on a transfer already answered (second tab)" do
      transfer = pending_transfer
      sign_in mohamed
      patch accept_deposit_responsibility_transfer_path(transfer)
      patch accept_deposit_responsibility_transfer_path(transfer)
      expect(flash[:alert]).to eq(I18n.t("deposit_responsibility_transfers.errors.already_accepted"))

      patch reject_deposit_responsibility_transfer_path(transfer), params: { rejection_reason: "late" }
      expect(flash[:alert]).to eq(I18n.t("deposit_responsibility_transfers.errors.already_accepted"))
      expect(session.reload.depositor).to eq(mohamed)
    end

    it "cannot accept once the day is verified — the server re-checks" do
      dr.update!(state: "verified", verified_at: Time.current, verified_by_id: manager.id)
      sign_in mohamed
      patch accept_deposit_responsibility_transfer_path(pending_transfer)
      expect(response).to redirect_to(root_path)
      expect(session.reload.depositor).to eq(ahmed)
    end
  end

  describe "non-recipients" do
    before { request_transfer!(to: mohamed) }

    it "cannot accept or reject — not the depositor, another cashier, nor the requesting manager" do
      transfer = pending_transfer
      [ ahmed, mahmoud, manager ].each do |user|
        sign_in user
        patch accept_deposit_responsibility_transfer_path(transfer)
        expect(response).to redirect_to(root_path)
        patch reject_deposit_responsibility_transfer_path(transfer), params: { rejection_reason: "x" }
        expect(response).to redirect_to(root_path)
      end
      expect(transfer.reload).to be_pending
      expect(session.reload.depositor).to eq(ahmed)
    end

    it "do not see the recipient request card" do
      [ ahmed, manager ].each do |user|
        sign_in user
        get dr_path
        expect(doc.at_css("#deposit-transfer-request-card")).to be_nil
      end
    end
  end

  describe "full history" do
    it "keeps request, acceptance and rejection events across repeated transfers" do
      request_transfer!(to: mohamed)
      sign_in mohamed
      patch accept_deposit_responsibility_transfer_path(pending_transfer)

      # The new depositor's responsibility can be transferred on again.
      request_transfer!(to: mahmoud, expected: mohamed)
      sign_in mahmoud
      patch reject_deposit_responsibility_transfer_path(pending_transfer), params: { rejection_reason: "Not today" }

      request_transfer!(to: ahmed, expected: mohamed)
      sign_in ahmed
      patch accept_deposit_responsibility_transfer_path(pending_transfer)
      expect(session.reload.depositor).to eq(ahmed)

      sign_in manager
      get dr_path
      [
        timeline(:deposit_transfer_requested, from: "Ahmed Bahaa",   to: "Mohamed Ahmed", actor: "Sara Manager"),
        timeline(:deposit_accepted, name: "Mohamed Ahmed"),
        timeline(:deposit_transfer_requested, from: "Mohamed Ahmed", to: "Mahmoud Saeed", actor: "Sara Manager"),
        timeline(:deposit_rejected, name: "Mahmoud Saeed"),
        "Not today",
        timeline(:deposit_transfer_requested, from: "Mohamed Ahmed", to: "Ahmed Bahaa",   actor: "Sara Manager"),
        timeline(:deposit_accepted, name: "Ahmed Bahaa")
      ].each { |text| expect(response.body).to include(text) }
      expect(dr.deposit_responsibility_transfers.count).to eq(3)
    end
  end

  describe "Day Close accept flow (unchanged)" do
    it "still lets the named colleague accept a Day Close transfer" do
      transfer = DepositResponsibilityTransfer.create!(daily_reconciliation: dr, from_user: ahmed, to_user: mahmoud)
      sign_in mahmoud
      get dr_path
      expect(doc.at_css("#deposit-transfer-request-card").text).to include("Ahmed Bahaa")

      patch accept_deposit_responsibility_transfer_path(transfer)
      expect(session.reload.depositor).to eq(mahmoud)

      sign_in manager
      get dr_path
      expect(response.body).to include(timeline(:deposit_assigned, actor: "Ahmed Bahaa", name: "Mahmoud Saeed"))
    end
  end
end
