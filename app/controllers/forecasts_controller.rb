class ForecastsController < ApplicationController
  def create
    response.headers["Cache-Control"] = "no-store"
    @address = params[:address] if params[:address].is_a?(String)
    @forecast = Weather::Forecast.new.call(address: forecast_input)
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

  def forecast_input
    # The visible label is only presentation. Editing it invalidates the selection.
    zip = params[:selected_zip]
    if @address.present? && @address.length <= 300 && @address == params[:selected_label] &&
        zip.is_a?(String) && zip.match?(/\A\d{5}(?:-\d{4})?\z/)
      @selected_zip = zip
      @selected_label = @address
      zip
    else
      params[:address]
    end
  end
end
