require "openssl"

class EnableBankingItem::CredentialUpload
  MAX_BYTES = 32.kilobytes

  def self.read(file)
    unless file.respond_to?(:read) && file.respond_to?(:size)
      raise ArgumentError, I18n.t("enable_banking_items.applications.select_key")
    end
    raise ArgumentError, I18n.t("enable_banking_items.applications.key_too_large") if file.size > MAX_BYTES

    content = file.read(MAX_BYTES + 1)
    raise ArgumentError, I18n.t("enable_banking_items.applications.key_too_large") if content.bytesize > MAX_BYTES
    key = OpenSSL::PKey::RSA.new(content, "")
    raise ArgumentError, I18n.t("enable_banking_items.applications.invalid_key") unless key.private?

    # Store only the private key, not incidental certificate text or metadata.
    key.to_pem
  rescue OpenSSL::PKey::PKeyError, OpenSSL::PKey::RSAError, OpenSSL::Cipher::CipherError
    # Never echo key contents, filenames or OpenSSL parser errors into the UI.
    raise ArgumentError, I18n.t("enable_banking_items.applications.invalid_key")
  end
end
