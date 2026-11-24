module Inventory
  # THE operation-permission rule for Stock Issues — used by StockIssuePolicy
  # (screens) and by every Stock Issue workflow service (so a console, job or
  # any other caller is held to the same rule). One permission per operation:
  #
  #   view    view_stock_issues      (independent of view_inventory)
  #   create  create_stock_issues    (create, edit, submit, import, delete a draft)
  #   approve approve_stock_issues   (approve / reject)
  #   confirm confirm_stock_issues   (confirm = post the stock deduction)
  #   cancel  cancel_stock_issues    (an issue not yet posted)
  #   void    void_stock_issues      (reverse a posted issue)
  #   quick_issue quick_issue_stock  (the Quick Issue workflow)
  #
  # manage_stock_issues grants nothing any more (replaced by
  # create_stock_issues; never copied to the new keys).
  #
  # Transition: manage_inventory is still honoured for every Stock Issue
  # operation, exactly as before, until its removal and the role migration
  # are approved — no saved role silently loses or gains access here.
  #
  # The owner holds every permission (User#can?). Permissions never grant
  # warehouse access; that is a separate check every operation also needs
  # (Inventory::IssueWarehouseReach / Inventory::WarehouseReach).
  module StockIssueAuthorization
    # Raised by services that treat a missing permission as a misuse (the
    # importer); the workflow step services return a failed Result instead.
    class Denied < StandardError; end

    PERMISSIONS = {
      view:        "view_stock_issues",
      create:      "create_stock_issues",
      approve:     "approve_stock_issues",
      confirm:     "confirm_stock_issues",
      cancel:      "cancel_stock_issues",
      void:        "void_stock_issues",
      quick_issue: "quick_issue_stock"
    }.freeze

    TRANSITIONAL_UMBRELLA = "manage_inventory".freeze

    # The workflow steps the trusted Quick Issue flow drives through the
    # standard services (submission is part of :create).
    QUICK_ISSUE_STEPS = %i[create approve confirm].freeze

    module_function

    def permits?(actor, operation)
      key = PERMISSIONS.fetch(operation)
      return false if actor.nil?

      actor.can?(key) || actor.can?(TRANSITIONAL_UMBRELLA)
    end

    # The check each workflow step service runs. A normal caller passes no
    # context and is held to the standard permission. The Quick Issue flow
    # passes its private context instead (see Inventory::StockIssueQuickIssue):
    # it is accepted only by identity — any other object is refused, never
    # treated as standard — and only for the Quick Issue steps, and it still
    # requires the actor to be allowed to use Quick Issue. It replaces only
    # this permission check; warehouse reach, business isolation,
    # locks, availability and audit are never delegated to it.
    def step_permitted?(actor, operation, context: nil)
      return permits?(actor, operation) if context.nil?

      StockIssueQuickIssue.trusted_context?(context) &&
        QUICK_ISSUE_STEPS.include?(operation) &&
        StockIssueQuickIssue.permitted?(actor)
    end

    def message
      I18n.t("inventory.stock_issues.errors.not_permitted")
    end
  end
end
