class ZipLookupsController < ApplicationController
  def show
    response.headers["Cache-Control"] = "no-store"
    zip = params[:zip]
    unless zip.is_a?(String) && zip.match?(/\A\d{3,5}\z/)
      raise Weather::Error.new("invalid_zip_prefix", "Enter three to five ZIP digits.", status: :unprocessable_content)
    end

    suggestions = Rails.cache.fetch([ "zip-suggestions", "v2", zip ], expires_in: 1.hour) do
      Weather::ZipCodeClient.new.suggestions(zip)
    end
    render json: { suggestions: suggestions }
  rescue Weather::Error => error
    render json: { error: { code: error.code, message: error.message } }, status: error.status
  end
end
