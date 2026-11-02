# frozen_string_literal: true

require "test_helper"
require "rake"

class TasksTest < ActiveSupport::TestCase
  setup do
    Rake::Task.clear
    Rails.application.load_tasks
  end

  test "defines each task once" do
    %w[sim800c:run sim800c:ports sim800c:reset_password sim800c:install:migrations].each do |name|
      assert_equal 1, Rake::Task[name].actions.size, name
    end
  end

  test "reset_password updates a user and creates a missing admin" do
    configure_for_tests
    Sim800c::User.create_account!("viewer1", "viewer-pass", "viewer")
    out, = capture_io { Rake::Task["sim800c:reset_password"].invoke("VIEWER1", "new-password") }
    assert_match(/updated/, out)
    assert Sim800c::User.authenticate("viewer1", "new-password")
    Rake::Task["sim800c:reset_password"].reenable
    out, = capture_io { Rake::Task["sim800c:reset_password"].invoke("root", "root-password") }
    assert_match(/created as an admin/, out)
    assert_equal "admin", Sim800c::User.find_by_username("root").role
  end
end
