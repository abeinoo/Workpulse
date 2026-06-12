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
          patch :waive
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
  end

  # ── Standalone Adjustments (pre-payroll, manager creates / admin approves) ─
  resources :adjustments, only: [ :index, :show, :new, :create, :destroy ] do
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

  resources :attendance_records, only: [ :index, :show, :new, :create, :edit, :update ] do
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
    end
  end

  get  "payroll_dashboard",    to: "payroll_dashboard#index",    as: :payroll_dashboard
  get  "operations_dashboard", to: "operations_dashboard#index", as: :operations_dashboard

  resources :payroll_periods, only: [ :index, :show, :new, :create, :destroy ] do
    member do
      patch :submit_for_review
      patch :complete_branch_review
      patch :finalize
      patch :mark_paid
      patch :regenerate
      patch :approve_all_pending
      patch :adjust_overtime
      patch :waive_deductions
      patch :reopen
      get   :export_bank_transfer
    end
    resources :payroll_entries, only: [ :show ] do
      member do
        patch :override_overtime
      end
      resources :payroll_line_items, only: [] do
        member do
          patch :approve
          patch :reject
          patch :waive
          patch :waive_deduction
          patch :restore_deduction
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

  # ── Profile (employee self-service) ───────────────────────────────────────
  namespace :profile do
    resource :password, only: [ :edit, :update ]
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
      end
    end
    resources :goods_receipts,  only: [ :index, :show, :new, :create ] do
      member { patch :void }
    end
    resources :stock_issues,    only: [ :index, :show, :new, :create ] do
      member { patch :void }
      collection do
        get  :import
        post :run_import, path: "import"
        get  :import_template
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

    # Shared barcode → product lookup for scanner-enabled document forms.
    get "barcode_lookup", to: "barcode_lookups#show", as: :barcode_lookup

    # ── Reports ──────────────────────────────────────────────────────────
    get "reports",                    to: "reports#index",              as: :reports
    get "reports/current_stock",      to: "reports#current_stock",      as: :current_stock_report
    get "reports/movements",          to: "reports#movements",          as: :movements_report
    get "reports/supplier_purchases", to: "reports#supplier_purchases", as: :supplier_purchases_report
  end

  # ── Root ──────────────────────────────────────────────────────────────────
  root to: "dashboard#index"
end
