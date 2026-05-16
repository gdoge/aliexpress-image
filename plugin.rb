# name: aliexpress-image
# about: Generates product image preview cards for multiple AliExpress links in a single post (Supports Short Links)
# version: 0.8
# authors: YourName
# url: https://github.com/yourusername/aliexpress-image

enabled_site_setting :aliexpress_image_enabled

register_asset "stylesheets/aliexpress.scss"

after_initialize do
  require 'digest'
  require 'openssl'
  require 'net/http'
  require 'json'
  require 'uri' # Required for parsing URLs in redirects

  module ::AliExpressImage
    class Processor
      
      # NEW: Helper Method to follow HTTP redirects to find the real URL
      def self.resolve_redirects(url, limit = 3)
        return url if limit == 0
        
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 5
        http.read_timeout = 5
        
        request = Net::HTTP::Get.new(uri.request_uri)
        # Mimic a standard browser so AliExpress doesn't block the redirect request
        request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"
        
        response = http.request(request)

        if response.is_a?(Net::HTTPRedirection)
          location = response['location']
          # Follow the redirect recursively
          resolve_redirects(location, limit - 1)
        else
          url # Reached final destination
        end
      rescue => e
        Rails.logger.warn("AliExpress Plugin: Failed to resolve short link #{url} - #{e.message}")
        url
      end

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
        http.open_timeout = 5 
        http.read_timeout = 5 

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

        # Updated Regex: Captures Standard Links AND Short Links (s.click / a.aliexpress)
        # Group 1: Optional Markdown Link prefix: [Text](
        # Group 2: The full URL (including tracking parameters)
        # Group 3: Optional Markdown Link suffix: )
        url_pattern = /(\[[^\]]*\]\()?((?:https?:\/\/(?:[a-zA-Z0-9.-]*aliexpress\.com\/item\/\d+\.html|s\.click\.aliexpress\.com\/e\/[a-zA-Z0-9_]+|a\.aliexpress\.com\/[a-zA-Z0-9_]+))[^\s()\[\]]*)(\))?/
        
        product_cache = {}
        has_changes = false
        current_raw = post.raw.dup

        current_raw.gsub!(url_pattern) do |matched_block|
          match_data = matched_block.match(url_pattern)
          next matched_block unless match_data

          full_url = match_data[2]
          product_id = nil
          
          # Check if it's a standard URL or a short link
          if full_url.match?(/item\/(\d+)\.html/)
            product_id = full_url[/\/item\/(\d+)\.html/, 1]
          else
            # Unshorten the link to steal the product ID
            resolved_url = resolve_redirects(full_url)
            product_id = resolved_url[/\/item\/(\d+)\.html/, 1] if resolved_url
          end
          
          # If we couldn't extract an ID (e.g., dead link), leave text alone
          next matched_block unless product_id

          if !product_cache.key?(product_id) && product_cache.any?
            sleep(0.5) 
          end

          product_cache[product_id] ||= get_product_details(product_id)
          details = product_cache[product_id]

          if details
            has_changes = true
            
            # Use the original link (short or long) as the destination 
            # to preserve localized subdomains and affiliate tracking parameters!
            target_url = full_url
            safe_title = details[:title].to_s.gsub(/[\[\]()]/, '').strip
            
            <<~MD
              
              [![#{safe_title}|300x300](#{details[:image]})](#{target_url})
              [wrap=aliexpress-info]
              **[#{safe_title}](#{target_url})**
              [/wrap]
              
            MD
          else
            matched_block 
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