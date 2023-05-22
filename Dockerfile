FROM php:8.2.6-zts-bullseye AS php

# Note that this image is based on the official PHP image, once https://github.com/php/php-src/pull/10141 is merged, this stage can be removed

RUN rm -Rf /usr/local/include/php/ /usr/local/lib/libphp.* /usr/local/lib/php/ /usr/local/php/

ENV PHPIZE_DEPS \
    autoconf \
    dpkg-dev \
    file \
    g++ \
    gcc \
    libc-dev \
    make \
    pkg-config \
    re2c

RUN apt-get update && \
    apt-get -y --no-install-recommends install \
    $PHPIZE_DEPS \
    libargon2-dev \
    libcurl4-openssl-dev \
    libonig-dev \
    libreadline-dev \
    libsodium-dev \
    libsqlite3-dev \
    libssl-dev \
    libxml2-dev \
    zlib1g-dev \
    bison \
    git \
    && \
    apt-get clean

WORKDIR /usr/src

RUN tar xf php.tar.xz && \
    cd php-8.2.6 && \
    ./configure \
        --enable-embed \
        --enable-zts \
        --disable-zend-signals \
        --enable-zend-max-execution-timers \
        --enable-mysqlnd \
        --enable-option-checking=fatal \
        --with-mhash \
        --with-pic \
        --enable-ftp \
        --enable-mbstring \
        --with-password-argon2 \
        --with-sodium=shared \
        --with-pdo-sqlite=/usr \
        --with-sqlite3=/usr \
        --with-curl \
        --with-iconv \
        --with-openssl \
        --with-readline \
        --with-zlib \
        --disable-phpdbg \
        --with-config-file-path="$PHP_INI_DIR" \
        --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" && \
    make -j$(nproc) && \
    make install && \
    rm -Rf php-8.2.6 && \
    php --version

RUN mkdir -p /tmp/lib && cd /usr/lib && \
    ldd /usr/local/bin/php | grep '=> /usr/lib/' | cut -d' ' -f3 | sed 's#/usr/lib/##g' | xargs -I % cp --parents "%" /tmp/lib/

FROM golang:1.20.4-bullseye AS builder

# This is required to link the FrankenPHP binary to the PHP binary
RUN apt-get update && \
    apt-get -y --no-install-recommends install \
        libargon2-dev \
        libcurl4-openssl-dev \
        libonig-dev \
        libreadline-dev \
        libsodium-dev \
        libsqlite3-dev \
        libssl-dev \
        libxml2-dev \
        zlib1g-dev \
        && \
        apt-get clean

WORKDIR /go/src/app

COPY go.mod go.sum ./
RUN go mod download

COPY ./caddy/go.mod ./caddy/go.sum ./caddy/
RUN cd caddy && go mod download

COPY . .

# todo: automate this?
# see https://github.com/docker-library/php/blob/master/8.2/bullseye/zts/Dockerfile#L57-L59 for PHP values
ENV CGO_LDFLAGS="-lssl -lcrypto -lreadline -largon2 -lcurl -lonig -lz $PHP_LDFLAGS" CGO_CFLAGS=$PHP_CFLAGS CGO_CPPFLAGS=$PHP_CPPFLAGS

COPY --from=php /usr/local/include/php/ /usr/local/include/php
COPY --from=php /usr/local/lib/libphp.* /usr/local/lib
RUN ln -s /usr/local/lib/libphp.so /usr/lib/libphp.so

WORKDIR /go/src/app/caddy/frankenphp

RUN go build && \
    mv ./frankenphp /usr/local/bin/frankenphp && \
    mv ./Caddyfile /etc/Caddyfile

WORKDIR /go/src/app

FROM php:8.2.6-zts-bullseye AS final

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

RUN mkdir -p /app/public
RUN echo '<?php phpinfo();' > /app/public/index.php

COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp
COPY --from=builder /etc/Caddyfile /etc/Caddyfile

COPY --from=php /usr/local/include/php/ /usr/local/include/php
COPY --from=php /usr/local/lib/libphp.* /usr/local/lib
COPY --from=php /usr/local/lib/php/ /usr/local/lib/php
COPY --from=php /usr/local/php/ /usr/local/php
COPY --from=php /usr/local/bin/ /usr/local/bin
COPY --from=php /usr/src /usr/src

RUN sed -i 's/php/frankenphp run/g' /usr/local/bin/docker-php-entrypoint

WORKDIR /app
CMD [ "--config", "/etc/Caddyfile" ]

FROM gcr.io/distroless/cc-debian11 AS slim

COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp
COPY --from=builder /etc/Caddyfile /etc/Caddyfile

COPY --from=php /bin/sh /bin/
COPY --from=php /lib/ /lib/
COPY --from=php /tmp/lib/ /usr/lib/

COPY --from=final /app /app
COPY --from=final /usr/local/bin/docker-php-* /usr/local/bin/php /usr/local/bin/frankenphp /usr/local/bin/

WORKDIR /app
CMD [ "--config", "/etc/Caddyfile" ]
