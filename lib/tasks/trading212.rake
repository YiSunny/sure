namespace :trading212 do
  desc "Review an exact positive cashback credit allocated to Pie cash (no entries or sync)"
  task review_cashback: :environment do
    abort "Set CONFIRM_FUNDING_REVIEW=yes only with independent funding evidence" unless ENV["CONFIRM_FUNDING_REVIEW"] == "yes"
    provider = Trading212Account.cash.find(ENV.fetch("PROVIDER_ACCOUNT_ID"))
    Trading212Account::CashbackAllocation.new(provider).review!(reference: ENV.fetch("CASHBACK_REFERENCE"),
      evidence: ENV.fetch("FUNDING_EVIDENCE"), actor: User.find(ENV.fetch("ACTOR_ID")))
    puts "Cashback allocation review saved. No entries changed or synchronization started."
  end

  desc "Record an exact, independently reviewed trade funding allocation (no sync or entries)"
  task review_settlement: :environment do
    abort "Set CONFIRM_FUNDING_REVIEW=yes only with independent funding evidence" unless ENV["CONFIRM_FUNDING_REVIEW"] == "yes"
    provider = Trading212Account.portfolio.find(ENV.fetch("PROVIDER_ACCOUNT_ID"))
    Trading212Account::Settlement.new(provider).review!(reference: ENV.fetch("FILL_REFERENCE"), cash_amount: ENV.fetch("CASH_AMOUNT"),
      evidence: ENV.fetch("FUNDING_EVIDENCE"), actor: User.find(ENV.fetch("ACTOR_ID")), funding_type: ENV.fetch("FUNDING_TYPE", "cash_and_pie"))
    puts "Funding review saved. No entries changed and synchronization was not started."
  end

  desc "Preview a same-owner duplicate manual account archival (read only)"
  task archive_preview: :environment do
    archive = Trading212Account::LegacyArchive.new(Trading212Account.find(ENV.fetch("PROVIDER_ACCOUNT_ID")),
      legacy_account: Account.find(ENV.fetch("LEGACY_ACCOUNT_ID")), user: User.find(ENV.fetch("ACTOR_ID")))
    puts JSON.pretty_generate(archive.preview)
  end

  desc "Archive a reviewed duplicate manual account without deleting its entries"
  task archive: :environment do
    abort "Set CONFIRM_ARCHIVE=yes after backup and transfer review" unless ENV["CONFIRM_ARCHIVE"] == "yes"
    archive = Trading212Account::LegacyArchive.new(Trading212Account.find(ENV.fetch("PROVIDER_ACCOUNT_ID")),
      legacy_account: Account.find(ENV.fetch("LEGACY_ACCOUNT_ID")), user: User.find(ENV.fetch("ACTOR_ID")))
    archive.apply!
    puts "Duplicate account preserved, disabled and excluded from financial reports."
  end

  desc "Validate a stored summary and preview Cash/Portfolio migration (read only)"
  task split_preview: :environment do
    provider = Trading212Account.find(ENV.fetch("PROVIDER_ACCOUNT_ID"))
    user = User.find(ENV.fetch("ACTOR_ID"))
    preview = Trading212Account::Splitter.new(provider, user: user).preview
    puts JSON.pretty_generate(preview)
  end

  desc "Apply an explicitly confirmed, previously reviewed Cash/Portfolio split"
  task split: :environment do
    abort "Set CONFIRM_SPLIT=yes after backup, restore test and split_preview" unless ENV["CONFIRM_SPLIT"] == "yes"
    provider = Trading212Account.find(ENV.fetch("PROVIDER_ACCOUNT_ID"))
    user = User.find(ENV.fetch("ACTOR_ID"))
    cash = Trading212Account::Splitter.new(provider, user: user).apply!
    puts JSON.pretty_generate(portfolio_provider_id: provider.id, cash_provider_id: cash.id,
      cash_account_id: cash.current_account.id, synchronization_started: false)
  end

  desc "Preview a history CSV against a split Cash account without applying entries"
  task statement_preview: :environment do
    provider = Trading212Account.cash.find(ENV.fetch("PROVIDER_ACCOUNT_ID"))
    user = User.find(ENV.fetch("ACTOR_ID"))
    content = File.binread(ENV.fetch("CSV_PATH"), Import::MAX_CSV_SIZE + 1)
    statement = provider.trading212_statements.new(user: user,
      checksum: Digest::SHA256.hexdigest(content), rows: Trading212Statement::Parser.new(content).parse)
    statement.authorize!(user)
    result = statement.preview_result
    # Do not dump merchants/references/notes into terminal logs.
    puts JSON.pretty_generate(matched: result[:matched].size, skipped: result[:skipped].size,
      conflicts: result[:conflicts], coverage_start: result[:coverage_start], coverage_end: result[:coverage_end])
  end
end
