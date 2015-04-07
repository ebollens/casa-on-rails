require 'uri'
require 'net/http'

class InPeer < ActiveRecord::Base

  has_many :in_filter_rulesets

  def get_payloads

    uri = URI(self.uri)
    payloads = nil

    Net::HTTP.start(uri.host, uri.port) do |http|

      request = Net::HTTP::Get.new uri

      request.add_field('Accept', 'application/json')
      request.add_field('Accept-Charset', 'utf-8')
      request.add_field('Content-Type', 'application/json')

      if self.secret
        request.body = {'secret'=>self.secret}.to_json
      end

      response = http.request(request)
      payloads = JSON.parse response.body

    end

    payloads

  end

end
