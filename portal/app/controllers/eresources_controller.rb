# frozen_string_literal: true

class EresourcesController < ApplicationController
  def index
    @databases = patron_api.eresources["databases"]
  end
end
