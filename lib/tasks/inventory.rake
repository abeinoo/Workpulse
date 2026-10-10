namespace :inventory do
  desc <<~DESC
    Normalize goods receipts that were cancelled/voided while their approval was
    still undecided (draft / pending_approval) — they show "awaiting approval"
    next to a "voided" receiving status. Moves approval_status → cancelled (the
    same transition Inventory::GoodsReceiptVoider now performs), one audit row
    each. Nothing else on the receipt changes.

    DRY RUN BY DEFAULT — lists the affected receipts and writes nothing.

    Options (all via ENV):
      APPLY=1          Actually write the changes.
      BUSINESS_ID=42   Restrict to one business.
      ACTOR_ID=7       Audit-log actor. Defaults to the user who voided each receipt.

    Usage:
      bin/rails inventory:normalize_cancelled_goods_receipt_approvals
      bin/rails inventory:normalize_cancelled_goods_receipt_approvals APPLY=1 ACTOR_ID=7
  DESC
  task normalize_cancelled_goods_receipt_approvals: :environment do
    apply  = ENV["APPLY"] == "1"
    actor  = ENV["ACTOR_ID"].presence && User.find(ENV["ACTOR_ID"])
    result = Inventory::GoodsReceiptCancelledApprovalNormalizer
               .new(apply: apply, business_id: ENV["BUSINESS_ID"].presence, actor: actor).call

    puts "[#{apply ? "APPLY" : "DRY RUN"}] #{result.candidates.size} voided goods receipt(s) with an undecided approval status:"
    result.candidates.each do |r|
      puts "  ##{r.id} #{r.receipt_number} business=#{r.business_id} approval=#{r.approval_status_before_type_cast} " \
           "status=#{r.status} voided_at=#{r.voided_at&.iso8601} reason=#{r.void_reason.inspect}"
    end
    puts "---"
    if apply
      puts "Updated: #{result.updated.size}"
      result.failed.each { |r, msg| puts "  FAILED ##{r.id} #{r.receipt_number}: #{msg}" }
    else
      puts "Nothing written. Re-run with APPLY=1 to apply."
    end
  end
end
