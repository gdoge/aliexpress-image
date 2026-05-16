# name: aliexpress-image
# about: Generates product image preview cards for multiple AliExpress links in a single post
# version: 0.7
# authors: YourName
# url: https://github.com/yourusername/aliexpress-image

enabled_site_setting :aliexpress_image_enabled

register_asset "stylesheets/aliexpress.scss"

after_initialize do
  require 'digest'
  require 'openssl'
  require 'net/http'
  require 'json'

  module ::AliExpressImage
    class Processor
      
      # Added a retries parameter (defaults to 2)
      def self.get_product_details(product_id, retries = 2)
        app_key = SiteSetting.aliexpress_app_key
        app_secret = SiteSetting.aliexpress_app_secret

        return nil if app_key.blank? || app_secret.blank?

        params = {
          "method" => "aliexpress.affiliate.productdetail.get",
          "app_key" => app_key,
          "format" => "json",
          "v" => "2.0",
          "sign_method" => "sha256",
          "timestamp" => (Time.now.to_f * 1000).to_i.to_s,
          "product_ids" => product_id,
          "target_currency" => "USD",
          "target_language" => "EN"
        }

        sorted_params = params.sort.map { |k, v| "#{k}#{v}" }.join
        signature = OpenSSL::HMAC.hexdigest('SHA256', app_secret, sorted_params).upcase

        uri = URI("https://api-sg.aliexpress.com/sync")
        uri.query = URI.encode_www_form(params.merge("sign" => signature))
        
        # Safety Net 1: Hardened HTTP Request with Timeouts
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5 # Fails if connection takes longer than 5s
        http.read_timeout = 5 # Fails if reading data takes longer than 5s

        request = Net::HTTP::Get.new(uri.request_uri)
        response = http.request(request)

        # Safety Net 2: Ensure we actually got a 200 OK response before parsing
        unless response.is_a?(Net::HTTPSuccess)
          Rails.logger.warn("AliExpress Image Plugin: HTTP Error #{response.code} for product #{product_id}")
          raise "HTTP Error" 
        end

        json = JSON.parse(response.body)
        product = json.dig("aliexpress_affiliate_productdetail_get_response", "resp_result", "result", "products", "product", 0)
        
        return nil unless product

        {
          title: product["product_title"],
          image: product["product_main_image_url"],
          price: product["target_sale_price"],
          currency: product["target_currency"]
        }
        
      # Safety Net 3: Catch Network, Timeout, and JSON Parsing errors specifically
      rescue Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, JSON::ParserError => e
        if retries > 0
          Rails.logger.warn("AliExpress Image Plugin: #{e.class} on #{product_id}. Retrying...")
          sleep(1) # Wait 1 second before retrying
          return get_product_details(product_id, retries - 1)
        else
          Rails.logger.error("AliExpress Image Plugin: Failed after retries for #{product_id}. Error: #{e.message}")
          return nil
        end
      rescue => e
        Rails.logger.error("AliExpress Image Plugin Unexpected Error: #{e.message}")
        return nil
      end

def self.process_post(post)
        return unless SiteSetting.aliexpress_image_enabled
        return if post.raw.blank?

        url_pattern = /(?<!\]\()(?<!\()https?:\/\/[a-zA-Z0-9.-]*aliexpress\.com\/item\/\d+\.html(?:\?[^\s()\[\]]*)?/
        
        product_cache = {}
        has_changes = false
        current_raw = post.raw.dup

        current_raw.gsub!(url_pattern) do |matched_url|
          product_id = matched_url.match(/\/item\/(\d+)\.html/)[1]
          
          if !product_cache.key?(product_id) && product_cache.any?
            sleep(0.5) 
          end

          product_cache[product_id] ||= get_product_details(product_id)
          details = product_cache[product_id]

          if details
            has_changes = true
            target_url = "https://www.aliexpress.com/item/#{product_id}.html"
            
            # Sanitize the title to prevent broken Markdown links
            # This removes [, ], (, and ) from the title string
            safe_title = details[:title].to_s.gsub(/[\[\]()]/, '').strip
            
            <<~MD
              
              [![#{safe_title}|300x300](#{details[:image]})](#{target_url})
              [wrap=aliexpress-info]
              **[#{safe_title}](#{target_url})**
              [/wrap]
              
            MD
          else
            matched_url 
          end
        end

        post.raw = current_raw if has_changes
      end
    end
  end

  on(:before_create_post) do |post|
    AliExpressImage::Processor.process_post(post)
  end

  on(:before_edit_post) do |post|
    AliExpressImage::Processor.process_post(post)
  end
end