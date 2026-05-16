# name: aliexpress-image
# about: Generates product image preview cards for multiple AliExpress links in a single post
# version: 0.6
# authors: YourName
# url: https://github.com/yourusername/aliexpress-image

enabled_site_setting :aliexpress_image_enabled

register_asset "stylesheets/aliexpress.scss"

after_initialize do
  require 'digest'
  require 'openssl'
  require 'net/http'

  module ::AliExpressImage
    class Processor
      def self.get_product_details(product_id)
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
        
        response = Net::HTTP.get(uri)
        json = JSON.parse(response)
        
        product = json.dig("aliexpress_affiliate_productdetail_get_response", "resp_result", "result", "products", "product", 0)
        
        return nil unless product

        {
          title: product["product_title"],
          image: product["product_main_image_url"],
          price: product["target_sale_price"],
          currency: product["target_currency"]
        }
      rescue => e
        Rails.logger.error("AliExpress Image Plugin Error: #{e.message}")
        nil
      end

      def self.process_post(post)
        return unless SiteSetting.aliexpress_image_enabled
        return if post.raw.blank?

        # Matches the URL and ignores markdown wrappers
        url_pattern = /(?<!\]\()(?<!\()https?:\/\/[a-zA-Z0-9.-]*aliexpress\.com\/item\/\d+\.html(?:\?[^\s()\[\]]*)?/
        
        product_cache = {}
        has_changes = false
        current_raw = post.raw.dup

        # Scan and replace from left-to-right
        current_raw.gsub!(url_pattern) do |matched_url|
          # Extract exact ID from the currently evaluated link
          product_id = matched_url.match(/\/item\/(\d+)\.html/)[1]
          
          # Check cache or fetch from API
          product_cache[product_id] ||= get_product_details(product_id)
          details = product_cache[product_id]

          if details
            has_changes = true
            target_url = "https://www.aliexpress.com/item/#{product_id}.html"
            
            # Formatted Markdown Card
            <<~MD
              
              [![#{details[:title]}|300x300](#{details[:image]})](#{target_url})
              [wrap=aliexpress-info]
              **[#{details[:title]}](#{target_url})**
              [/wrap]
              
            MD
          else
            # Leave URL alone if API fails
            matched_url 
          end
        end

        # Update the post text before Discourse saves it
        post.raw = current_raw if has_changes
      end
    end
  end

  # Hook 1: Runs when a user creates a brand new post or topic
  on(:before_create_post) do |post|
    AliExpressImage::Processor.process_post(post)
  end

  # Hook 2: Runs when a user edits an existing post
  on(:before_edit_post) do |post|
    AliExpressImage::Processor.process_post(post)
  end
end