#!/usr/bin/env bash

# https://www.faqforge.com/linux/fixed-ubuntu-apt-get-upgrade-auto-restart-services/
export DEBIAN_FRONTEND=noninteractive

# hardening - https://static.open-scap.org/ssg-guides/ssg-ubuntu2204-guide-index.html
apt-get install -y libopenscap8 jq
SCAP_INFO=$(curl https://api.github.com/repos/ComplianceAsCode/content/releases | jq -r '.[0].assets[]')
SCAP_DOWNLOAD_URL=$(echo $SCAP_INFO | jq -r '. | select(.content_type == "application/zip") | .browser_download_url')
SCAP_VERSION=$(echo $SCAP_DOWNLOAD_URL | grep -E -o '[0-9]{1}.[0-9]{1,2}.[0-9]{1,2}' | head -1)

wget $SCAP_DOWNLOAD_URL -O /tmp/scap.zip
unzip -d /tmp /tmp/scap.zip

chmod +x /tmp/scap-security-guide-${SCAP_VERSION}/bash/ubuntu2204-script-cis_level1_server.sh
sudo /tmp/scap-security-guide-${SCAP_VERSION}/bash/ubuntu2204-script-cis_level1_server.sh
