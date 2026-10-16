# frozen_string_literal: true

require "test_helper"

class Sure::FirstRunTest < ActiveSupport::TestCase
  test "creates a household family and a super_admin and closes signup" do
    result = Sure::FirstRun.call(
      email: "first-run-#{SecureRandom.hex(4)}@example.com",
      password: "correct-horse-9A!",
      family_name: "M0 Household"
    )

    assert result.user.persisted?
    assert result.user.super_admin?, "the bootstrapped user must be a super_admin"
    assert_equal "M0 Household", result.family.name
    assert_equal result.family, result.user.family
    assert_equal "invite_only", result.onboarding_state
    assert_equal "invite_only", Setting.onboarding_state
    assert Setting.require_invite_for_signup, "invite_only must require an invite"
  end

  test "is idempotent for the same email and leaves exactly one super_admin" do
    email = "first-run-idem-#{SecureRandom.hex(4)}@example.com"
    first = Sure::FirstRun.call(email: email, password: "correct-horse-9A!", family_name: "M0 Household")
    second = Sure::FirstRun.call(email: email, password: "another-horse-1B!", family_name: "M0 Household")

    assert_equal first.user.id, second.user.id
    assert_equal 1, User.where(email: email).count
    assert_equal 1, Family.where(name: "M0 Household").count
  end

  test "rejects a password shorter than 8 characters" do
    assert_raises(Sure::FirstRun::Error) do
      Sure::FirstRun.call(email: "short-#{SecureRandom.hex(4)}@example.com", password: "short")
    end
  end
end
