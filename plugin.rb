# name: aliexpress-image
# about: Generates a product image preview for AliExpress links using Admin settings
# version: 0.2
# authors: YourName
# url: https://github.com/yourusername/aliexpress-image

enabled_site_setting :aliexpress_image_enabled

after_initialize do
  require 'digest'
  require 'openssl'
  require 'net/http'

  module ::AliExpressImage
    class Processor
      def self.get_img_url(product_id)
        # Pull values from the Admin Settings
        app_key = SiteSetting.aliexpress_app_key
        app_secret = SiteSetting.aliexpress_app_secret

        # Safety check: if settings are empty, don't run
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

        # 1. Sort and Sign
        sorted_params = params.sort.map { |k, v| "#{k}#{v}" }.join
        signature = OpenSSL::HMAC.hexdigest('SHA256', app_secret, sorted_params).upcase

        # 2. Call API
        uri = URI("https://api-sg.aliexpress.com/sync")
        uri.query = URI.encode_www_form(params.merge("sign" => signature))
        
        response = Net::HTTP.get(uri)
        json = JSON.parse(response)
        
        # 3. Extract Image
        json.dig("aliexpress_affiliate_productdetail_get_response", "resp_result", "result", "products", "product", 0, "product_main_image_url")
      rescue => e
        Rails.logger.error("AliExpress Image Plugin Error: #{e.message}")
        nil
      end
    end
  end

  on(:post_created) do |post|
    return unless SiteSetting.aliexpress_image_enabled
    
    # Matches IDs in URLs like /item/12345.html
    ids = post.raw.scan(/aliexpress\.com\/item\/(\d+)\.html/).flatten.uniq
    
    if ids.any?
      image_url = AliExpressImage::Processor.get_img_url(ids.first)
      if image_url
        new_raw = post.raw + "\n\n![AliExpress Product|600x600](#{image_url})"
        post.update_columns(raw: new_raw)
        post.publish_change_to_clients! :cooked
      end
    end
  end
end