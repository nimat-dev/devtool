# Your company's certificates (optional)

Some company networks open HTTPS connections and sign them again with their own certificate (TLS
inspection). The tools then stop with errors such as "self-signed certificate in certificate
chain" (az), "x509: certificate signed by unknown authority" (kubectl, terraform) or "SSL
certificate problem" (git, curl) until they trust that certificate. This folder is where it goes.

The easy way, with nothing to rebuild:

    Add-DevToolsCA        (PowerShell)
    devtools-add-ca       (bash)

It asks the network which certificates it signs with, shows them, and after your `y` saves them here.

Or put the files here yourself:

    certs/company-root.cer   <- .crt, .cer or .pem, any capital letters, any name

PEM text and the binary form that Windows exports both work, and so do several files. If IT does
not have the root certificate for you, export it from Windows: `certmgr.msc`, *Trusted Root
Certification Authorities*, *Certificates*, right click the company's root, *All Tasks*, *Export*,
*Base-64 encoded X.509 (.CER)*. Then `Add-DevToolsCA -Path FILE` (bash: `devtools-add-ca FILE`).

Every container reads this folder as it starts, so a new file counts from the next command on.
The Dockerfile also trusts the `*.crt` files here while the image is built (the downloads of the
tools). That one needs a `docker compose build` after you add a file, and the file must be PEM.

Add your company's certificate and nothing else: whatever is here is trusted for every site the
tools open. Do NOT commit the real files (.gitignore already excludes them). More in the README,
under "Certificate errors".
