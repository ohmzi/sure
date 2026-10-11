namespace :paperless do
  desc "Ensure the least-privilege ingest integration user exists and mint (or reuse) its API key"
  task ensure_ingest_user: :environment do
    email = Ingest::PaperlessController::INTEGRATION_EMAIL
    family = Family.order(:created_at).first or abort("No family exists; create the household first.")

    user = User.find_or_initialize_by(email: email)
    if user.new_record?
      user.assign_attributes(first_name: "Paperless", last_name: "Ingest", role: "member",
                             family: family, onboarded_at: Time.current, ui_layout: "intro")
      user.password = SecureRandom.hex(32) # random; never disclosed
      user.save!
      puts "Created integration user #{email}"
    end

    existing = user.api_keys.active.find_by(name: "paperless-ingest")
    if existing
      puts "An active 'paperless-ingest' key already exists (id=#{existing.id}); not minting a new one."
      next
    end

    plain = ApiKey.generate_secure_key
    key = user.api_keys.create!(name: "paperless-ingest", scopes: [ "read_write" ], source: "monitoring", key: plain)
    puts "Minted API key id=#{key.id}. COPY IT NOW — it is not shown again:"
    puts key.plain_key
  end

  desc "Enqueue an OCR-text snapshot for every settled document link that has none (re-runnable)"
  task backfill_extracted_text: :environment do
    scope = DocumentLink.where.not(paperless_document_id: nil).where(extracted_text: nil)
    count = scope.count
    scope.find_each { |link| Paperless::CaptureContentJob.perform_later(link.id) }
    puts "Enqueued #{count} document(s) for content capture."
  end
end
