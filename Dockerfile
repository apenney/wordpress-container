############################
# Build stage for PHP extensions
############################
FROM docker.io/library/wordpress:apache AS builder

# Install build dependencies and PHP extensions
RUN <<EOF
set -eux
apt-get update
apt-get install -y --no-install-recommends \
    libonig-dev \
    libxml2-dev
rm -rf /var/lib/apt/lists/*

# Install PHP extensions
docker-php-ext-install -j "$(nproc)" \
    mbstring \
    xml

pecl install igbinary
docker-php-ext-enable igbinary

# Verify installation
extDir="$(php -r 'echo ini_get("extension_dir");')"
[ -d "$extDir" ]
! { ldd "$extDir"/*.so | grep 'not found'; }

# Check for PHP warnings during startup
err="$(php --version 3>&1 1>&2 2>&3)"
[ -z "$err" ]
EOF

############################
# WordPress plugins/themes stage
############################
FROM docker.io/library/wordpress:apache AS addons

# Install dependencies for downloading addons
RUN <<EOF
set -eux
apt-get update
apt-get install -y --no-install-recommends \
    jq \
    unzip
rm -rf /var/lib/apt/lists/*
EOF

# Install WordPress addons
WORKDIR /usr/src/wordpress
COPY wp-addon-install.sh /usr/local/bin/
RUN <<EOF
set -eux
chmod +x /usr/local/bin/wp-addon-install.sh
/usr/local/bin/wp-addon-install.sh
EOF

############################
# Final stage
############################
FROM docker.io/library/wordpress:apache

# Add WordPress CLI
COPY --from=docker.io/library/wordpress:cli /usr/local/bin/wp /usr/local/bin/wp

# Copy PHP extensions from builder
COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

# Add runtime dependencies
RUN <<EOF
set -eux
apt-get update
apt-get install -y --no-install-recommends \
    jq \
    unzip
rm -rf /var/lib/apt/lists/*
EOF

# Configure WordPress and Apache
WORKDIR /usr/src/wordpress
RUN <<EOF
set -eux
find /etc/apache2 -name '*.conf' -type f \
    -exec sed -ri \
        -e "s!/var/www/html!$PWD!g" \
        -e "s!Directory /var/www/!Directory $PWD!g" \
        '{}' +
cp -s wp-config-docker.php wp-config.php
EOF

# Copy WordPress addons from the addons stage
COPY --from=addons /usr/src/wordpress/wp-content/ /usr/src/wordpress/wp-content/

# Add custom entrypoint
COPY entrypoint-addon.sh /usr/local/bin/
RUN <<EOF
set -eux
chmod +x /usr/local/bin/entrypoint-addon.sh
EOF

# Add underprivileged runtime user
RUN <<EOF
set -eux
groupadd --system wordpress
useradd --system --gid wordpress --no-create-home --home /nonexistent \
    --comment "wordpress user" --shell /bin/false wordpress
EOF

# Add health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

# Switch to underprivileged user
USER wordpress
ENV APACHE_RUN_USER=wordpress \
    APACHE_RUN_GROUP=wordpress

ENTRYPOINT ["entrypoint-addon.sh"]
CMD ["apache2-foreground"]
