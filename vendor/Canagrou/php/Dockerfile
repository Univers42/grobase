FROM php:8.3-fpm-alpine

# Install system dependencies
RUN apk add --no-cache \
    freetype-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libwebp-dev \
    msmtp \
    && docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
        --with-webp \
    && docker-php-ext-install -j$(nproc) \
        gd \
        pdo \
        pdo_mysql \
        opcache

# Configure msmtp for mail relay to Mailpit
RUN printf "account default\nhost mailpit\nport 1025\nfrom noreply@camagru.local\nauth off\ntls off\n" > /etc/msmtprc

# PHP configuration
RUN printf "upload_max_filesize = 10M\npost_max_size = 12M\nmemory_limit = 128M\nsendmail_path = /usr/bin/msmtp -t\n" > /usr/local/etc/php/conf.d/custom.ini

# Create uploads directory
RUN mkdir -p /var/www/html/public/uploads \
    && chown -R www-data:www-data /var/www/html/public/uploads

WORKDIR /var/www/html
