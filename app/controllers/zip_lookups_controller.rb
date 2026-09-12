class ZipLookupsController < ApplicationController
  def show
    response.headers["Cache-Control"] = "no-store"
    zip = params[:zip]
    unless zip.is_a?(String) && zip.match?(/\A\d{5}\z/)
      render json: { error: "Enter a five-digit ZIP code." }, status: :unprocessable_content
      return
    end

    location = Rails.cache.fetch([ "zip-location", "v1", zip ], expires_in: 1.hour) do
      Weather::ZipCodeClient.new.lookup(zip)
    end
    render json: { zip: location.fetch(:postal_code), label: location.fetch(:display_name) }
  rescue Weather::Error => error
    render json: { error: error.message }, status: error.status
  end
end
