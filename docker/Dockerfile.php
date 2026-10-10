# Shared PHP build for all three runtimes. One version (8.5.11), one extension set,
# one php-production.ini, so a difference between charts is the server, not PHP.
#
# Targets:
#   php-base     php:8.5.11-cli-trixie + composer + drush; the FreeUnit runtime
#   php-fpm      php:8.5.11-fpm-trixie + nginx in the same container
#   apache       php:8.5.11-apache-trixie (mod_php on prefork)
#
# Drupal 11.4 needs PHP >= 8.3, Drupal 12 needs >= 8.5; 8.5.11 covers both lines.
# opcache is compiled in; JIT is off in php-production.ini (plan section 2).

FROM composer/composer:2-bin AS composer
FROM ghcr.io/mlocati/php-extension-installer:2 AS php-extension-installer

FROM php:8.5.11-cli-trixie AS php-base
COPY --from=php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/install-php-extensions
COPY --from=composer /composer /usr/bin/composer
RUN set -eux; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' > /etc/apt/apt.conf.d/80-retries; \
    install-php-extensions intl mbstring pdo_mysql mysqli pdo_pgsql pdo_sqlite gd zip opcache exif apcu; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl default-mysql-client; \
    rm -rf /var/lib/apt/lists/*
COPY docker/php-production.ini /usr/local/etc/php/conf.d/zz-production.ini
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
ENV COMPOSER_HOME=/opt/composer
RUN composer global require --no-interaction --no-progress drush/drush:^13 \
    && ln -s /opt/composer/vendor/bin/drush /usr/local/bin/drush
WORKDIR /app
STOPSIGNAL SIGTERM
CMD ["php", "-a"]

# nginx + php-fpm in one container: the perf sampler sums one server tree per
# runtime, so the pair must live in one cgroup (plan section 5.3).
FROM php:8.5.11-fpm-trixie AS php-fpm
COPY --from=php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/install-php-extensions
COPY --from=composer /composer /usr/bin/composer
RUN set -eux; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' > /etc/apt/apt.conf.d/80-retries; \
    install-php-extensions intl mbstring pdo_mysql mysqli pdo_pgsql pdo_sqlite gd zip opcache exif apcu; \
    apt-get update; \
    apt-get install -y --no-install-recommends nginx curl default-mysql-client; \
    rm -rf /var/lib/apt/lists/*
COPY docker/php-production.ini /usr/local/etc/php/conf.d/zz-production.ini
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY docker/runtimes/php-fpm.conf /usr/local/etc/php-fpm.d/www.conf
COPY docker/runtimes/nginx.conf /etc/nginx/conf.d/default.conf
# the Debian package's default server would win the name conflict on :80
RUN rm -f /etc/nginx/sites-enabled/default
COPY docker/entrypoint-nginx-fpm.sh /usr/local/bin/entrypoint-nginx-fpm.sh
RUN chmod +x /usr/local/bin/entrypoint-nginx-fpm.sh
WORKDIR /app
CMD ["/usr/local/bin/entrypoint-nginx-fpm.sh"]

# mod_php requires a non-threaded MPM; php:*-apache already builds libphp for
# prefork, so this target only pins the child count and the INI.
FROM php:8.5.11-apache-trixie AS apache
COPY --from=php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/install-php-extensions
COPY --from=composer /composer /usr/bin/composer
RUN set -eux; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' > /etc/apt/apt.conf.d/80-retries; \
    install-php-extensions intl mbstring pdo_mysql mysqli pdo_pgsql pdo_sqlite gd zip opcache exif apcu; \
    a2enmod rewrite; \
    a2dissite 000-default; \
    rm -rf /var/lib/apt/lists/*
COPY docker/php-production.ini /usr/local/etc/php/conf.d/zz-production.ini
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY docker/runtimes/apache.conf /etc/apache2/conf-available/zz-bench.conf
RUN a2enconf zz-bench
WORKDIR /app
CMD ["apache2-foreground"]
