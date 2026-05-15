# name: aliexpress-image
# about: Generates product image preview cards for multiple AliExpress links in a single post
# version: 0.5
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

        # Group 1 captures the ID. 
        # Group 2 optionally captures trailing query parameters (e.g., ?spm=123) to prevent dangling text.
        url_pattern = /(?<!\]\()(?<!\()https?:\/\/[a-zA-Z0-9.-]*aliexpress\.com\/item\/(\d+)\.html(\?[^\s()\[\]]*)?/
        
        product_cache = {}
        has_changes = false
        current_raw = post.raw.dup

        # Using the block form of gsub! processes the text safely from left-to-right.
        # This prevents the script from accidentally replacing URLs inside the markdown it just generated.
        current_raw.gsub!(url_pattern) do |match|
          product_id = $1 # Captured from the regex (\d+)
          
          # Cache API calls in case the user pasted the exact same product link multiple times
          product_cache[product_id] ||= get_product_details(product_id)
          details = product_cache[product_id]

          if details
            has_changes = true
            target_url = "https://www.aliexpress.com/item/#{product_id}.html"
            
            # The leading and trailing newlines ensure Discourse doesn't break the markdown formatting
            <<~MD
              
              [![#{details[:title]}|300x300](#{details[:image]})](#{target_url})
              [wrap=aliexpress-info]
              **[#{details[:title]}](#{target_url})**
              [/wrap]
              
            MD
          else
            match # Keeps the original URL string intact if the API call fails
          end
        end

        # We directly assign the raw text. Discourse handles the cooking, saving, and broadcasting naturally.
        post.raw = current_raw if has_changes
      end
    end
  end

  # Hooks onto creation and edits *before* Discourse processes the post
  on(:before_create_post) do |post|
    AliExpressImage::Processor.process_post(post)
  end

  on(:before_edit_post) do |post|
    AliExpressImage::Processor.process_post(post)
  end
end