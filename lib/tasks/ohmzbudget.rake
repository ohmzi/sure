namespace :ohmzbudget do
  desc "First-run bootstrap: household family + first super_admin (password on stdin) + close signup"
  task first_run: :environment do
    email = ENV["ADMIN_EMAIL"].to_s
    abort "set ADMIN_EMAIL (see deploy/.env)" if email.blank?

    password =
      if STDIN.tty?
        require "io/console"
        STDIN.getpass("Admin password for #{email}: ")
      else
        STDIN.read.strip
      end

    result = Ohmzbudget::FirstRun.call(email: email, password: password)
    puts "super_admin=#{result.user.email} role=#{result.user.role} " \
         "family=#{result.family.name} onboarding_state=#{result.onboarding_state}"
  end
end
