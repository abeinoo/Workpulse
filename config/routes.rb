Rails.application.routes.draw do
  devise_for :users, controllers: {
    sessions:      "users/sessions",
    registrations: "users/registrations"
  }, skip: [ :passwords ]

  # ── API (mobile app) ──────────────────────────────────────────────────────
  namespace :api do
    namespace :v1 do
      post   "auth/login",  to: "sessions#create"
      delete "auth/logout", to: "sessions#destroy"

      resources :businesses, only: [ :show, :update ]
      resources :branches
      resources :users do
        resources :salary_profiles, only: [ :index, :show, :create, :update ]
      end
      resources :shifts do
        resources :penalty_rules, only: [ :index, :create, :update, :destroy ]
      end
      resources :shift_assignments

      post "attendance/check_in",  to: "attendance#check_in"
      post "attendance/check_out", to: "attendance#check_out"
      get  "attendance/today",     to: "attendance#today"
      post "attendance/punch",     to: "punches#create"

      resources :attendance_records, only: [ :index, :show, :update ]

      resources :employee_requests, only: [ :index, :show, :create ] do
        member do
          patch :approve
          patch :reject
          patch :pay
          patch :cancel
        end
      end

      resources :advances, only: [ :index, :show ]

      namespace :reports do
        get "payroll/summary", to: "payroll#summary"
        get "payroll/export",  to: "payroll#export"
        get "attendance",      to: "attendance#summary"
      end

      resources :payroll_periods, only: [ :index, :show, :create, :destroy ] do
        member do
          patch :submit_for_review
          patch :approve_all_pending
          patch :finalize
          patch :mark_paid
          patch :regenerate
          patch :reopen
          patch :complete_branch_review
        end
        resources :payroll_entries,     only: [ :index, :show, :update ]
        resources :payroll_adjustments, only: [ :index, :create, :destroy ]
      end

      resources :payroll_line_items, only: [] do
        member do
          patch :approve
          patch :reject
        end
      end
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check

  # ── Super Admin ───────────────────────────────────────────────────────────
  namespace :admin do
    root to: "dashboard#index"

    resource :settings, only: [ :show, :update ]

    resources :users do
      resources :salary_profiles, only: [ :new, :create, :edit, :update ]
      resource  :employee_insurance_profile, only: [ :edit, :update ]
      resource  :password, only: [ :edit, :update ], controller: "user_passwords"
      member do
        patch :transfer_ownership
        patch :toggle_active
      end
    end

    resources :branches

    resources :shifts do
      resources :penalty_rules, only: [ :new, :create, :edit, :update, :destroy ]
    end

    resources :attendance_records, only: [ :index, :show, :update ]

    resources :attendance_imports, only: [ :new, :create, :show ] do
      member do
        patch  :confirm
        delete :cancel
        get    :failed_rows
      end
      collection do
        get :template
      end
    end

    resources :biometric_devices do
      member do
        patch :regenerate_token
      end
    end

    resources :biometric_punch_logs, only: [ :index, :show ]

    resources :permission_roles do
      member do
        post   :assign_user
        delete :remove_user
      end
    end

    resources :employee_obligations, except: [ :destroy ] do
      member do
        patch :pause
        patch :resume
        patch :cancel
        patch :postpone
      end
    end

    resources :shift_templates do
      member do
        patch :archive
        patch :unarchive
        get   :apply
        post  :preview_apply
        post  :apply_confirm
      end
    end

    resources :shift_rule_profiles

    # ── Performance: Department Settings ──────────────────────────────────
    resources :departments, except: [ :show ]
    resources :job_titles,  only: [ :index, :new, :create, :edit, :update ]
    resources :evaluation_templates
  end

  # ── Standalone Adjustments (pre-payroll, manager creates / admin approves) ─
  resources :adjustments, only: [ :index, :show, :new, :create, :edit, :update, :destroy ] do
    collection do
      post :bulk_approve
      post :bulk_reject
    end
    member do
      patch :approve
      patch :reject
    end
  end

  # ── Bulk Adjustments (multi-row entry + CSV import) ──────────────────────
  resource :bulk_adjustments, only: [] do
    get  :new,            path: "new"
    post :create,         path: "new"
    get  :import,         path: "import"
    post :preview_import, path: "import/preview"
    post :confirm_import, path: "import/confirm"
    get  :template,       path: "import/template"
  end

  # ── Branch Manager + Employee (shared web routes) ─────────────────────────
  resources :shifts,            only: [ :show ]
  resources :shift_assignments, only: [ :index, :new, :create, :edit, :update, :destroy ] do
    member do
      get   :confirm_end
      patch :end
      get   :confirm_delete
    end
    collection do
      patch  :bulk_end
      delete :bulk_delete
      post   :bulk_assign
      get    :bulk_assign_preview
    end
  end

  post "attendance/check_in",  to: "attendance#check_in",  as: :attendance_check_in
  post "attendance/check_out", to: "attendance#check_out", as: :attendance_check_out

  resources :attendance_records, only: [ :index, :show, :new, :create, :edit, :update, :destroy ] do
    collection do
      get  :bulk
      post :bulk_create,     path: "bulk"
      get  :import,          path: "import"
      post :preview_import,  path: "import/preview"
      post :confirm_import,  path: "import/confirm"
      get  :import_template, path: "import/template"
    end
  end

  resources :employee_requests, only: [ :index, :new, :create, :show ] do
    collection do
      patch :mark_all_paid
      patch :bulk_pay
    end
    member do
      patch :approve
      patch :reject
      patch :pay
      patch :cancel
    end
  end

  # Employee data submission ("طلب إضافة موظف") — personal data + ID photos
  # only; employment configuration happens on the employee after approval.
  resources :employee_data_requests, only: [ :index, :new, :create, :show, :edit, :update ] do
    member do
      patch :correct
      patch :approve
      patch :reject
      patch :request_changes
      get   "documents/:side", action: :document, as: :document, constraints: { side: /front|back/ }
    end
  end

  get  "payroll_dashboard",    to: "payroll_dashboard#index",    as: :payroll_dashboard
  get  "operations_dashboard", to: "operations_dashboard#index", as: :operations_dashboard

  resources :payroll_periods, only: [ :index, :show, :new, :create, :destroy ] do
    member do
      patch :submit_for_review
      patch :complete_branch_review
      patch :request_changes
      patch :resubmit_for_review
      patch :finalize
      patch :mark_paid
      patch :regenerate
      patch :approve_all_pending
      patch :adjust_overtime
      patch :waive_deductions
      patch :mark_all_reviewed
      patch :reopen
      get   :export_bank_transfer
      get   :recalculate_overtime_preview
      patch :recalculate_overtime
    end
    resources :payroll_entries, only: [ :show ] do
      member do
        patch :override_overtime
        patch :mark_reviewed
      end
      resources :payroll_line_items, only: [] do
        member do
          patch :approve
          patch :reject
          patch :waive_deduction
          patch :restore_deduction
          patch :cancel_addition
        end
      end
      resources :payroll_adjustments, only: [ :new, :create ]
    end
    resources :payroll_adjustments, only: [ :destroy ] do
      member do
        patch :approve
        patch :reject
      end
    end
  end

  patch "preferences/locale", to: "preferences#update", as: :user_locale
  patch "locale", to: "locale#update", as: :set_locale

  # Marks today's birthday celebration as seen (shown once per business day).
  resource :birthday_celebration, only: :create

  # ── Profile (employee self-service) ───────────────────────────────────────
  namespace :profile do
    resource :password, only: [ :edit, :update ]
  end

  # ── Till (cashier workflow) ───────────────────────────────────────────────
  # DEPRECATED: my_shift was the old standalone cashier landing page.
  # All till operations now flow through Daily Reconciliation (/finance/daily_reconciliations).
  # Route kept for backward compatibility (bookmarks); no longer linked in the UI.
  get "my_shift", to: "till_handovers#my_shift", as: :my_shift

  resources :opening_floats, only: %i[new create]

  resources :till_handovers, only: %i[new create show] do
    member do
      patch :accept
      patch :cancel
      patch :reject
      get   :reverse_form
      patch :reverse
      get   :new_adjustment
      post  :create_adjustment
    end
  end

  resources :deposit_responsibility_transfers, only: %i[show create] do
    member do
      patch :accept
      patch :cancel
      get   :reject_form
      patch :reject
    end
  end

  resources :till_refunds, only: %i[new create]

  resources :till_deposits, only: %i[new create show] do
    member do
      patch :void
      get   :manual_match_modal
      patch :manual_match
      get   :ignore_modal
      patch :ignore
      patch :unignore
    end
  end

  # ── Inventory Management ──────────────────────────────────────────────────
  namespace :inventory do
    root to: "dashboard#index"

    resources :warehouses
    resources :suppliers
    resources :brands,             except: [ :show ]
    resources :product_categories, except: [ :show ]
    resources :products do
      collection do
        get  :import
        post :run_import, path: "import"
        get  :import_template
        get  :next_barcode_code
      end
      member do
        post  :generate_barcode
        get   :children
        patch :archive
        patch :restore
        patch :archive_family
      end
    end
    resources :barcode_labels, only: [ :index, :show ]
    resources :purchase_requests, only: [ :index, :show, :new, :create, :edit, :update, :destroy ] do
      collection do
        post :bulk_approve
      end
      member do
        post :submit
        post :approve
        post :reject
        post :cancel
        post :close_remaining
      end
      resources :advances, only: [ :new, :create ], controller: "purchase_request_advances" do
        member do
          post :confirm
          post :cancel
          post :reverse
        end
      end
    end
    resources :goods_receipts,  only: [ :index, :show, :new, :create, :edit, :update ] do
      member do
        patch :void
        patch :cancel
        post  :confirm
        post  :submit
        post  :approve
        post  :reject
      end
      resources :settlements, only: [ :new, :create ], controller: "goods_receipt_settlements" do
        member do
          patch :reverse
        end
      end
    end
    resources :stock_issues,   only: [ :index, :show, :new, :create, :edit, :update, :destroy ] do
      member do
        patch :void
        patch :cancel
        post  :submit
        post  :approve
        post  :reject
        post  :confirm
      end
      collection do
        get  :import
        post :preview_import, path: "import/preview"
        post :run_import, path: "import"
        get  :import_template
      end
    end
    # Draft import batches from a stock-issue CSV import — not nested under a
    # single stock_issue, since a batch's whole purpose is holding rows that
    # never made it into one.
    resources :stock_issue_import_batches, only: [ :show ] do
      patch :complete, on: :member
      resources :rows, only: [], controller: "stock_issue_import_rows" do
        member do
          patch :resolve
          patch :skip
        end
      end
    end
    resources :stock_transfers, only: [ :index, :show, :new, :create ] do
      member { patch :void }
    end
    resources :stock_adjustments, only: [ :index, :show, :new, :create ] do
      member { patch :void }
    end
    resources :stock_counts do
      member do
        patch :complete
        patch :approve
        patch :reopen
        get   :export
        get   :import
        patch :run_import, path: "import"
      end
    end

    # Workspace landing page for configuration screens (categories, brands).
    get "settings", to: "settings#show", as: :settings
    # Warehouse → branch supply links (reporting relationship; stock stays with the warehouse).
    resources :warehouse_supplies, only: [ :index, :update ]

    # Shared barcode → product lookup for scanner-enabled document forms.
    get "barcode_lookup", to: "barcode_lookups#show", as: :barcode_lookup

    # ── Reports ──────────────────────────────────────────────────────────
    get "reports",                    to: "reports#index",              as: :reports
    get "reports/current_stock",      to: "reports#current_stock",      as: :current_stock_report
    get "reports/movements",          to: "reports#movements",          as: :movements_report
    get "reports/movements/export",   to: "reports#export_movements",   as: :movements_report_export
    get "reports/supplier_purchases", to: "reports#supplier_purchases", as: :supplier_purchases_report
    get "reports/low_stock",          to: "reports#low_stock",          as: :low_stock_report
    get "reports/no_movement",        to: "reports#no_movement",        as: :no_movement_report
    get "reports/branch_comparison",  to: "reports#branch_comparison",  as: :branch_comparison_report
    get "reports/branch_comparison/export", to: "reports#export_branch_comparison", as: :branch_comparison_report_export
    get "reports/consumption",        to: "reports#consumption",        as: :consumption_report
    get "reports/transfers",          to: "reports#transfers",          as: :transfers_report
    get "reports/adjustments",        to: "reports#adjustments",        as: :adjustments_report
    get "reports/purchases",          to: "reports#purchases",          as: :purchases_report
  end

  # ── Financial Operations & Expense Management ─────────────────────────────
  namespace :finance do
    root to: "dashboard#index"
    get "dashboard/export_pdf", to: "dashboard#export_pdf", as: :dashboard_export_pdf

    resources :expenses do
      member do
        patch :submit
        patch :approve
        patch :reject
        patch :cancel
      end
      resources :payments, only: [ :new, :create ], controller: "expense_payments"
    end

    resources :balance_requests do
      member do
        patch :submit
        patch :approve
        patch :reject
        patch :mark_paid
        patch :cancel
      end
    end

    resources :payment_methods, except: [ :show ] do
      member do
        patch :move_up
        patch :move_down
      end
    end

    resources :expense_categories, except: [ :show ]
    resources :expense_types, except: [ :show ] do
      collection { get :options, defaults: { format: :json } }
    end
    resources :expense_tags,       except: [ :show ]

    resources :recurring_expenses do
      member { post :generate }
    end

    # ── Reports & Branch Profitability ────────────────────────────────────
    get "reports",                      to: "reports#index",                as: :reports
    get "reports/expenses_by_branch",   to: "reports#expenses_by_branch",   as: :expenses_by_branch_report
    get "reports/expenses_by_category", to: "reports#expenses_by_category", as: :expenses_by_category_report
    get "reports/expenses_by_type",     to: "reports#expenses_by_type",     as: :expenses_by_type_report
    get "reports/expense_trend",        to: "reports#expense_trend",        as: :expense_trend_report
    get "reports/shared_allocation",    to: "reports#shared_allocation",    as: :shared_allocation_report
    get "reports/recurring",            to: "reports#recurring",            as: :recurring_report
    get "reports/custody_balances",     to: "reports#custody_balances",     as: :custody_balances_report
    get "reports/custody_transactions", to: "reports#custody_transactions", as: :custody_transactions_report
    get "reports/negative_balances",    to: "reports#negative_balances",    as: :negative_balances_report
    get "reports/approvals",            to: "reports#approvals",            as: :approvals_report
    get "reports/branch_profitability", to: "reports#branch_profitability", as: :branch_profitability_report
    get "reports/expense_details",      to: "reports#expense_details",      as: :expense_details_report

    resources :custody_accounts do
      resources :custody_transactions, only: [ :create ] do
        member { patch :void }
      end
    end

    resources :daily_reconciliations, only: %i[index show new create] do
      member do
        patch :verify
        patch :assign_depositor
        get   :transfer_deposit_responsibility
        get   :edit_opening_float
        patch :update_opening_float_amounts
        post  :receive_opening_float
        get   :edit_session_totals
        patch :update_session_totals
        get   :edit_day_close_amounts
        patch :update_day_close_amounts
        get   :correct_opening_float
        patch :update_opening_float_correction
      end
      collection do
        post :bulk_receive_opening_float
        post :bulk_settle
        get  :export
      end
    end

    resources :sales_imports, only: %i[index show new create destroy] do
      member do
        get   :edit_column_mapping
        patch :update_column_mapping
        get   :preview_import
        post  :confirm_import
      end
    end

    resources :pos_imports, only: %i[index show new create destroy] do
      member do
        get  :preview_import
        post :confirm_import
        post :ignore_row
      end
    end

    resources :remaining_deposit_balances, only: %i[show] do
      member do
        patch :settle
        patch :write_off
        patch :reassign
      end
    end

    resources :bank_disputes, only: %i[new create show] do
      member do
        patch :submit_to_bank
        patch :start_investigation
        patch :refund
        patch :confirm_successful
        patch :reject
        patch :close
        patch :update_case
        patch :confirm_deposit
      end
    end

    # ── Deposit Verification ──────────────────────────────────────────────────
    resources :bank_statements do
      collection do
        get :sample_csv
      end
      member do
        get   :edit_column_mapping
        patch :update_column_mapping
        get   :preview_import
        post  :confirm_import
        post  :rematch
      end
    end

    resources :bank_statement_transactions, only: %i[show] do
      member do
        get   :manual_match_modal
        patch :match
        patch :unmatch
        patch :ignore
      end
    end

    resources :deposit_verifications, only: %i[index]
  end

  # ── Laundry Operations ─────────────────────────────────────────────────────
  namespace :laundry do
    root to: "dashboard#index"

    resources :towel_types, except: [ :show ] do
      resources :standard_cost_rates, only: %i[new create]
    end

    resources :towel_transfers, only: %i[index show new create] do
      member do
        # NOTE: not named `dispatch` — that's ActionController::Metal's core
        # routing method; overriding it with a same-named action breaks every
        # action on the controller, not just this one.
        patch :mark_dispatched
        patch :receive
        patch :cancel
      end
    end

    resources :laundry_batches, only: %i[index show new create] do
      member do
        patch :start
        patch :complete
        patch :reverse
      end
      resources :consumptions, only: [ :create ], controller: "laundry_batch_consumptions"
    end

    resources :towel_adjustments, only: %i[index new create]

    get "balances", to: "towel_balances#index", as: :towel_balances

    # NOTE: laundry material consumption is NOT recorded here — the existing
    # Inventory Stock Issue workflow (inventory/stock_issues) is the single
    # source of truth. See Finance::Reports::LaundryCostSummary.

    # NOTE: standard washing-cost rates are managed per towel type, nested
    # under towel_types above — there is no standalone rate-management page.

    namespace :reports do
      get "branch_consumption", to: "branch_consumption#index"
      get "cost_summary",       to: "cost_summary#index"
    end
  end

  # ── Performance Evaluation ────────────────────────────────────────────────
  namespace :performance do
    root to: "dashboard#index"

    resources :observations do
      collection { get :criteria_options }
    end
    resources :reviews do
      collection do
        get :employee_summary
        get :export_xlsx
        get :export_pdf
        get "employee_summary/export_xlsx", action: :employee_summary_export_xlsx, as: :employee_summary_export_xlsx
        get "employee_summary/export_pdf",  action: :employee_summary_export_pdf,  as: :employee_summary_export_pdf
      end
      member do
        patch :submit
        patch :finalize
      end
    end

    get "reports",       to: "reports#index", as: :reports
    get "reports/trend", to: "reports#trend", as: :trend_report
  end

  # ── Root ──────────────────────────────────────────────────────────────────
  root to: "dashboard#index"
end
