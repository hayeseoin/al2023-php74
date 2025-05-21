#!/bin/bash

# Must be run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root. Exiting."
  exit 1
fi

rm /usr/bin/php
rm /usr/bin/phpize
rm /usr/bin/php-config
rm -rf /usr/local/php-7.4/
rm /etc/systemd/system/php-fpm.service
