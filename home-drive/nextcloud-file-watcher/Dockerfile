ARG NEXTCLOUD_TAG=stable-fpm
FROM nextcloud:${NEXTCLOUD_TAG}
# Same base image nextcloud-app/nextcloud-cron use, not a smaller/generic
# one: `php occ` needs the exact PHP version and extensions Nextcloud
# itself ships with, and reusing this image is what guarantees that instead
# of tracking it separately. inotify-tools is the one thing it's missing.
RUN apt-get update \
    && apt-get install -y --no-install-recommends inotify-tools \
    && rm -rf /var/lib/apt/lists/*

COPY watch.sh /watch.sh
RUN chmod +x /watch.sh

ENTRYPOINT ["/watch.sh"]
