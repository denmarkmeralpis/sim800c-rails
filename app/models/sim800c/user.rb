# frozen_string_literal: true

module Sim800c
  # A dashboard account (admin, operator or viewer).
  class User < ApplicationRecord
    has_many :sessions, class_name: "Sim800c::Session", dependent: :delete_all

    class << self
      # True until the first account exists; the dashboard then shows the setup page.
      def needs_setup? = !exists?

      def find_by_username(username) = find_by(username_key: username.to_s.downcase)

      def create_account!(username, password, role)
        username = username.to_s
        unless Auth::USERNAME_FORMAT.match?(username)
          raise AppError.bad_request("Username must be 3-40 characters: letters, digits, dot, dash or underscore")
        end
        raise AppError.bad_request("Invalid role: #{role}") unless Auth::ROLES.include?(role.to_s)

        Auth.validate_password!(password)
        raise AppError.conflict("User \"#{username}\" already exists") if find_by_username(username)

        create!(username: username, username_key: username.downcase, password_hash: Auth.hash_password(password),
                role: role.to_s)
      rescue ActiveRecord::RecordNotUnique
        raise AppError.conflict("User \"#{username}\" already exists")
      end

      # Creates the initial admin from config.auth.admin_password on first start. True if created.
      def ensure_admin!(username, password)
        return false if password.to_s.empty? || !needs_setup?

        create_first_admin!(username, password)
        true
      rescue AppError => e
        raise unless e.code == "conflict"

        false
      end

      # First-time setup from the dashboard: creates the admin, only while no account exists.
      def setup_admin!(username, password)
        create_first_admin!(username, password)
      end

      # Two processes creating the first admin at once would both see an empty table (READ COMMITTED).
      # Inserting the same marker row first makes the second wait for the first to commit; by then the
      # admin exists. The marker never outlives the transaction.
      def create_first_admin!(username, password)
        transaction do
          marker = IdempotencyKey.create!(owner: "system", idempotency_key: "first-admin", request_hash: "-",
                                          sms_ids: [], created_at: Time.current)
          raise AppError.conflict("Setup has already been completed. Sign in instead.") unless needs_setup?

          user = create_account!(username, password, "admin")
          marker.delete
          user
        end
      end

      # The user when the password matches, else nil. Takes the same time whether or not the user exists.
      def authenticate(username, password)
        user = find_by_username(username)
        ok = Auth.verify_password(password, user&.password_hash || Auth.dummy_hash)
        user if user && ok
      end

      # Call inside a transaction: the admin rows stay locked until it ends, so two admins removing
      # each other at the same time cannot leave none.
      def assert_not_last_admin!
        admins = where(role: "admin").lock.pluck(:id)
        raise AppError.bad_request("At least one admin account must remain") if admins.size <= 1
      end
    end

    def scopes = Auth::ROLE_SCOPES.fetch(role)

    def as_api
      { id: id, username: username, role: role, createdAt: iso(created_at), lastLoginAt: iso(last_login_at) }
    end

    # Changing the role or the password signs the user out everywhere.
    def update_account!(acting_user_id:, role: nil, password: nil)
      if role && role != self.role
        raise AppError.bad_request("You cannot change your own role") if id == acting_user_id
        raise AppError.bad_request("Invalid role: #{role}") unless Auth::ROLES.include?(role)

        self.class.transaction do
          self.class.assert_not_last_admin! if self.role == "admin"
          update!(role: role)
          sessions.delete_all
        end
      end
      unless password.nil?
        Auth.validate_password!(password)
        update!(password_hash: Auth.hash_password(password))
        sessions.delete_all
      end
      self
    end

    def destroy_account!(acting_user_id)
      raise AppError.bad_request("You cannot delete your own account") if id == acting_user_id

      transaction do
        self.class.assert_not_last_admin! if role == "admin"
        # User ids can be reused, so a new user must not inherit this one's Idempotency-Keys.
        IdempotencyKey.where(owner: "user:#{id}").delete_all
        destroy!
      end
    end

    # Signs out every other session of this user.
    def change_password!(current, new_password, keep_session_id)
      raise AppError.bad_request("Current password is incorrect") unless Auth.verify_password(current, password_hash)

      Auth.validate_password!(new_password)
      update!(password_hash: Auth.hash_password(new_password))
      sessions.where.not(id: keep_session_id.to_s).delete_all
    end

    private

    def iso(time) = Sim800c.iso(time)
  end
end
