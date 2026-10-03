require "rails_helper"

# The custody account ledger ("سجل المعاملات") lists the account's FULL
# transaction history, paginated in SQL (newest first, id tie-breaker). It
# used to be capped at the newest 100 rows, which hid older history.
RSpec.describe "Finance::CustodyAccounts#show transaction history", type: :request do
  let(:business) { create(:business, currency: "EGP") }
  let(:owner)    { create(:user, :owner, business: business, preferred_locale: "ar") }
  let(:holder)   { create(:user, business: business) }
  let(:account)  { create(:custody_account, business: business, user: holder) }

  let(:per_page) { Finance::CustodyAccountsController::TRANSACTIONS_PER_PAGE }

  # 120 top-ups (amount n, one per day) from 2026-05-01 → 2026-08-28: more than
  # the old 100-row cap, so the oldest ones (May) used to be invisible.
  let(:count) { 120 }
  let!(:txn_ids) do
    start = Time.zone.local(2026, 5, 1, 10)
    rows = (1..count).map do |n|
      at = start + (n - 1).days
      { business_id: business.id, custody_account_id: account.id, txn_type: "top_up",
        amount: n, notes: "seed #{n}", created_by_id: owner.id, created_at: at, updated_at: at }
    end
    CustodyTransaction.insert_all!(rows, returning: :id).rows.flatten
  end

  def ledger_ids(page = nil)
    get finance_custody_account_path(account, page: page)
    expect(response).to have_http_status(:ok)
    response.body.scan(/id="txn-(\d+)"/).flatten.map(&:to_i)
  end

  def all_pages
    pages = (1..(count.to_f / per_page).ceil).map { |p| ledger_ids(p) }
    [ pages, pages.flatten ]
  end

  before { sign_in owner }

  it "includes transactions older than 2026-08-31 and older than the previous 100-row cap" do
    _, ids = all_pages
    oldest = CustodyTransaction.where(id: txn_ids).order(:created_at).first

    expect(oldest.created_at.to_date).to eq(Date.new(2026, 5, 1))
    expect(ids).to include(oldest.id)
  end

  it "returns PER_PAGE records per page, newest first" do
    page1 = ledger_ids(1)
    expected = CustodyTransaction.where(id: txn_ids).order(created_at: :desc, id: :desc).limit(per_page).pluck(:id)

    expect(page1.size).to eq(per_page)
    expect(page1).to eq(expected)
  end

  it "has strictly older transactions on page 2 than on page 1" do
    page1 = CustodyTransaction.where(id: ledger_ids(1))
    page2 = CustodyTransaction.where(id: ledger_ids(2))

    expect(page2.maximum(:created_at)).to be < page1.minimum(:created_at)
  end

  it "covers the complete history across all pages with no gaps or repeats" do
    pages, ids = all_pages

    expect(pages.map(&:size)).to eq([ 50, 50, 20 ])
    expect(ids).to eq(CustodyTransaction.where(id: txn_ids).order(created_at: :desc, id: :desc).pluck(:id))
  end

  it "breaks timestamp ties deterministically by id (newest id first)" do
    at = Time.zone.local(2026, 9, 1, 12)
    tied = CustodyTransaction.insert_all!(
      [ 1, 2, 3 ].map do |n|
        { business_id: business.id, custody_account_id: account.id, txn_type: "top_up",
          amount: n, created_by_id: owner.id, created_at: at, updated_at: at }
      end,
      returning: :id
    ).rows.flatten

    expect(ledger_ids(1).first(3)).to eq(tied.sort.reverse)
  end

  it "shows the arabic page position and pagination links" do
    get finance_custody_account_path(account, page: 2)

    expect(response.body).to include("الصفحة 2 من 3 · 120 معاملة")
    expect(response.body).to include(I18n.t("pagination.prev", locale: :ar))
    expect(response.body).to include(I18n.t("pagination.next", locale: :ar))
  end

  it "clamps an out-of-range page to the last page" do
    expect(ledger_ids(99)).to eq(ledger_ids(3))
  end

  describe "balances" do
    let(:total) { (1..count).sum } # 7,260

    it "shows the same full-ledger current balance on every page" do
      [ 1, 2, 3 ].each do |page|
        get finance_custody_account_path(account, page: page)
        expect(response.body).to include("7,260.00 ج.م")
      end
    end

    it "starts page 2's running balance after page 1's transactions" do
      # Page 1 holds amounts 120..71 (sum 4,775) → page 2 starts at 2,485.
      get finance_custody_account_path(account, page: 2)
      first_row = response.body[/<tr id="txn-\d+".*?<\/tr>/m]

      expect(first_row).to include("2,485.00 ج.م")
    end

    it "keeps the last-activity date on the newest transaction regardless of page" do
      get finance_custody_account_path(account, page: 3)
      expect(response.body).to include(I18n.l(Date.new(2026, 8, 28), format: :long, locale: :ar))
    end
  end

  describe "authorization" do
    # A regular employee (the default employee balance permissions), with
    # view_employee_balances scoped to self — CustodyAccountPolicy::Scope then
    # limits them to their own account.
    let(:employee_role) do
      create(:permission_role, business: business,
                               permissions: %w[view_employee_balances create_balance_requests],
                               permission_scopes: { "view_employee_balances" => "self" })
    end
    let(:holder) { create(:user, business: business, permission_role: employee_role) }

    it "lets the account holder page through their own full history" do
      sign_in holder
      get finance_custody_account_path(account, page: 3)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("txn-#{txn_ids.first}")
    end

    it "does not show another employee's account, on any page" do
      sign_in create(:user, business: business, permission_role: employee_role)
      get finance_custody_account_path(account, page: 2)

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to match(/<tr id="txn-\d+"/)
      expect(response.body).not_to include("seed 1")
    end

    it "still redirects a user without any finance permission" do
      sign_in create(:user, business: business)
      get finance_custody_account_path(account, page: 2)

      expect(response).to redirect_to(root_path)
    end

    it "does not show an account from another business" do
      sign_in create(:user, :owner, business: create(:business))
      get finance_custody_account_path(account)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "empty history" do
    let(:count) { 0 }
    let!(:txn_ids) { [] }

    it "keeps the empty state and renders no pagination" do
      get finance_custody_account_path(account)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.custody.transactions.empty", locale: :ar))
      expect(response.body).not_to include('class="pagination"')
    end
  end
end
