# name: aliexpress-image
# about: Generates product image preview cards for multiple AliExpress links in a single post
# version: 0.4
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
    end
  end

  on(:post_created) do |post|
    return unless SiteSetting.aliexpress_image_enabled
    
    # Safeguard 1: If we already processed this post, stop immediately
    return if post.custom_fields["aliexpress_card_processed"]
    
    # Safeguard 2: Advanced Regex Lookbehind
    # (?<!\]\() and (?<!\() ensure the URL is NOT preceded by a markdown link identifier
    url_pattern = /(?<!\]\()(?<!\()(https?:\/\/[a-zA-Z0-9.-]*aliexpress\.com\/item\/(\d+)\.html)/
    
    matches = post.raw.scan(url_pattern).uniq
    
    if matches.any?
      current_raw = post.raw.dup
      has_changes = false
      
      matches.each do |full_url, product_id|
        details = AliExpressImage::Processor.get_product_details(product_id)
        
        if details
          target_url = "https://www.aliexpress.com/item/#{product_id}.html"
          
          card_markdown = <<~MD
            [![#{details[:title]}|300x300](#{details[:image]})](#{target_url})
              [wrap=aliexpress-info]
              **[#{details[:title]}](#{target_url})**
              [/wrap]
          MD
          
          current_raw.gsub!(full_url, card_markdown)
          has_changes = true
        end
      end
      
      if has_changes
        # Mark as processed so it never runs on this post again
        post.custom_fields["aliexpress_card_processed"] = true
        
        # Save both the new text and our flag safely
        post.update_columns(raw: current_raw)
        post.save_custom_fields
        
        post.publish_change_to_clients! :cooked
      end
    end
  end
end