class ForecastsController < ApplicationController
  def create
    response.headers["Cache-Control"] = "no-store"
    @address = params[:address] if params[:address].is_a?(String)
    @forecast = Weather::Forecast.new.call(address: params[:address])
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
end
