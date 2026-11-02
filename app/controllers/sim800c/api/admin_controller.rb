# frozen_string_literal: true

module Sim800c
  module Api
    # User and API key management — admins only, via the dashboard.
    class AdminController < ApiController
      before_action :authenticate!
      before_action { require_scope!("admin") }
      before_action :require_session!

      def keys
        render json: { data: ApiKey.listing.map(&:as_api), availableScopes: Auth::API_KEY_SCOPES }
      end

      def create_key
        v = body_validation
        name = v.string("name", trim: true, min: 1, max: 80)
        scopes = v.enum_array("scopes", Auth::API_KEY_SCOPES, min_message: "Choose at least one scope")
        v.validate!
        key, api_key = ApiKey.generate!(name, scopes, principal.user_id)
        log_and_notify(:info, "auth", "API key \"#{api_key.name}\" created by #{principal.name}", { scopes: api_key.scopes })
        render json: { data: api_key.as_api, key: key }, status: :created
      end

      def revoke_key
        api_key = (ApiKey.find_by(id: id_param) || raise(AppError.not_found("API key"))).revoke!
        log_and_notify(:info, "auth", "API key \"#{api_key.name}\" revoked by #{principal.name}")
        render json: { data: api_key.as_api }
      end

      def users
        render json: { data: User.order(:username_key).map(&:as_api), roles: Auth::ROLE_SCOPES }
      end

      def create_user
        v = body_validation
        username = v.string("username", trim: true, min: 3, max: 40)
        password = v.string("password", min: 8, max: 200)
        role = v.enum("role", Auth::ROLES, optional: false)
        v.validate!
        user = User.create_account!(username, password, role)
        log_and_notify(:info, "auth", "User \"#{user.username}\" (#{user.role}) created by #{principal.name}")
        render json: { data: user.as_api }, status: :created
      end

      def update_user
        id = id_param
        v = body_validation
        role = v.enum("role", Auth::ROLES)
        password = v.string("password", min: 8, max: 200, optional: true)
        v.issue("", "Nothing to update") if v.issues.empty? && role.nil? && password.nil?
        v.validate!
        user = find_user(id).update_account!(role: role, password: password, acting_user_id: principal.user_id)
        log_and_notify(:info, "auth", "User \"#{user.username}\" updated by #{principal.name}")
        render json: { data: user.as_api }
      end

      def destroy_user
        user = find_user(id_param)
        user.destroy_account!(principal.user_id)
        log_and_notify(:info, "auth", "User \"#{user.username}\" deleted by #{principal.name}")
        head :no_content
      end

      private

      def find_user(id) = User.find_by(id: id) || raise(AppError.not_found("User"))
    end
  end
end
