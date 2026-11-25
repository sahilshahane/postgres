#!/bin/bash
# REPORT.md -> report/REPORT.pdf (pandoc to HTML, headless Chrome to PDF)
set -e; cd "$(dirname "$0")/.."
pandoc REPORT.md -s --embed-resources --resource-path=. --metadata pagetitle="AIO WAL on Cloud Storage" -c report/style.css -o report/REPORT.html
google-chrome --headless=new --no-sandbox --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="$PWD/report/REPORT.pdf" "file://$PWD/report/REPORT.html" 2>/dev/null
ls -la report/REPORT.pdf
