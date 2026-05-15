# name: aliexpress-image
# about: Generates a product image preview for AliExpress links using Admin settings
# version: 0.3
# authors: YourName
# url: https://github.com/yourusername/aliexpress-image

enabled_site_setting :aliexpress_image_enabled

# Register the custom CSS file
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
        
        # Extract the entire product object
        product = json.dig("aliexpress_affiliate_productdetail_get_response", "resp_result", "result", "products", "product", 0)
        
        return nil unless product

        # Return a hash of details
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
    end
  end

on(:post_created) do |post|
    return unless SiteSetting.aliexpress_image_enabled
    
    # We use a regex that captures the whole URL so we can replace it
    url_pattern = /https?:\/\/(?:[a-z]{2}\.)?aliexpress\.com\/item\/(\d+)\.html/
    
    match = post.raw.match(url_pattern)
    
    if match
      full_url = match[0]
      product_id = match[1]
      
      details = AliExpressImage::Processor.get_product_details(product_id)
      
      if details
        target_url = "https://www.aliexpress.com/item/#{product_id}.html"
        
        # Build the 300px Card
        card_markdown = <<~MD
          [wrap=aliexpress-card]
          [![#{details[:title]}|300x300](#{details[:image]})](#{target_url})
          [wrap=aliexpress-info]
          **[#{details[:title]}](#{target_url})**
          [/wrap]
          [/wrap]
        MD
        
        # REPLACE the original link with the card
        new_raw = post.raw.gsub(full_url, card_markdown)
        
        post.update_columns(raw: new_raw)
        post.publish_change_to_clients! :cooked
      end
    end
  end
end