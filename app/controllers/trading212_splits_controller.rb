class Trading212SplitsController < ApplicationController
  before_action :require_preview_features!
  before_action :set_provider_account

  def show
    @summary = splitter.preview
  rescue Trading212Account::Snapshot::Invalid, Trading212Account::Splitter::Conflict => error
    @error = error.message
  end

  def create
    splitter.apply!
    redirect_to accounts_path, notice: t("trading212_split.created"), status: :see_other
  rescue Trading212Account::Snapshot::Invalid, Trading212Account::Splitter::Conflict => error
    redirect_to trading212_split_path(@provider_account), alert: error.message, status: :see_other
  end

  private

    def set_provider_account
      @provider_account = Trading212Account.joins(:trading212_item)
        .where(trading212_items: { family_id: Current.family.id }).find(params[:id])
      account = @provider_account.current_account
      raise ActiveRecord::RecordNotFound unless account && Current.family.accounts.writable_by(Current.user).exists?(id: account.id)
    end

    def splitter
      Trading212Account::Splitter.new(@provider_account, user: Current.user)
    end
end
