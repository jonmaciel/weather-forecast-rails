class ZipLookupsController < ApplicationController
  def show
    response.headers["Cache-Control"] = "no-store"
    zip = params[:zip]
    unless zip.is_a?(String) && zip.match?(/\A\d{3,5}\z/)
      render json: { error: "Enter three to five ZIP digits." }, status: :unprocessable_content
      return
    end

    suggestions = Rails.cache.fetch([ "zip-suggestions", "v1", zip ], expires_in: 1.hour) do
      Weather::ZipCodeClient.new.suggestions(zip)
    end
    render json: { suggestions: suggestions }
  rescue Weather::Error => error
    render json: { error: error.message }, status: error.status
  end
end
