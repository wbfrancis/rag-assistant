class SearchController < ApplicationController
  # A single read-only action: embed the query and show the tenant's nearest
  # chunks. The tenant always comes from Current.user (never params), so a user
  # can only ever search their own corpus.
  def index
    @query = params[:q].to_s
    @result = Retriever.new(tenant: Current.user, query: @query).call if @query.present?
  end
end
