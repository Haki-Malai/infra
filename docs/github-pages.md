# GitHub Pages Sites

This repo manages DNS for the GitHub Pages sites. Application source, build
pipelines, and Pages content stay in their own repositories.

## Sites

- `hakimalai.com`: root CV site.
- `qr.hakimalai.com`: QR project.
- PACKETLOSS is migrating to S3/CloudFront at `packetloss.hakimalai.com` and
  `dev.packetloss.hakimalai.com`; see [the migration runbook](packetloss.md).

## DNS Model

- Apex `hakimalai.com`: GitHub Pages `A` and `AAAA` records.
- `qr.hakimalai.com`: GitHub Pages `A` and `AAAA` records.
- `packetloss.hakimalai.com`: retains its GitHub Pages `A`/`AAAA` records until
  `packetloss_production_dns_enabled` switches them to CloudFront aliases.
- `dev.packetloss.hakimalai.com`: CloudFront `A`/`AAAA` aliases.

The apex and `qr` hosts retain the existing GitHub Pages IP records.

## Boundaries

GitHub Pages settings are not managed here yet. Import them only after the
current remote Pages build modes and custom-domain settings are verified.
