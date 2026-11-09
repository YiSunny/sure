# Multiple Enable Banking applications

A household can use different Enable Banking applications for different bank
owners. Each connection stores its own Application ID, private key and consent
session. Family administrators manage these connections; separate application
credentials are not a privacy boundary between household administrators.

1. In Enable Banking, activate a Production application by linking the accounts
   it is allowed to read. Configure the callback URL shown in Sure as an allowed
   redirect URL. Restricted applications can read only linked accounts.
2. Sign into Sure as the account owner, who needs the family-admin role.
3. Open Settings → Bank sync → Enable Banking, then select **Add another
   Enable Banking application**. This action always creates a new connection;
   it does not change existing credentials or revoke existing consent.
4. Enter a recognizable application label, country and Application ID. Upload
   the unencrypted RSA private-key `.pem` downloaded from Enable Banking (up to
   32 KB). A public key or certificate alone is insufficient. The key is not
   echoed in the form, and credential parameters are filtered from request logs.
   Configure Active Record encryption to encrypt credentials at rest.
5. Save, then open Enable Banking again and select **Connect bank** on the row
   with the correct application label and ID. Authenticate with that owner's
   bank login. Activating the application in Enable Banking does not replace
   this consent flow.
6. Complete account setup while signed in as the owner; new Sure accounts are
   assigned to the current user. Review account sharing separately.

For another bank using an existing application's credentials, select **Add bank
using this application** on that application's row. This copies only the selected
connection's credentials into a new bank consent; it does not use the first
application in the household. Leave existing connected applications unchanged.

Private keys must stay out of Git, screenshots and support messages. Upload them
through the HTTPS form rather than posting their contents in chat.
