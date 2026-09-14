class ForecastsController < ApplicationController
  def create
    response.headers["Cache-Control"] = "no-store"
    @address = params[:address] if params[:address].is_a?(String)
    @forecast = Weather::Forecast.new.call(**forecast_parameters)
    respond_to do |format|
      format.html { render "home/index" }
      format.json { render json: @forecast }
    end
  rescue Weather::Error => error
    @error = error
    respond_to do |format|
      format.html { render "home/index", status: error.status }
      format.json { render json: { error: { code: error.code, message: error.message } }, status: error.status }
    end
  end

  private

  def forecast_parameters
    # The visible label is only presentation. Editing it invalidates the selection.
    unless @address.present? && @address.length <= 300 && @address == params[:selected_label]
      return { address: params[:address] }
    end

    token = params[:selected_address_token]
    if !token.nil? && token != ""
      @selected_label = @address
      @selected_address_token = token if token.is_a?(String)
      return { address: @address, address_token: token }
    end

    zip = params[:selected_zip]
    if zip.is_a?(String) && zip.match?(/\A\d{5}(?:-\d{4})?\z/)
      @selected_zip = zip
      @selected_label = @address
      location_id = params[:selected_location_id]
      location_id = nil if location_id == ""
      @selected_location_id = location_id if location_id.is_a?(String)
      { address: zip, location_id: location_id }
    else
      { address: params[:address] }
    end
  end
end
