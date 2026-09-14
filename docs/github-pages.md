# GitHub Pages Sites

This repo manages DNS for the GitHub Pages sites. Application source, build
pipelines, and Pages content stay in their own repositories.

## Sites

- `hakimalai.com`: root CV site.
- `qr.hakimalai.com`: QR project.
- `packetloss.hakimalai.com`: PACKETLOSS project, with the development build at `/dev/`.

## DNS Model

- Apex `hakimalai.com`: GitHub Pages `A` and `AAAA` records.
- `qr.hakimalai.com`: GitHub Pages `A` and `AAAA` records.
- `packetloss.hakimalai.com`: GitHub Pages `CNAME` record pointing to `haki-malai.github.io`.

The apex and `qr` hosts retain the existing GitHub Pages IP records. The
`packetloss` subdomain uses GitHub's recommended `CNAME` configuration.

## Boundaries

GitHub Pages settings are not managed here yet. Import them only after the
current remote Pages build modes and custom-domain settings are verified.
