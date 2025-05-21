# al2023-php74
Compiled PHP 7.4 for AL2023.
Not for production use.


## Testing PHP 7.4
Ensure that files/php74-fpm.conf is included in `/etc/httpd/conf.d/`

Run the following command
```
echo "<?php phpinfo(); ?>" | sudo tee /var/www/html/info.php
```
Restart apache check the page
```
apachectl graceful
# or
sudo systemctl restart httpd

curl http://localhost/info.php
```
It should return the PHP info page.
