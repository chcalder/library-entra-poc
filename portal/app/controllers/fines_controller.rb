# frozen_string_literal: true

class FinesController < ApplicationController
  def index
    data = patron_api.fines
    @fines = data["fines"]
    @balance = data["balance"]
  end
end
