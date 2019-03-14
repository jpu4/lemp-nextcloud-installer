#!/bin/bash

# locking and caching
yum install -y php-pecl-apcu redis php-pecl-redis
systemctl start redis
systemctl enable redis

yum -y install yum-utils
yum-config-manager --enable rhui-REGION-rhel-server-extras rhui-REGION-rhel-server-optional
yum install certbot python2-certbot-nginx

# For use with vultr blockstorage
mkdir /mnt/block100
echo >> /etc/fstab
echo /dev/vdb1               /mnt/block100       ext4    defaults,noatime,nofail 0 0 >> /etc/fstab
mount /mnt/block100

while true; do
    
# ref: https://docs.nextcloud.com/server/15/admin_manual/installation/command_line_installation.html

    ncReleaseFile="nextcloud-15.0.5.zip"
    ncReleaseURL="https://download.nextcloud.com/server/releases/$ncReleaseFile"
    filedateTS=`date '+%Y%m%d-%H%M%S'`
    dateTS=`date '+%Y-%m-%d-%H:%M:%S'`
    webRoot="/usr/share/nginx"
    documentRoot="$webRoot/nextcloud"
    httpUser="nginx"
    confDir="/etc/nginx/conf.d"
    dbName="nextcloud"
    dbHost="localhost"
    dbPort="3306"
    dbUser="nextcloud_$RANDOM"
    dbUserPass=`tr -cd '[:alnum:]' < /dev/urandom | fold -w30 | head -n1`
    dbTablePrefix="nc_"
    ncAdminPass=`tr -cd '[:alnum:]' < /dev/urandom | fold -w30 | head -n1`
    ncDataDir="$documentRoot/data"

    read -e -i "$(hostname)" -p "Hostname: (ie. cloud.example.com) " hostName_in
    hostName="${hostName_in:-$(hostname)}"

    read -e -i "$webRoot" -p "Webroot: " webRoot_in
    webRoot="${webRoot_in:-$webRoot}"

    read -e -i "$documentRoot" -p "documentRoot: " documentRoot_in
    documentRoot="${documentRoot_in:-$documentRoot}"

    read -e -i "$httpUser" -p "HTTP User: " httpUser_in
    httpUser="${httpUser_in:-$httpUser}"

    read -e -i "$dbName" -p "dbName: " dbName_in
    dbName="${dbName_in:-$dbName}"

    read -e -i "$dbHost" -p "dbHost: " dbHost_in
    dbHost="${dbHost_in:-$dbHost}"

    read -e -i "$dbPort" -p "dbPort: " dbPort_in
    dbPort="${dbPort_in:-$dbPort}"

    read -e -i "$dbUser" -p "dbUser: " dbUser_in
    dbUser="${dbUser_in:-$dbUser}"

    read -e -i "$dbUserPass" -p "dbUserPass: " dbUserPass_in
    dbUserPass="${dbUserPass_in:-$dbUserPass}"

    read -e -i "$dbTablePrefix" -p "dbTablePrefix: " dbTablePrefix_in
    dbTablePrefix="${dbTablePrefix_in:-$dbTablePrefix}"

    read -p 'ncAdminUser: ' ncAdminUser

    read -e -i "$ncAdminPass" -p "ncAdminPass: " ncAdminPass_in
    ncAdminPass="${ncAdminPass_in:-$ncAdminPass}"

    read -e -i "$ncDataDir" -p "ncDataDir: " ncDataDir_in
    ncDataDir="${ncDataDir_in:-$ncDataDir}"

    echo "## For your records"
    echo "> INSTALL DATE: " $dateTS
    echo ""
    echo "* SERVER HOSTNAME: " $(hostname)
    echo "* WEBROOT: " $webRoot
    echo "* DOCUMENTROOT: " $documentRoot
    echo "* HTTPUSER: " $httpUser
    echo "* NGINX CONF DIR: " $confDir
    echo "* NEXTCLOUD DATA DIRECTORY: " $ncDataDir
    echo "* NEXTCLOUD DBNAME: " $dbName
    echo "* NEXTCLOUD DBHOST: " $dbHost
    echo "* NEXTCLOUD DBPORT: " $dbPort
    echo "* NEXTCLOUD DBUSER: " $dbUser
    echo "* NEXTCLOUD DBPASS: " $dbUserPass
    echo "* NEXTCLOUD DBTABLEPREFIX: " $dbTablePrefix
    echo "* NEXTCLOUD ADMINUSER: " $ncAdminUser
    echo "* NEXTCLOUD ADMINPASS: " $ncAdminPass
    echo ""

    cancelContinue="Y"
    read -e -i "$cancelContinue" -p "Continue? (N to cancel) " cancelContinue_in 
    cancelContinue="${cancelContinue_in:-$cancelContinue}"

    case $cancelContinue in
        [Nn]* ) exit;;
        [Yy]* ) break;;
    esac
done

# fix solution ref: https://stackoverflow.com/questions/37702595/owncloud-setup-sqlstatehy0001045-access-denied-for-user-owncloudlocalhos
if [ $dbHost = 'localhost' ]
then
    dbHost="127.0.0.1"
fi

# Use the official nextcloud nginx conf file and find and replace hostname and documentroot
cp nginx-official-nextcloud.conf $confDir/nextcloud-$hostName.conf
/usr/bin/sed -i -e "s|HOSTNAME|$hostName|g" $confDir/nextcloud-$hostName.conf
/usr/bin/sed -i -e "s|DOCUMENTROOT|$documentRoot|g" $confDir/nextcloud-$hostName.conf

mv $confDir/http.conf $confDir/http.conf.bak
mv $confDir/https.conf $confDir/https.conf.bak

# Let's Encrypt
certbot --nginx

cd $webRoot
# Download Nextcloud Release Package
wget -q -P $webRoot $ncReleaseURL
unzip $ncReleaseFile

# Set httpUser as owner
chown -R $httpUser:$httpUser $documentRoot
chmod 775 $documentRoot

# Create data directory
mkdir $ncDataDir
chown $httpUser:$httpUser $ncDataDir
chmod 0770 $ncDataDir

# php -i | grep memory_limit
/usr/bin/sed -i -e "s|;user_ini.filename = ".user.ini"|user_ini.filename = ".user.ini"|g" /etc/php.ini
/usr/bin/sed -i -e "s|memory_limit = 128M|memory_limit = 512M|g" /etc/php.ini
systemctl restart php-fpm

# Create database and user
mysql -u root -e "CREATE DATABASE $dbName;"
mysql -u root -e "CREATE USER '$dbUser'@'$dbHost' IDENTIFIED BY '$dbPass';"
mysql -u root -e "GRANT ALL PRIVILEGES ON $dbName.* TO '$dbUser'@'$dbHost' WITH GRANT OPTION;"

# Install Nextcloud with occ command line installer
cd $documentRoot
sudo -u $httpUser php occ maintenance:install --database "mysql" --database-name "$dbName" --database-host "$dbHost" --database-port "$dbPort" --database-user "$dbUser" --database-pass "$dbUserPass" --database-table-prefix "$dbTablePrefix" --admin-user "$ncAdminUser" --admin-pass "$ncAdminPass" --data-dir "$ncDataDir"

# ref: https://docs.nextcloud.com/server/15/admin_manual/installation/selinux_configuration.html

# NOT WORKING
#semanage fcontext -a -t httpd_sys_rw_content_t '$documentRoot/data(/.*)?'
#semanage fcontext -a -t httpd_sys_rw_content_t '$documentRoot/config(/.*)?'
#semanage fcontext -a -t httpd_sys_rw_content_t '$documentRoot/apps(/.*)?'
#semanage fcontext -a -t httpd_sys_rw_content_t '$documentRoot/.htaccess'
#semanage fcontext -a -t httpd_sys_rw_content_t '$documentRoot/.user.ini'
#semanage fcontext -a -t httpd_sys_rw_content_t '$documentRoot/3rdparty/aws/aws-sdk-php/src/data/logs(/.*)?'

#restorecon -Rv '$documentRoot/'

# ref: https://docs.nextcloud.com/server/15/admin_manual/installation/server_tuning.html

# on ubuntu: etc/php/7.0/fpm/php.ini
# php.ini?

# opcache.enable=1
# opcache.enable_cli=1
# opcache.interned_strings_buffer=8
# opcache.max_accelerated_files=10000
# opcache.memory_consumption=128
# opcache.save_comments=1
# opcache.revalidate_freq=1

# ref: https://docs.nextcloud.com/server/15/admin_manual/configuration_server/caching_configuration.html

systemctl restart nginx

# update firewall
firewall-cmd --add-service=http --permanent
firewall-cmd --add-service=https --permanent
firewall-cmd --add-service=mysql --permanent
firewall-cmd --reload
