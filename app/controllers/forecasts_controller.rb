class ForecastsController < ApplicationController
  def create
    response.headers["Cache-Control"] = "no-store"
    render json: Weather::Forecast.new.call(address: params[:address])
  rescue Weather::Error => error
    render json: { error: { code: error.code, message: error.message } }, status: error.status
  end
end
