# frozen_string_literal: true

module Ohmzbudget
  # First-run bootstrap for the fork: an idempotent household family + the
  # first super_admin, then close open signup. Kept as a PORO (house style:
  # logic in models, not app/services) so it is unit-testable without Rake.
  class FirstRun
    class Error < StandardError; end

    Result = Struct.new(:family, :user, :onboarding_state, keyword_init: true)

    MIN_PASSWORD_LENGTH = 8

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(email:, password:, family_name: "Household", currency: "USD", country: "US", first_name: "Owner")
      @email = email.to_s.strip.downcase
      @password = password.to_s
      @family_name = family_name
      @currency = currency
      @country = country
      @first_name = first_name
    end

    def call
      raise Error, "email is required" if @email.blank?
      raise Error, "password must be at least #{MIN_PASSWORD_LENGTH} characters" if @password.length < MIN_PASSWORD_LENGTH

      family = Family.find_or_create_by!(name: @family_name) do |f|
        f.currency = @currency
        f.country = @country
      end

      user = User.find_or_initialize_by(email: @email)
      user.assign_attributes(
        family: family,
        first_name: @first_name,
        role: "super_admin",
        password: @password,
        password_confirmation: @password
      )
      user.save!

      Setting.onboarding_state = "invite_only"

      Result.new(family: family, user: user, onboarding_state: Setting.onboarding_state)
    end
  end
end
