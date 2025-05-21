#!/bin/bash

#####
##Setup
#####

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


# Ensure servlets directory exists
mkdir -p /usr/share/tomcat9/webapps/servlets
# Turn off tomcat 
systemctl stop tomcat9

# # Prompt to select WAR file from terminalfour-releases
# echo "Choose the version to deploy:"
# select war_file in terminalfour-releases/*.war; do
#   if [[ -n "$war_file" ]]; then
#     echo "You selected: $war_file"
#     break
#   else
#     echo "Invalid selection. Try again."
#   fi
# done

# Find .war files, sort by parent directory version (natural sort)
mapfile -t war_files < <(find terminalfour-releases -type f -name '*.war' | sort -V -r)

# Prompt user to select one
echo "Choose the version to deploy:"
select war_file in "${war_files[@]}"; do
  if [[ -n "$war_file" ]]; then
    echo "You selected: $war_file"
    break
  else
    echo "Invalid selection. Try again."
  fi
done

# Prompt for domain name
read -rp "Enter domain name: " domain

# FindPrompt for dataset archives
# archives=(samplesite-dataset/*.tgz)
archives=($(find samplesite-dataset -type f -name '*.tgz'))


# Check if any archives were found
if [[ ${#archives[@]} -eq 0 ]]; then
  echo "No dataset archives found in samplesite-dataset/"
  exit 1
fi

# If only one archive, use it
if [[ ${#archives[@]} -eq 1 ]]; then
  dataset_archive="${archives[0]}"
  echo "Using dataset: $dataset_archive"
else
  echo "Available dataset archives:"
  select archive in "${archives[@]}"; do
    if [[ -n "$archive" ]]; then
      dataset_archive="$archive"
      echo "Selected dataset: $dataset_archive"
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done
fi

# Set cert directory
cert_dir="/etc/httpd/sslcerts/$domain"
# Define config files
work_dir="config-files/temp"
rm -rf "$work_dir"
mkdir -p "$work_dir"
cp config-files/000-terminalfour.SSL.conf "$work_dir/"
cp config-files/000-terminalfour.conf "$work_dir/"
ssl_conf_temp="$work_dir/000-terminalfour.SSL.conf"
non_ssl_conf_temp="$work_dir/000-terminalfour.conf"


ssl_conf_dest="/etc/httpd/conf.d/000-terminalfour.SSL.conf"
non_ssl_conf_dest="/etc/httpd/conf.d/000-terminalfour.conf"

# Define target location
target_war="/usr/share/tomcat9/webapps/servlets/$(basename "$war_file")"

# Ensure license file exists
if [[ ! -f "license.txt" ]]; then
  echo "ERROR: license.txt not found."
  exit 1
fi

# Read entire file content into a variable, preserving newlines
license=$(<license.txt)
# Escape single quotes for SQL (SQL uses '' to represent a single quote)
license_escaped=$(printf "%s" "$license" | sed "s/'/''/g")

#####
##Copy dataset
#####

if [[ -z "$dataset_archive" ]]; then
  echo "No .tgz dataset found in samplesite-dataset/"
  exit 1
fi

echo "Extracting dataset archive: $dataset_archive"
temp_dir=$(mktemp -d)

# Extract to temporary directory
tar -xzf "$dataset_archive" -C "$temp_dir"

# Verify filestore directory exists
if [[ ! -d "$temp_dir/web/terminalfour/filestore" ]]; then
  echo "Error: filestore directory not found in extracted dataset."
  rm -rf "$temp_dir"
  exit 1
fi

# Ensure target location exists
mkdir -p /web/terminalfour

# Remove existing filestore and copy new one
echo "Copying filestore to /web/terminalfour/filestore"
rm -rf /web/terminalfour/filestore
cp -a "$temp_dir/web/terminalfour/filestore" /web/terminalfour/

# Set ownership
chown -R tomcat:apache /web/terminalfour/filestore

echo "Filestore copied and ownership set. Temp directory cleaned up."

# Locate SQL backup file in extracted dataset
sql_file=$(find "$temp_dir" -type f -name "*.sql" | head -n 1)

if [[ -z "$sql_file" ]]; then
  echo "Error: No SQL backup found in dataset."
  rm -rf "$temp_dir"
  exit 1
fi

echo "Found SQL backup: $sql_file"

# Drop existing database if it exists and recreate it
mysql -ut4user -ppassword -e "
DROP DATABASE IF EXISTS terminalfour;
CREATE DATABASE terminalfour;
"

# Import the SQL backup
echo "Importing database into terminalfour..."
mysql -ut4user -ppassword terminalfour < "$sql_file"

echo "Database import complete."

# Clean up temp dir
rm -rf "$temp_dir"
echo "Temporary files removed."

#####
## WAR into tomcat
#####

# Ensure destination directory exists
mkdir -p /usr/share/tomcat9/webapps/servlets
chown tomcat:tomcat /usr/share/tomcat9/webapps/servlets


# Copy WAR file, overwriting if it exists
cp -f "$war_file" "$target_war"

echo "WAR file copied to $target_war"

# Update server.xml docBase
cp config-files/server.xml "$work_dir/"
server_xml_temp="$work_dir/server.xml"
server_xml="/usr/share/tomcat9/conf/server.xml"
escaped_path=$(printf '%s\n' "$target_war" | sed 's:/:\\/:g')

# Update the docBase inside the <Context> tag for /terminalfour
sed -i "s|WAR_PLACEHOLDER|$target_war|g" "$ssl_conf_temp" "$server_xml_temp"

cp "$server_xml_temp" "$server_xml"


echo "server.xml updated with new docBase: $target_war"

#####
## Create certificates and update apache
#####

# Create directory if it doesn't exist
mkdir -p "$cert_dir"

# Generate self-signed certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$cert_dir/key.key" \
  -out "$cert_dir/crt.crt" \
  -subj "/C=US/ST=State/L=City/O=Organization/CN=$domain"

# Copy cert to interm.crt
cp "$cert_dir/crt.crt" "$cert_dir/interm.crt"

echo "Certificate and key created at $cert_dir"

# Update ServerName and ServerAlias
# for conf_file in "$ssl_conf_temp" "$non_ssl_conf_temp"; do
#   sed -i -E "s/^\s*ServerName\s+.*$/    ServerName $domain/" "$conf_file"
#   sed -i -E "s/^\s*ServerAlias\s+.*$/    ServerAlias $domain/" "$conf_file"
# done
sed -i "s|SERVER_NAME_PLACEHOLDER|$domain|g" "$ssl_conf_temp" "$non_ssl_conf_temp"
sed -i "s|SERVER_ALIAS_PLACEHOLDER|$domain|g" "$ssl_conf_temp" "$non_ssl_conf_temp"
sed -i "s|DOMAIN_PLACEHOLDER|$domain|g" "$ssl_conf_temp" "$non_ssl_conf_temp"
sed -i "s|CERTIFICATE_DIR_PLACEHOLDER|$cert_dir|g" "$ssl_conf_temp"

cp "$ssl_conf_temp" "$ssl_conf_dest"
cp "$non_ssl_conf_temp" "$non_ssl_conf_dest"


echo "Apache config updated for domain $domain"

#####
## Update MySQL database with new domain
#####
mysql \
  -ut4user \
  -ppassword \
  terminalfour -A <<-ENDMARKER

UPDATE config_option SET config_value='https://$domain/terminalfour/' WHERE config_key='advanced.environment.smLocation';
UPDATE config_option SET config_value='https://$domain/terminalfour/' WHERE config_key='general.contextURL';

UPDATE config_option SET config_value=0 WHERE config_key='pxl.enablePxl';

INSERT IGNORE INTO config_option (config_key, config_value, config_type) VALUES ('advanced.system.autoUpgrade', '1', 'boolean');
UPDATE channel SET base_href = 'https://'"$domain"'/' WHERE id = 1;
UPDATE channel SET channel_publish_url = 'https://'"$domain"'/' WHERE id = 1;
UPDATE channel set output_dir="/web/terminalfour/htdocs/" where id=1;
UPDATE preview_filter set directory="/web/terminalfour/htdocs/preview/" where id=1;
UPDATE users SET password='m/gdbVWY1lgkeb+DxMvk8aTlzqzyxeqYk1H52yntGLCuj35+MEXyTfR8FoBPO/EVg2solCcPCGPR82CO/dj6Sw==' WHERE username='termfour';
UPDATE users SET hash_iterations=4000 WHERE username='termfour';
UPDATE users SET password_salt='touS6/Jw3DIEDYxz6fBioV2hwL4tzPisy6RDsKMXWT4=' WHERE username='termfour';
COMMIT;
ENDMARKER

echo "Database updated with domain $domain"

#UPDATE license_keys SET license_key='${license_escaped}' where id=1;
#UPDATE users SET password='m/gdbVWY1lgkeb+DxMvk8aTlzqzyxeqYk1H52yntGLCuj35+MEXyTfR8FoBPO/EVg2solCcPCGPR82CO/dj6Sw==' WHERE username='termfour';
#UPDATE users SET hash_iterations=4000 WHERE username='termfour';
#UPDATE users SET password_salt='touS6/Jw3DIEDYxz6fBioV2hwL4tzPisy6RDsKMXWT4=' WHERE username='termfour';

#####
## Finishing
#####

rm -rf "$work_dir"

# Ensure temp directory exists
mkdir -p /web/terminalfour/temp

# Correct all permissions on /web/terminalfour
chown -R tomcat:apache /web/terminalfour

# Host entry
echo "Deployed successfully. Please add the following to your hosts file:"
echo "$(hostname -I | awk '{print $1}')    $domain"

apachectl graceful
apachectl graceful

# Make sure tomcat files belong to the right user
chown -R tomcat:tomcat /usr/share/tomcat9
systemctl start tomcat9
