#!/bin/bash

# Must be run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root. Exiting."
  exit 1
fi

# Ensure script is run from relative directory 
cd "$(dirname "$0")" || {
  echo "Failed to change to script directory"
  exit 1
}

dnf install -y libicu libxslt

tar -xvf /opt/al2023-php74/php-7.4.tar.gz -C /usr/local/
ln -s /usr/local/php-7.4/bin/php /usr/bin/php
ln -s /usr/local/php-7.4/bin/phpize /usr/bin/phpize
ln -s /usr/local/php-7.4/bin/php-config /usr/bin/php-config

cp files/php74-fpm.service /etc/systemd/system/php-fpm.service
systemctl enable php-fpm.service --now

