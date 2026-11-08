require "digest"

class Trading212StatementsController < ApplicationController
  before_action :require_preview_features!
  before_action :set_provider_account

  def new
  end

  def create
    file = params.require(:file)
    raise ArgumentError, "Select a CSV file" unless file.respond_to?(:size) && file.respond_to?(:read)
    raise ArgumentError, "CSV exceeds upload limit" if file.size > Import::MAX_CSV_SIZE
    content = file.read
    checksum = Digest::SHA256.hexdigest(content)
    @statement = @provider_account.trading212_statements.find_or_initialize_by(checksum: checksum)
    if @statement.new_record?
      @statement.assign_attributes(user: Current.user, rows: Trading212Statement::Parser.new(content).parse)
      @statement.save!
    end
    redirect_to trading212_statement_path(@statement, trading212_account_id: @provider_account.id), status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    redirect_to new_trading212_statement_path(trading212_account_id: @provider_account.id), alert: error.message, status: :see_other
  end

  def show
    @statement = @provider_account.trading212_statements.find(params[:id])
    @summary = @statement.preview_result
  end

  def apply
    @statement = @provider_account.trading212_statements.find(params[:id])
    @statement.apply!(actor: Current.user)
    redirect_to account_path(@provider_account.current_account), notice: t("trading212_split.statement_applied"), status: :see_other
  rescue ArgumentError => error
    redirect_to trading212_statement_path(@statement, trading212_account_id: @provider_account.id), alert: error.message, status: :see_other
  end

  def revert
    @statement = @provider_account.trading212_statements.find(params[:id])
    @statement.revert!(actor: Current.user)
    redirect_to trading212_statement_path(@statement, trading212_account_id: @provider_account.id), notice: t("trading212_split.statement_reverted"), status: :see_other
  rescue ArgumentError => error
    redirect_to trading212_statement_path(@statement, trading212_account_id: @provider_account.id), alert: error.message, status: :see_other
  end

  private

    def set_provider_account
      @provider_account = Trading212Account.cash.joins(:trading212_item)
        .where(trading212_items: { family_id: Current.family.id }).find(params[:trading212_account_id])
      account = @provider_account.current_account
      raise ActiveRecord::RecordNotFound unless account && Current.family.accounts.writable_by(Current.user).exists?(id: account.id)
    end
end
