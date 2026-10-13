# Shared PHP build for all three runtimes. One version (8.5.11), one extension set,
# one php-production.ini, so a difference between charts is the server, not PHP.
#
# Targets:
#   php-base     php:8.5.11-cli-trixie + composer + drush; the FreeUnit runtime
#   php-fpm-base the PHP half of every PHP-FPM runtime (extensions, INI, pool)
#   php-fpm      php-fpm-base + the Debian nginx package
#   nginx-src    php-fpm-base + nginx built from the upstream tarball
#   angie-fpm    php-fpm-base + Angie built from the upstream tarball
#   freenginx-fpm php-fpm-base + FreeNginx built from the upstream tarball
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

# The PHP half of every PHP-FPM runtime.  Built once so the runtimes differ only
# in the server they install.
FROM php:8.5.11-fpm-trixie AS php-fpm-base
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
COPY docker/runtimes/php-fpm.conf /usr/local/etc/php-fpm.d/www.conf
WORKDIR /app

# nginx + php-fpm in one container: the perf sampler sums one server tree per
# runtime, so the pair must live in one cgroup (plan section 5.3).
FROM php-fpm-base AS php-fpm
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends nginx; \
    rm -rf /var/lib/apt/lists/*
COPY docker/runtimes/nginx.conf /etc/nginx/conf.d/default.conf
# the Debian package's default server would win the name conflict on :80
RUN rm -f /etc/nginx/sites-enabled/default
COPY docker/entrypoint-nginx-fpm.sh /usr/local/bin/entrypoint-nginx-fpm.sh
RUN chmod +x /usr/local/bin/entrypoint-nginx-fpm.sh
CMD ["/usr/local/bin/entrypoint-nginx-fpm.sh"]

# ---------------------------------------------------------------- the forks
# nginx, Angie and FreeNginx from their own tarballs with one script and one flag
# set, so a difference between the three is the source and not the packager.  The
# Debian package above stays the runtime the published nginx numbers came from;
# nginx-src is the like-for-like baseline for the two forks.  Versions and
# checksums are pinned in the call, so bumping a fork edits one line.  The binary
# is named separately because FreeNginx installs "nginx" and Angie installs
# "angie"; the perf sampler keys on the process title, which is "angie:" for
# Angie and "nginx:" for both nginx builds.
FROM php-fpm-base AS webserver-base
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential libpcre2-dev zlib1g-dev libssl-dev; \
    rm -rf /var/lib/apt/lists/*
COPY docker/build-webserver.sh docker/install-ws-conf.sh /usr/local/bin/
COPY docker/entrypoint-webserver-fpm.sh /usr/local/bin/
COPY docker/runtimes/ws-main-head.conf /tmp/ws-main-head.conf
COPY docker/runtimes/nginx-src.conf /tmp/server-nginx.conf
COPY docker/runtimes/angie.conf /tmp/server-angie.conf
COPY docker/runtimes/freenginx.conf /tmp/server-freenginx.conf
RUN chmod +x /usr/local/bin/build-webserver.sh /usr/local/bin/install-ws-conf.sh \
             /usr/local/bin/entrypoint-webserver-fpm.sh

FROM webserver-base AS nginx-src
RUN set -eux; \
    build-webserver.sh nginx \
        https://nginx.org/download/nginx-1.31.6.tar.gz \
        974ed5298a5e398e008704ed5db284e655fc270c596493dbccada452448fc9f1 \
        /usr/local/nginx nginx \
        --with-http_ssl_module --with-http_v2_module --with-http_realip_module \
        --with-http_stub_status_module --with-http_gzip_static_module \
        --with-http_sub_module --with-http_auth_request_module \
        --with-threads --with-file-aio --with-pcre-jit --with-cc-opt='-O2'; \
    install-ws-conf.sh nginx /usr/local/nginx nginx
ENV WEBSERVER_BIN=/usr/local/nginx/sbin/nginx \
    WEBSERVER_CONF=/usr/local/nginx/conf/nginx.conf
CMD ["/usr/local/bin/entrypoint-webserver-fpm.sh"]

FROM webserver-base AS angie-fpm
RUN set -eux; \
    build-webserver.sh angie \
        https://download.angie.software/files/angie-1.12.3.tar.gz \
        09343fcfd8a085dab8e3745fb568e0eb16c9284ad636407d2fbcbfcfea8b3788 \
        /usr/local/angie angie \
        --with-http_ssl_module --with-http_v2_module --with-http_realip_module \
        --with-http_stub_status_module --with-http_gzip_static_module \
        --with-http_sub_module --with-http_auth_request_module \
        --with-threads --with-file-aio --with-pcre-jit --with-cc-opt='-O2'; \
    install-ws-conf.sh angie /usr/local/angie angie
ENV WEBSERVER_BIN=/usr/local/angie/sbin/angie \
    WEBSERVER_CONF=/usr/local/angie/conf/nginx.conf
CMD ["/usr/local/bin/entrypoint-webserver-fpm.sh"]

FROM webserver-base AS freenginx-fpm
RUN set -eux; \
    build-webserver.sh freenginx \
        https://freenginx.org/download/freenginx-1.31.4.tar.gz \
        23d784d93e13ac8febf6dd209631e056bc8c4046769804c6ef3c56d401734e27 \
        /usr/local/freenginx nginx \
        --with-http_ssl_module --with-http_v2_module --with-http_realip_module \
        --with-http_stub_status_module --with-http_gzip_static_module \
        --with-http_sub_module --with-http_auth_request_module \
        --with-threads --with-file-aio --with-pcre-jit --with-cc-opt='-O2'; \
    install-ws-conf.sh freenginx /usr/local/freenginx nginx
ENV WEBSERVER_BIN=/usr/local/freenginx/sbin/nginx \
    WEBSERVER_CONF=/usr/local/freenginx/conf/nginx.conf
CMD ["/usr/local/bin/entrypoint-webserver-fpm.sh"]

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
