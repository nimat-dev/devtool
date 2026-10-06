# Corporate root CA (optional)

If your company does TLS interception, the HTTPS downloads in the Dockerfile
(Microsoft, HashiCorp, GitHub, AWS) will fail during build with certificate
errors. Drop your corporate root CA here to fix it:

    certs/corp-root-ca.crt   <- any filename, must end in .crt (PEM encoded)

Rebuild. With no .crt here, the CA step is a harmless no-op.

Get the cert from IT, or export it from a browser on the corporate network.
Do NOT commit the real cert (.gitignore already excludes *.crt / *.pem).
