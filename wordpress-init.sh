#!/bin/bash

# Update all packages
yum -y update

# Mount EFS
MOUNT_PATH="/var/www"
EFS_DNS_NAME=${vars.efs_dns_name}

[ $(grep -c $${EFS_DNS_NAME} /etc/fstab) -eq 0 ] && \
        (echo "$${EFS_DNS_NAME}:/ $${MOUNT_PATH} nfs nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev 0 0" >> /etc/fstab; \
                mkdir -p $${MOUNT_PATH}; mount $${MOUNT_PATH})


# Install httpd and php packages
amazon-linux-extras enable php7.4
yum -y install httpd php php-cli php-gd php-mysqlnd
systemctl enable --now httpd

# Download Wordpress
WP_ROOT_DIR=$${MOUNT_PATH}/html
LOCK_FILE=$${MOUNT_PATH}/.wordpress.lock
EC2_LIST=$${MOUNT_PATH}/.ec2_list
WP_CONFIG_FILE=$${WP_ROOT_DIR}/wp-config.php


SHORT_NAME=$(hostname -s)
echo "$${SHORT_NAME}" >> $${EC2_LIST}
FIRST_SERVER=$(head -1 $${EC2_LIST})

if [ ! -f $${LOCK_FILE} -a "$${SHORT_NAME}" == "$${FIRST_SERVER}" ]; then

# Create lock to avoid multiple attempts
	touch $${LOCK_FILE}

# A hack to keep ALB monitoring healthy during initialization
	echo "OK" > $${WP_ROOT_DIR}/index.html
# Hack Finish here

        cd $${MOUNT_PATH}
        wget http://wordpress.org/latest.tar.gz
        tar xzvf latest.tar.gz
	rm -rf $${WP_ROOT_DIR}
	mv wordpress html
        mkdir $${WP_ROOT_DIR}/wp-content/uploads
	touch $${WP_ROOT_DIR}/wp-config.php
	chown -R apache:apache $${WP_ROOT_DIR}
	rm -rf latest.tar.gz

else
	echo "$(date) :: Lock is acquired by another server"  >> /var/log/user-data-status.txt
fi

# Reboot
reboot
