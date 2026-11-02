# frozen_string_literal: true

require "test_helper"
require "support/api_helpers"

# First-time setup: without config.auth.admin_password, the first admin is created from the dashboard.
class SetupTest < ActiveSupport::TestCase
  include ApiHelpers

  setup do
    start_runtime("auth.admin_password" => nil, "auth.admin_username" => "owner")
    Sim800c::ApiController.instance_variable_set(:@admin_checked, nil)
  end

  test "first-time setup creates the admin once" do
    res = req("/api/auth/setup")
    assert_equal 200, res.status
    assert_equal({ "required" => true, "username" => "owner" }, res.body)
    assert_equal 0, Sim800c::User.count
    assert_equal 401, req("/api/v1/sms").status

    assert_equal 400, req("/api/auth/setup", body: { username: "owner", password: "short" }).status
    assert_equal 400, req("/api/auth/setup", body: { username: "no spaces", password: "long-enough-pass" }).status
    assert_equal 0, Sim800c::User.count

    created = req("/api/auth/setup", body: { username: "owner", password: "owner-password" })
    assert_equal 200, created.status
    assert_equal %w[owner admin], [created.body.dig("user", "username"), created.body.dig("user", "role")]
    assert created.body["csrfToken"]
    assert_includes created.body["scopes"], "admin"
    cookie = created.headers["set-cookie"].split(";").first
    me = req("/api/auth/me", session: { cookie: cookie })
    assert_equal [200, "owner"], [me.status, me.body.dig("user", "username")]
    assert_equal 200, req("/api/auth/login", body: { username: "owner", password: "owner-password" }).status

    assert_equal({ "required" => false, "username" => "owner" }, req("/api/auth/setup").body)
    again = req("/api/auth/setup", body: { username: "intruder", password: "intruder-password" })
    assert_equal 409, again.status
    assert_equal ["owner"], Sim800c::User.pluck(:username)
  end
end
